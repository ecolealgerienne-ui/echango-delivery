#!/usr/bin/env bash
#
# Tri et filtres de « Courses libres » (entreprise) — chaque axe avec son témoin.
#
# ── Ce que ce banc éprouve, et ce qu'aucun autre ne posait ───────────────────
#
# `GET /flotte/opportunites` servait le pool national brut. Il accepte désormais
# `wilaya`, `vehicleType`, `withoutCod` et `sort`, appliqués côté serveur AVANT
# pagination. Le risque est le plus redouté du dépôt (règle 10) : un filtre trop
# large vide la liste en silence, un filtre ignoré ne filtre rien — les deux
# indiscernables d'une panne sans témoin.
#
# ── Témoin positif ET négatif à chaque axe (règle 8) ─────────────────────────
#
#   • sans filtre        → les quatre courses visibles (contrôle positif) ;
#   • wilaya=Alger       → Alger visibles, Blida CACHÉE ; et l'inverse (symétrie) ;
#   • vehicleType=moto   → moto visibles, utilitaire ET voiture CACHÉES
#                          (égalité EXACTE, pas l'échelle du pool transporteur) ;
#   • withoutCod=true     → sans COD visibles, la course à encaisser CACHÉE ;
#   • sort=best_paid      → prix décroissant sur nos trois repères ;
#   • wilaya inconnue     → nos quatre courses absentes (le paramètre EST honoré) ;
#   • facets             → wilayas et véhicules du pool présents dans la réponse.
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-opportunites-filtre.sh

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
fapi() { local m="$1" p="$2"
  curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_TOKEN"; }

OA=""; OB=""; OC=""; OD=""
cleanup() {
  for o in "$OA" "$OB" "$OC" "$OD"; do
    [ -n "$o" ] && mapi POST "/commercant/commandes/$o/annuler" "{}" >/dev/null 2>&1 || true
  done
}

# Publie une course DIFFUSEE (draft puis publier) -> fleetbaseOrderId sur stdout
# cod=0 => champ omis (le serveur refuse codAmount:0, cf. @Min(1)).
publish() { # province vehicle price cod
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n --arg p "$1" --arg v "$2" --argjson pr "$3" --argjson cod "$4" '{
    draft:true,
    pickupLocationName:"Depot Filtre", pickupLatitude:36.7719, pickupLongitude:3.0589,
    pickupContactName:"Commerce", pickupContactPhone:"0551020304", pickupProvince:$p,
    dropoffLocationName:"Client", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"0551020305",
    items:[{description:"colis", quantity:1}],
    vehicleType:$v, price:$pr, podMethod:"aucune"
  } + (if $cod > 0 then {codAmount:$cod, codIncludesDelivery:false} else {} end)')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 220)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

# La course $1 est-elle dans /flotte/opportunites avec la query $2 ? yes/no
opp_has() { fapi GET "/flotte/opportunites?limit=100&$2" \
  | jq -e --arg o "$1" '[.data[]?.uuid] | index($o)' >/dev/null 2>&1 && echo yes || echo no; }

# Rang de la course $1 dans la liste triée par la query $2 (-1 si absente)
opp_rank() { fapi GET "/flotte/opportunites?limit=100&$2" \
  | jq -r --arg o "$1" '([.data[]?.uuid] | index($o)) // -1'; }

echo "================================================================"
echo "  Filtres et tri de /flotte/opportunites"
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
pass "commercant + entreprise connectes"

step "Quatre courses diffusees"
OA="$(publish "Alger" "moto"       500  0)";    [[ "$OA" == ERR:* ]] && fail "publish OA" "$OA"
OB="$(publish "Blida" "utilitaire" 3000 2500)"; [[ "$OB" == ERR:* ]] && fail "publish OB" "$OB"
OC="$(publish "Alger" "moto"       1200 0)";    [[ "$OC" == ERR:* ]] && fail "publish OC" "$OC"
OD="$(publish "Alger" "voiture"    800  0)";    [[ "$OD" == ERR:* ]] && fail "publish OD" "$OD"
pass "OA=Alger/moto/500  OB=Blida/util/3000+cod  OC=Alger/moto/1200  OD=Alger/voiture/800"

step "Sans filtre : les quatre visibles (controle positif)"
for pair in "OA $OA" "OB $OB" "OC $OC" "OD $OD"; do
  n="${pair%% *}"; u="${pair##* }"
  [ "$(opp_has "$u" "")" = "yes" ] || fail "$n absente SANS filtre — decor ou visibilite en cause"
done
pass "OA OB OC OD toutes dans le pool"

step "wilaya=Alger : Alger visibles, Blida cachee"
[ "$(opp_has "$OA" "wilaya=Alger")" = "yes" ] || fail "wilaya=Alger : OA a disparu (filtre trop large)"
[ "$(opp_has "$OC" "wilaya=Alger")" = "yes" ] || fail "wilaya=Alger : OC a disparu"
[ "$(opp_has "$OB" "wilaya=Alger")" = "no"  ] || fail "wilaya=Alger : OB (Blida) visible — le filtre ne filtre pas"
pass "Alger visibles, Blida cachee"

step "wilaya=Blida : Blida visible, Alger cachees (symetrie)"
[ "$(opp_has "$OB" "wilaya=Blida")" = "yes" ] || fail "wilaya=Blida : OB a disparu"
[ "$(opp_has "$OA" "wilaya=Blida")" = "no"  ] || fail "wilaya=Blida : OA (Alger) visible"
[ "$(opp_has "$OC" "wilaya=Blida")" = "no"  ] || fail "wilaya=Blida : OC (Alger) visible"
pass "le filtre decide sur la wilaya declaree, pas l identite"

step "vehicleType=moto : egalite EXACTE (utilitaire ET voiture cachees)"
[ "$(opp_has "$OA" "vehicleType=moto")" = "yes" ] || fail "vehicleType=moto : OA a disparu"
[ "$(opp_has "$OC" "vehicleType=moto")" = "yes" ] || fail "vehicleType=moto : OC a disparu"
[ "$(opp_has "$OB" "vehicleType=moto")" = "no"  ] || fail "vehicleType=moto : OB (utilitaire) visible"
[ "$(opp_has "$OD" "vehicleType=moto")" = "no"  ] || fail "vehicleType=moto : OD (voiture) visible — ce n est PAS l echelle du pool"
pass "seules les courses exigeant moto restent"

step "vehicleType=utilitaire : seule OB"
[ "$(opp_has "$OB" "vehicleType=utilitaire")" = "yes" ] || fail "vehicleType=utilitaire : OB a disparu"
[ "$(opp_has "$OA" "vehicleType=utilitaire")" = "no"  ] || fail "vehicleType=utilitaire : OA (moto) visible"
pass "OB seule"

step "withoutCod=true : la course a encaisser est cachee"
[ "$(opp_has "$OA" "withoutCod=true")" = "yes" ] || fail "withoutCod : OA (cod 0) a disparu"
[ "$(opp_has "$OC" "withoutCod=true")" = "yes" ] || fail "withoutCod : OC (cod 0) a disparu"
[ "$(opp_has "$OB" "withoutCod=true")" = "no"  ] || fail "withoutCod : OB (cod 2500) visible"
pass "seules les courses sans encaissement restent"

step "sort=best_paid : prix decroissant sur nos reperes (OB 3000 > OC 1200 > OA 500)"
rb="$(opp_rank "$OB" "sort=best_paid")"
rc="$(opp_rank "$OC" "sort=best_paid")"
ra="$(opp_rank "$OA" "sort=best_paid")"
{ [ "$rb" -ge 0 ] && [ "$rc" -ge 0 ] && [ "$ra" -ge 0 ]; } || fail "sort=best_paid : un repere absent (rb=$rb rc=$rc ra=$ra)"
{ [ "$rb" -lt "$rc" ] && [ "$rc" -lt "$ra" ]; } || fail "sort=best_paid : ordre KO (OB=$rb OC=$rc OA=$ra, attendu croissant)"
pass "OB avant OC avant OA"

step "sort inconnu : ne casse rien, les quatre repondent"
for pair in "OA $OA" "OB $OB" "OC $OC" "OD $OD"; do
  n="${pair%% *}"; u="${pair##* }"
  [ "$(opp_has "$u" "sort=nimportequoi")" = "yes" ] || fail "sort inconnu : $n a disparu (devrait retomber sur l ordre naturel)"
done
pass "valeur de tri inconnue => ordre naturel, aucune course perdue"

step "wilaya inconnue (Tamanrasset) : nos quatre courses absentes"
for pair in "OA $OA" "OB $OB" "OC $OC" "OD $OD"; do
  n="${pair%% *}"; u="${pair##* }"
  [ "$(opp_has "$u" "wilaya=Tamanrasset")" = "no" ] || fail "wilaya=Tamanrasset : $n visible — le parametre est IGNORE"
done
pass "le parametre wilaya est bien honore (0 de nos reperes)"

step "facets : wilayas et vehicules du pool presents dans la reponse"
FAC="$(fapi GET "/flotte/opportunites?limit=100&wilaya=Alger")"
echo "$FAC" | jq -e '(.facets.wilayas | map(ascii_downcase)) as $w | ($w | index("alger")) and ($w | index("blida"))' >/dev/null \
  || fail "facets.wilayas ne contient pas Alger ET Blida (calcule AVANT filtrage ?)" "$(echo "$FAC" | jq -c '.facets')"
echo "$FAC" | jq -e '(.facets.vehicleTypes | map(ascii_downcase)) as $v | ($v|index("moto")) and ($v|index("utilitaire")) and ($v|index("voiture"))' >/dev/null \
  || fail "facets.vehicleTypes incomplet" "$(echo "$FAC" | jq -c '.facets')"
pass "facets stables : tout le pool, malgre le filtre wilaya=Alger"

step "combine wilaya=Alger + vehicleType=moto + withoutCod=true"
Q="wilaya=Alger&vehicleType=moto&withoutCod=true"
[ "$(opp_has "$OA" "$Q")" = "yes" ] || fail "combine : OA a disparu"
[ "$(opp_has "$OC" "$Q")" = "yes" ] || fail "combine : OC a disparu"
[ "$(opp_has "$OB" "$Q")" = "no"  ] || fail "combine : OB visible"
[ "$(opp_has "$OD" "$Q")" = "no"  ] || fail "combine : OD (voiture) visible"
pass "les trois filtres s appliquent ensemble : OA + OC seulement"

cleanup
echo
echo "================================================================"
echo "OK  wilaya, vehicule (egalite exacte), sans-encaissement et tri"
echo "    filtrent cote serveur avant pagination — temoin a chaque axe."
echo "================================================================"
