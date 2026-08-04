#!/usr/bin/env bash
#
# Cibler une course sur un favori ENTREPRISE (facilitator) — la branche jamais
# jouée de bout en bout.
#
# ── Ce que ce banc éprouve, et pourquoi il pourrait trouver un défaut ─────────
#
# Un commerçant peut mettre en favori un CONDUCTEUR (`party_type:'driver'`) ou
# une ENTREPRISE de transport (`party_type:'fleet'`). Cibler un conducteur pose
# `driver_assigned_uuid` ; cibler une entreprise pose `facilitator_uuid` +
# `facilitator_type` et laisse `driver_assigned_uuid` NUL — l'entreprise choisira
# elle-même son conducteur. `test-visibilite-ciblage.sh` couvre le cas
# conducteur ; **le cas entreprise n'a jamais tourné e2e.**
#
# ⚠️ **C'est exactement la classe du défaut `(f:any)`** que le code met en garde
# (`commercant.service.ts:482`) : une branche écrite, typée `any`, jamais
# exercée, qui peut servir `undefined` en silence. On la joue donc en entier.
#
# ── Les quatre témoins ────────────────────────────────────────────────────────
#
#   A. la commande porte `facilitator_uuid = <vendor entreprise>`, `adhoc=false`,
#      `driver_assigned_uuid=null` — confiée à l'entreprise, hors du pool ;
#   B. l'entreprise la voit dans SES commandes (`/flotte/commandes`) et PAS dans
#      les opportunités du pool (`/flotte/opportunites`) — elle lui est confiée,
#      pas offerte ;
#   C. un conducteur indépendant reçoit 404 dessus — invisible au pool ;
#   D. l'entreprise affecte SON conducteur, et la course le porte.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-ciblage-entreprise.sh

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

order_state() { fb_get "/int/v1/orders/$1" | jq -c '(.order//.data//.) | {status, adhoc, driver_assigned_uuid, facilitator_uuid}'; }
driver_of()   { fb_get "/int/v1/orders/$1" | jq -r '(.order//.data//.).driver_assigned_uuid // "null"'; }
membership_id()     { fapi GET /flotte/adhesions | jq -r --arg d "$1" '[(.data // [])[] | select(.driver_uuid==$d)][0].id // empty'; }
membership_status() { fapi GET /flotte/adhesions | jq -r --arg d "$1" '[(.data // [])[] | select(.driver_uuid==$d)][0].status // "none"'; }
free_d() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }

echo "════════════════════════════════════════════════════════════════"
echo "  Ciblage d'un favori ENTREPRISE (facilitator)"
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

# Le Vendor Fleetbase de l'entreprise, retrouvé par email (même mécanique que
# `fb_activate_vendor_by_email`). C'est lui qu'on met en favori et qu'on cible.
FLEET_VENDOR="$(fb_get "/int/v1/vendors?email=$FLEET&limit=100" \
  | jq -r --arg e "$FLEET" '(.vendors // .data // []) | map(select(.email == $e)) | last.uuid // empty')"
[ -n "$FLEET_VENDOR" ] || fail "Vendor de l'entreprise introuvable ($FLEET)"

# Un conducteur INDÉPENDANT pour l'entreprise (adhésion), et un AUTRE pour le
# témoin d'invisibilité.
mapfile -t DRV < <(_accounted_driver_uuids)
D_UUID=""
for d in "${DRV[@]}"; do
  vu="$(fb_get "/int/v1/drivers/$d" | jq -r '(.driver//.data//.).vendor_uuid // "null"')"
  if [ "$vu" = "null" ] || [ -z "$vu" ]; then D_UUID="$d"; break; fi
done
[ -n "$D_UUID" ] || fail "Aucun conducteur indépendant parmi les comptes"
W_UUID=""; for d in "${DRV[@]}"; do [ "$d" != "$D_UUID" ] && { W_UUID="$d"; break; }; done
[ -n "$W_UUID" ] || fail "Un second conducteur (témoin d'invisibilité) requis"

free_d "$D_UUID"
obtain_driver_token "$D_UUID" >/dev/null 2>&1 || fail "Jeton D impossible" "${DRIVER_SESSION_ERROR:-}"
D_TOKEN="$DRIVER_TOKEN"
obtain_driver_token "$W_UUID" >/dev/null 2>&1 || fail "Jeton W impossible" "${DRIVER_SESSION_ERROR:-}"
W_TOKEN="$DRIVER_TOKEN"
pass "Commerçant, entreprise (vendor ${FLEET_VENDOR:0:8}…), D indépendant (${D_UUID:0:8}…), témoin W (${W_UUID:0:8}…)"

# ── L'adhésion D↔entreprise amenée à ACTIVE (pour le témoin D) ───────────────
step "Adhésion de D active"
case "$(membership_status "$D_UUID")" in
  active)    : ;;
  suspended) fapi POST "/flotte/adhesions/$(membership_id "$D_UUID")/reactiver" '{}' >/dev/null ;;
  pending)   dapi POST "/transporteur/entreprises/$(membership_id "$D_UUID")/accepter" '{}' >/dev/null ;;
  *)         fapi POST "/flotte/conducteurs/$D_UUID/adhesion" '{}' >/dev/null
             mid="$(membership_id "$D_UUID")"; [ -n "$mid" ] || fail "Invitation sans adhésion"
             dapi POST "/transporteur/entreprises/$mid/accepter" '{}' >/dev/null ;;
esac
[ "$(membership_status "$D_UUID")" = "active" ] || fail "Adhésion de D non active" "état: $(membership_status "$D_UUID")"
pass "D est membre actif de l'entreprise"

# ── L'entreprise en favori du commerçant ────────────────────────────────────
step "L'entreprise mise en favori (party_type fleet)"
mapi DELETE "/commercant/transporteurs/favoris/$FLEET_VENDOR" >/dev/null 2>&1 || true
add="$(mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$FLEET_VENDOR" '{fleetbaseDriverUuid:$u, partyType:"fleet"}')")"
echo "$add" | jq -e '.added == true' >/dev/null 2>&1 \
  || fail "Mise en favori de l'entreprise refusée" "$(echo "$add" | jq -c '{code,message}')"
mapi GET /commercant/transporteurs/favoris \
  | jq -e --arg u "$FLEET_VENDOR" '[.data[]? | select(.driver_uuid==$u and .party_type=="fleet")] | length == 1' >/dev/null \
  || fail "L'entreprise n'apparaît pas en favori fleet" "$(mapi GET /commercant/transporteurs/favoris | jq -c '.data')"
pass "Entreprise favori (party_type=fleet)"

# ── La course ciblée sur l'entreprise ───────────────────────────────────────
step "Course ciblée sur l'entreprise"
resp="$(mapi POST /commercant/commandes "$(jq -n --arg t "$FLEET_VENDOR" '{
  pickupLocationName:"Dépôt Facilitateur", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Facilitateur", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:700, podMethod:"aucune",
  targetFavouriteUuid:$t }')")"
C="$(echo "$resp" | jq -r '.fleetbaseOrderId // .uuid // empty')"
[ -n "$C" ] || fail "Création ciblée entreprise échouée" "$(echo "$resp" | head -c 300)"
pass "Course créée : $C"
echo "   état : $(order_state "$C")"

# ── Témoin A : facilitator posé, hors pool, sans conducteur ─────────────────
step "A — confiée à l'entreprise, hors du pool"
as="$(order_state "$C")"
[ "$(echo "$as" | jq -r '.facilitator_uuid')" = "$FLEET_VENDOR" ] \
  || fail "facilitator_uuid ≠ vendor entreprise" "$as"
[ "$(echo "$as" | jq -r '.adhoc')" = "false" ] \
  || fail "adhoc devrait être false (course confiée)" "$as"
[ "$(echo "$as" | jq -r '.driver_assigned_uuid')" = "null" ] \
  || fail "driver_assigned_uuid devrait être null (l'entreprise choisit)" "$as"
pass "facilitator = entreprise, adhoc=false, aucun conducteur encore"

# ── Témoin B : l'entreprise la voit dans SES commandes, pas dans le pool ────
#
# ⚠️ Le contrat flotte sert ses collections sous `{data:[…]}` (comme
# `/flotte/adhesions`), PAS sous `{orders:[…]}` comme le contrat transporteur.
step "B — l'entreprise la voit dans ses commandes, pas dans les opportunités"
fapi GET "/flotte/commandes?limit=100" | jq -e --arg o "$C" '[.data[]?.uuid] | index($o)' >/dev/null \
  || fail "L'entreprise ne voit PAS la course confiée dans /flotte/commandes" \
     "$(fapi GET '/flotte/commandes?limit=100' | jq -c '[.data[]?.uuid][:5]')"
if fapi GET "/flotte/opportunites?limit=100" | jq -e --arg o "$C" '[.data[]?.uuid] | index($o)' >/dev/null; then
  fail "La course confiée apparaît AUSSI dans les opportunités du pool — elle n'est plus « confiée »"
fi
pass "Vue dans /flotte/commandes, absente de /flotte/opportunites"

# ── Témoin C : un conducteur indépendant ne la voit pas ─────────────────────
step "C — invisible à un conducteur du pool"
wcode="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$C" -H "Authorization: Bearer $W_TOKEN")"
[ "$wcode" = "404" ] || fail "Le témoin W devrait avoir 404 (invisible), a eu $wcode"
pass "W ne voit pas la course (404, pas 403)"

# ── Témoin D : l'entreprise affecte son conducteur ──────────────────────────
step "D — l'entreprise affecte son conducteur D"
r="$(fapi POST "/flotte/commandes/$C/assigner" "$(jq -n --arg d "$D_UUID" '{driverId:$d}')")"
echo "$r" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "L'entreprise n'a pas pu affecter son conducteur" "$(echo "$r" | jq -c '{code,message}')"
[ "$(driver_of "$C")" = "$D_UUID" ] \
  || fail "La course n'est pas portée par D après affectation" "porteur: $(driver_of "$C")"
pass "TÉMOIN : l'entreprise a confié la course à son conducteur D"

# ── Ménage ──────────────────────────────────────────────────────────────────
mapi POST "/commercant/commandes/$C/annuler" '{}' >/dev/null 2>&1 || true
mapi DELETE "/commercant/transporteurs/favoris/$FLEET_VENDOR" >/dev/null 2>&1 || true
free_d "$D_UUID"

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Cibler une ENTREPRISE la pose en facilitateur, hors du pool :"
echo "   elle voit la course, le pool non, et elle l'affecte à son conducteur."
echo "════════════════════════════════════════════════════════════════"
