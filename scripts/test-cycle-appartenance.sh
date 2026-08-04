#!/usr/bin/env bash
#
# Cycle de vie de l'appartenance : ce qu'un DÉPART coupe, et ce qu'il ne coupe pas.
#
# ── Ce que ce banc éprouve, et la décision qu'il protège ───────────────────
#
# Une entreprise ne peut confier une course qu'à un conducteur qui LUI est
# rattaché — d'origine, ou par une adhésion ACTIVE (`fleetMayUseDriver`). Quand
# le conducteur QUITTE l'entreprise, la règle du code est nette et volontaire
# (`transporteur.service.ts::leaveFleet`) :
#
#   « Partir coupe les courses à venir, PAS ce qu'on doit. »
#
# Donc deux effets distincts, et il faut prouver LES DEUX :
#
#   1. la course DÉJÀ confiée n'est PAS arrachée — elle reste au conducteur,
#      visible de l'entreprise, menée à son terme (sinon une livraison en cours
#      s'évanouirait au moment où quelqu'un clique « quitter ») ;
#   2. une course à venir lui est REFUSÉE — `driver.forbidden`, un contrôle qui
#      dit non (règle 8), et le refus est réversible : réadhérer rouvre l'accès,
#      ce qui prouve qu'il portait sur le STATUT, pas sur l'identité.
#
# ⚠️ **Le piège qui fausserait tout** : après la première affectation, le
# conducteur est OCCUPÉ. Un refus ultérieur sortirait alors en
# `driver.unavailable` (occupé), pas en `driver.forbidden` (parti) — deux motifs
# que rien ne distingue à l'œil. On LIBÈRE donc le conducteur avant d'éprouver le
# refus d'appartenance, pour que le seul motif possible soit le départ.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-cycle-appartenance.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
FLEET="${FLEET:-app-parcours-entreprise@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }
fapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $FLEET_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_TOKEN"; fi; }
dapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $D_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $D_TOKEN"; fi; }

driver_of() { fb_get "/int/v1/orders/$1" | jq -r '(.order//.data//.).driver_assigned_uuid // "null"'; }
# ⚠️ **La pagination `?driver=` de Fleetbase est INSTABLE** : sans tri stable,
# deux `page=N` successives ne rendent pas le même sous-ensemble, et une course
# `started` de D peut n'apparaître sur AUCUNE page prise isolément tout en
# comptant contre elle dans `driverIsBusy` (qui balaie jusqu'à 50 pages). Un
# `free_d` mono-page rendait donc D « occupé » de façon fantôme. On balaie donc
# TOUTES les pages, et on répète le balayage : chaque annulation décale la
# fenêtre et fait remonter ce qu'un passage avait raté.
free_d() {
  local round p uuids u remaining
  for round in 1 2 3; do
    remaining=0
    for p in 1 2 3 4 5 6; do
      uuids="$(fb_get "/int/v1/orders?driver=$1&limit=100&page=$p" \
        | jq -r '[.orders[]? | select(.status != null and (.status|IN("completed","canceled","cancelled")|not))][].uuid')"
      for u in $uuids; do
        remaining=1
        fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
      done
    done
    [ "$remaining" -eq 0 ] && break
  done
}

publish() { # -> fleetbaseOrderId
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n '{
    pickupLocationName:"Dépôt Cycle", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Cycle", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis", quantity:1}], price:500, podMethod:"aucune", draft:true }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 160)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"; }

# Identifiant de l'adhésion de D dans cette flotte (ou vide). La liste est
# enveloppée dans `{data:[…]}` — le contrat sert les collections ainsi.
membership_id() { fapi GET /flotte/adhesions | jq -r --arg d "$1" '[(.data // [])[] | select(.driver_uuid==$d)][0].id // empty'; }
membership_status() { fapi GET /flotte/adhesions | jq -r --arg d "$1" '[(.data // [])[] | select(.driver_uuid==$d)][0].status // "none"'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Cycle de vie de l'appartenance — ce qu'un départ coupe"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
fb_activate_vendor_by_email "$FLEET" >/dev/null 2>&1 || true
FLEET_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$FLEET" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$FLEET_TOKEN" ] || fail "Connexion flotte impossible"

# Un conducteur INDÉPENDANT (non détenu par une entreprise) : c'est la seule
# population pour qui l'adhésion décide de l'accès. Un conducteur d'origine
# serait toujours utilisable, statut ou pas — il ne prouverait rien.
mapfile -t DRV < <(_accounted_driver_uuids)
D_UUID=""
for d in "${DRV[@]}"; do
  vu="$(fb_get "/int/v1/drivers/$d" | jq -r '(.driver//.data//.).vendor_uuid // "null"')"
  if [ "$vu" = "null" ] || [ -z "$vu" ]; then D_UUID="$d"; break; fi
done
[ -n "$D_UUID" ] || fail "Aucun conducteur indépendant parmi les comptes"
free_d "$D_UUID"
obtain_driver_token "$D_UUID" >/dev/null 2>&1 || fail "Jeton conducteur impossible" "${DRIVER_SESSION_ERROR:-}"
D_TOKEN="$DRIVER_TOKEN"
pass "Commerçant, flotte, conducteur indépendant D (${D_UUID:0:8}…)"

# ── Amener l'adhésion D↔flotte à ACTIVE, quel que soit l'état laissé ────────
step "Adhésion active (D accepte l'invitation de la flotte)"
st="$(membership_status "$D_UUID")"
case "$st" in
  active)    : ;;
  suspended) fapi POST "/flotte/adhesions/$(membership_id "$D_UUID")/reactiver" '{}' >/dev/null ;;
  pending)   dapi POST "/transporteur/entreprises/$(membership_id "$D_UUID")/accepter" '{}' >/dev/null ;;
  *)         fapi POST "/flotte/conducteurs/$D_UUID/adhesion" '{}' >/dev/null
             mid="$(membership_id "$D_UUID")"; [ -n "$mid" ] || fail "Invitation sans adhésion"
             dapi POST "/transporteur/entreprises/$mid/accepter" '{}' >/dev/null ;;
esac
MID="$(membership_id "$D_UUID")"
[ "$(membership_status "$D_UUID")" = "active" ] || fail "L'adhésion n'est pas active" "état: $(membership_status "$D_UUID")"
pass "Adhésion active (id ${MID:0:8}…)"

# ── Témoin POSITIF : membre actif → la flotte peut confier ─────────────────
step "Membre actif → la flotte confie une course"
C="$(publish)"; [[ "$C" == ERR:* ]] && fail "Publication C" "$C"
fapi POST "/flotte/opportunites/$C/prendre" '{}' >/dev/null
r="$(fapi POST "/flotte/commandes/$C/assigner" "$(jq -n --arg d "$D_UUID" '{driverId:$d}')")"
echo "$r" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Affectation à un membre actif refusée" "$(echo "$r" | jq -c '{code,message}')"
[ "$(driver_of "$C")" = "$D_UUID" ] || fail "La course n'est pas au conducteur" "porteur: $(driver_of "$C")"
pass "TÉMOIN : course C confiée à D (membre actif)"

# ── Le départ ──────────────────────────────────────────────────────────────
step "D quitte la flotte"
q="$(dapi POST "/transporteur/entreprises/$MID/quitter" '{}')"
[ "$(echo "$q" | jq -r '.status // empty')" = "declined" ] || fail "Le départ n'a pas pris" "$(echo "$q" | jq -c '.')"
pass "Adhésion passée à « declined »"

# ── Effet 1 : la course déjà confiée n'est PAS orpheline ───────────────────
step "La course déjà confiée SURVIT au départ (pas d'orphelin)"
[ "$(driver_of "$C")" = "$D_UUID" ] \
  || fail "Le départ a ARRACHÉ la course en cours — porteur: $(driver_of "$C")"
# Et l'entreprise la voit toujours dans sa liste (elle en répond encore).
seen="$(fapi GET "/flotte/commandes/$C" | jq -r '.uuid // .id // empty')"
[ -n "$seen" ] || fail "L'entreprise ne voit plus la course qu'elle a confiée"
pass "TÉMOIN : C reste à D, toujours visible de l'entreprise — « pas ce qu'on doit »"

# ── Effet 2 : une course à venir est REFUSÉE (règle 8) ─────────────────────
step "Une course À VENIR est refusée à l'ex-membre"
# On libère D de C d'abord : sinon le refus sortirait « occupé » et non « parti »
# (voir l'en-tête). C n'est plus la question ; le motif du refus, si.
# ⚠️ Annulation de C par son uuid CONNU, pas par le balayage `free_d` : la
# pagination `?driver=` instable rate parfois C, et D resterait occupé au pas
# suivant. Ici on sait exactement quoi annuler.
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
[ "$(driver_of "$C")" = "null" ] || fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
C2="$(publish)"; [[ "$C2" == ERR:* ]] && fail "Publication C2" "$C2"
fapi POST "/flotte/opportunites/$C2/prendre" '{}' >/dev/null
r2="$(fapi POST "/flotte/commandes/$C2/assigner" "$(jq -n --arg d "$D_UUID" '{driverId:$d}')")"
got="$(echo "$r2" | jq -r '.code // empty')"
[ "$got" = "driver.forbidden" ] || fail "L'affectation à un parti devrait être « driver.forbidden »" "code: « $got » — $(echo "$r2" | jq -c '{code,message}')"
[ "$(driver_of "$C2")" = "null" ] || fail "C2 a quand même été confiée" "porteur: $(driver_of "$C2")"
pass "TÉMOIN NÉGATIF : course à venir refusée (driver.forbidden), C2 sans porteur"

# ── Réversible : réadhérer rouvre l'accès (statut, pas identité) ────────────
step "Réadhésion → l'accès rouvre (le refus portait sur le STATUT)"
fapi POST "/flotte/conducteurs/$D_UUID/adhesion" '{}' >/dev/null
MID2="$(membership_id "$D_UUID")"
dapi POST "/transporteur/entreprises/$MID2/accepter" '{}' >/dev/null
[ "$(membership_status "$D_UUID")" = "active" ] || fail "Réadhésion non active"
r3="$(fapi POST "/flotte/commandes/$C2/assigner" "$(jq -n --arg d "$D_UUID" '{driverId:$d}')")"
echo "$r3" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Après réadhésion, l'affectation est encore refusée" "$(echo "$r3" | jq -c '{code,message}')"
[ "$(driver_of "$C2")" = "$D_UUID" ] || fail "C2 non confiée après réadhésion" "porteur: $(driver_of "$C2")"
pass "TÉMOIN : réadhésion rétablit l'accès — le même D, la même course, acceptée"

# ── Ménage ──
free_d "$D_UUID"
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
fb_api PUT "/int/v1/orders/$C2" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le départ coupe les courses À VENIR (driver.forbidden), jamais"
echo "   celle déjà confiée ; réadhérer rouvre l'accès. « Partir coupe"
echo "   les courses à venir, pas ce qu'on doit. »"
echo "════════════════════════════════════════════════════════════════"
