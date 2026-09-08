#!/usr/bin/env bash
#
# Zone de service d'une entreprise (Palier 1) — le pool se borne aux wilayas
# déclarées, et le réglage SURVIT (champ personnalisé sur le Vendor Fleetbase).
#
# ── Ce que ce banc éprouve ──────────────────────────────────────────────────
#
# `PUT /flotte/zone` écrit la liste des wilayas dans un champ personnalisé du
# Vendor — définition auto-provisionnée, sentinelle « - » pour « aucune »
# (Fleetbase refuse la chaîne vide). Rien de tout cela n'est vérifiable hors
# stack réelle. Puis `getClaimableOrders` borne le pool à cette zone AVANT les
# filtres de chips (Palier 2).
#
# ── Témoin positif ET négatif (règle 8), plus la persistance ────────────────
#
#   • zone vide        → les trois courses visibles (contrôle positif) ;
#   • zone = [Alger]   → Alger visible, Blida CACHÉE, la course SANS wilaya
#                        reste visible (biais : on ne cache que ce qu'on SAIT
#                        hors zone) ; la réponse porte serviceZone=[Alger] ;
#   • zone = [Alger,Blida] → les deux visibles ;
#   • zone effacée []  → tout revisible, serviceZone=[] ;
#   • PUT [Oran] puis GET /flotte/zone frais → ["Oran"] : c'est STOCKÉ, pas un
#     état de session (la preuve que le champ personnalisé Vendor fonctionne).
#
# Mutation : neutraliser `filterByServiceZone` dans opportunity/fleet-zone.ts
# fait échouer l'étape « zone = [Alger] ».
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-zone-entreprise.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
FLEET="${FLEET:-app-parcours-entreprise@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "OK $1"; }
fail() { echo "XX $1"; [ -n "${2:-}" ] && echo "   $2"; cleanup; exit 1; }
step() { echo; echo "-- $1 --"; }

. "$(dirname "$0")/lib/fleetbase.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H "Content-Type: application/json" -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }
fapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H "Content-Type: application/json" -H "Authorization: Bearer $FLEET_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_TOKEN"; fi; }

OA=""; OB=""; ON=""
cleanup() {
  [ -n "${FLEET_TOKEN:-}" ] && fapi PUT /flotte/zone '{"wilayas":[]}' >/dev/null 2>&1 || true
  for o in "$OA" "$OB" "$ON"; do
    [ -n "$o" ] && mapi POST "/commercant/commandes/$o/annuler" "{}" >/dev/null 2>&1 || true
  done
}

# Publie une course DIFFUSEE. $1 = province ("" pour aucune). -> fleetbaseOrderId
publish() {
  local o uuid prov="$1"
  o="$(mapi POST /commercant/commandes "$(jq -n --arg p "$prov" '{
    draft:true,
    pickupLocationName:"Depot Zone", pickupLatitude:36.7719, pickupLongitude:3.0589,
    pickupContactName:"Commerce", pickupContactPhone:"0551020304",
    dropoffLocationName:"Client", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"0551020305",
    items:[{description:"colis", quantity:1}], price:600, podMethod:"aucune"
  } + (if ($p|length) > 0 then {pickupProvince:$p} else {} end)')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 220)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

# La course $1 est-elle dans /flotte/opportunites ? yes/no
opp_has() { fapi GET "/flotte/opportunites?limit=100" \
  | jq -e --arg o "$1" '[.data[]?.uuid] | index($o)' >/dev/null 2>&1 && echo yes || echo no; }

# serviceZone renvoyé par la liste, en CSV trié
opp_zone() { fapi GET "/flotte/opportunites?limit=100" \
  | jq -r '(.serviceZone // []) | sort | join(",")'; }

# la zone lue par GET /flotte/zone, en CSV trié
read_zone() { fapi GET /flotte/zone | jq -r '(.wilayas // []) | sort | join(",")'; }

# pose une zone : $@ = wilayas (aucun argument => zone vide)
set_zone() {
  local body='{"wilayas":[]}'
  if [ $# -gt 0 ]; then
    body="$(printf '%s\n' "$@" | jq -R . | jq -sc '{wilayas: .}')"
  fi
  fapi PUT /flotte/zone "$body" >/dev/null
}

echo "================================================================"
echo "  Zone de service d'une entreprise — le pool se borne, et ca dure"
echo "================================================================"

step "Decor : connexions"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commercant impossible"
fb_activate_vendor_by_email "$FLEET" >/dev/null 2>&1 || true
FLEET_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$FLEET" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$FLEET_TOKEN" ] || fail "Connexion entreprise impossible"
set_zone   # part d'une zone vide, quel que soit l'etat laisse par un run precedent
pass "commercant + entreprise connectes, zone remise a vide"

step "Trois courses : Alger, Blida, et une SANS wilaya"
OA="$(publish "Alger")"; [[ "$OA" == ERR:* ]] && fail "publish Alger" "$OA"
OB="$(publish "Blida")"; [[ "$OB" == ERR:* ]] && fail "publish Blida" "$OB"
ON="$(publish "")";      [[ "$ON" == ERR:* ]] && fail "publish sans wilaya" "$ON"
pass "OA=Alger  OB=Blida  ON=sans wilaya"

step "Zone vide : les trois visibles (controle positif)"
[ "$(opp_has "$OA")" = "yes" ] || fail "zone vide : OA absente"
[ "$(opp_has "$OB")" = "yes" ] || fail "zone vide : OB absente"
[ "$(opp_has "$ON")" = "yes" ] || fail "zone vide : ON absente"
[ -z "$(opp_zone)" ] || fail "zone vide : serviceZone devrait etre [] mais vaut [$(opp_zone)]"
pass "les trois visibles, serviceZone=[]"

step "Zone = [Alger] : ecrit, RELU, applique"
set_zone "Alger"
[ "$(read_zone)" = "Alger" ] || fail "GET /flotte/zone ne rend pas [Alger] apres PUT" "lu: [$(read_zone)] — le champ personnalise Vendor n'a pas pris"
[ "$(opp_has "$OA")" = "yes" ] || fail "zone=[Alger] : OA (Alger) a disparu (filtre trop large)"
[ "$(opp_has "$OB")" = "no"  ] || fail "zone=[Alger] : OB (Blida) visible — le filtre ne filtre pas"
[ "$(opp_has "$ON")" = "yes" ] || fail "zone=[Alger] : ON (sans wilaya) cachee — le biais devrait la laisser passer"
[ "$(opp_zone)" = "Alger" ] || fail "zone=[Alger] : serviceZone de la liste vaut [$(opp_zone)]"
pass "Alger visible, Blida cachee, sans-wilaya visible, serviceZone=[Alger]"

step "Zone = [Alger, Blida] : les deux visibles"
set_zone "Alger" "Blida"
[ "$(read_zone)" = "Alger,Blida" ] || fail "GET /flotte/zone : [$(read_zone)] au lieu de [Alger,Blida]"
[ "$(opp_has "$OA")" = "yes" ] || fail "zone=[Alger,Blida] : OA a disparu"
[ "$(opp_has "$OB")" = "yes" ] || fail "zone=[Alger,Blida] : OB a disparu"
pass "Alger et Blida visibles"

step "Zone effacee : tout revisible, serviceZone=[]"
set_zone
[ -z "$(read_zone)" ] || fail "apres effacement, GET /flotte/zone rend encore [$(read_zone)]"
[ "$(opp_has "$OB")" = "yes" ] || fail "zone effacee : OB (Blida) toujours cachee"
[ -z "$(opp_zone)" ] || fail "zone effacee : serviceZone=[$(opp_zone)]"
pass "les trois visibles, serviceZone=[]"

step "Persistance : PUT [Oran] puis relecture FRAICHE"
set_zone "Oran"
[ "$(read_zone)" = "Oran" ] || fail "persistance : GET rend [$(read_zone)] et pas [Oran] — la valeur ne survit pas a l'ecriture"
# rien de nos trois reperes n'est a Oran : ils doivent tous disparaitre
[ "$(opp_has "$OA")" = "no" ] || fail "zone=[Oran] : OA (Alger) encore visible"
[ "$(opp_has "$OB")" = "no" ] || fail "zone=[Oran] : OB (Blida) encore visible"
[ "$(opp_has "$ON")" = "yes" ] || fail "zone=[Oran] : ON (sans wilaya) cachee — biais"
pass "zone=[Oran] stockee et appliquee ; seule la course sans wilaya reste"

cleanup
echo
echo "================================================================"
echo "OK  la zone de service se stocke (champ perso Vendor), se relit,"
echo "    borne le pool, et le biais garde les courses sans wilaya."
echo "================================================================"
