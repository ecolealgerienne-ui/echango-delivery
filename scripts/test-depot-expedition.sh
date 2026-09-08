#!/usr/bin/env bash
#
# Le dépôt EXPÉDIE une course vers un client (spec §3.3).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# `POST /flotte/commandes` : le transporteur crée une course où `customer_uuid`
# est SON `Vendor` et `pickup` est un de SES dépôts (`assertOwnsDepot`). La
# course lui est confiée (`facilitator` = son `Vendor`), donc visible dans
# `GET /flotte/commandes` ; il peut cibler un de ses conducteurs.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • création      → payload.pickup = le Place du dépôt, customer_uuid ET
#                     facilitator_uuid = le Vendor du transporteur ;
#   • visibilité     → la course est dans GET /flotte/commandes du transporteur ;
#   • ciblage        → targetDriverUuid → la course porte driver_assigned_uuid ;
#   • appartenance   → un `pickupDepotUuid` d'un AUTRE transporteur → 404
#                     depot.not_found (règle 12), jamais la course d'autrui.
#
# Mutation : neutraliser `assertOwnsDepot` (accepter tout uuid) fait passer
# l'étape « dépôt d'autrui » — donc échouer.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-depot-expedition.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
FLEET_A="${FLEET:-app-parcours-entreprise@echango.local}"
FLEET_B="${FLEET_B_EMAIL:-appartenance-entreprise-b@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "OK $1"; }
fail() { echo "XX $1"; [ -n "${2:-}" ] && echo "   $2"; cleanup; exit 1; }
step() { echo; echo "-- $1 --"; }

. "$HERE/lib/fleetbase.sh"

DEPOT_A=""; DEPOT_B=""; ORD=""
cleanup() {
  [ -n "$ORD" ] && fb_api PUT "/int/v1/orders/$ORD" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
  [ -n "$DEPOT_A" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_A" -H "Authorization: Bearer $A_TOKEN" >/dev/null 2>&1 || true
  [ -n "$DEPOT_B" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_B" -H "Authorization: Bearer $B_TOKEN" >/dev/null 2>&1 || true
}

login() { curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty'; }
a_code() { curl -sS -o /tmp/exp_resp -w '%{http_code}' -X POST "$BFF_URL/flotte/commandes" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$1"; }

echo "================================================================"
echo "  Le dépôt expédie une course (spec §3.3)"
echo "================================================================"

step "Décor : comptes + dépôts A et B"
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
A_TOKEN="$(login "$FLEET_A")"
B_TOKEN="$(login "$FLEET_B")"
if [ -z "$B_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" -H "Content-Type: application/json" -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p,businessName:"Flotte témoin expédition"}')"
  fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
  B_TOKEN="$(login "$FLEET_B")"
fi
[ -n "$A_TOKEN" ] && [ -n "$B_TOKEN" ] || fail "connexions incomplètes"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor A introuvable"
DEPOT_A="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d '{"name":"Dépôt Exp A","latitude":36.7550,"longitude":3.0450,"phone":"021000010","contactName":"Chef A","province":"Alger"}' | jq -r '.uuid // empty')"
DEPOT_B="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $B_TOKEN" -d '{"name":"Dépôt Exp B","latitude":35.700,"longitude":-0.640,"phone":"041000011","contactName":"Chef B","province":"Oran"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT_A" ] && [ -n "$DEPOT_B" ] || fail "création dépôt(s) échouée"
DRV_A="$(curl -sS "$BFF_URL/flotte/drivers" -H "Authorization: Bearer $A_TOKEN" | jq -r '(.data // .)[0].uuid // empty')"
pass "A (vendor ${VENDOR_A:0:8}…, dépôt ${DEPOT_A:0:8}…, conducteur ${DRV_A:0:8}…), B (dépôt ${DEPOT_B:0:8}…)"

BODY_OK="$(jq -n --arg d "$DEPOT_A" --arg drv "$DRV_A" '{
  pickupDepotUuid:$d,
  dropoffLocationName:"Client Exp", dropoffLatitude:36.7300, dropoffLongitude:3.0700,
  dropoffContactName:"Client Exp", dropoffContactPhone:"0555111222", dropoffProvince:"Alger",
  items:[{description:"colis", quantity:1}], price:800, podMethod:"aucune"
} + (if ($drv|length) > 0 then {targetDriverUuid:$drv} else {} end))')"

step "Le transporteur crée une course depuis son dépôt A"
resp="$(curl -sS -X POST "$BFF_URL/flotte/commandes" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$BODY_OK")"
ORD="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$ORD" ] || fail "création échouée" "$(echo "$resp" | head -c 300)"
o="$(fb_get "/int/v1/orders/$ORD" | jq -c '(.order//.data//.) | {customer_uuid, facilitator_uuid, driver:.driver_assigned_uuid, pickup:(.payload.pickup.uuid // .payload.pickup_uuid)}')"
[ "$(echo "$o" | jq -r '.pickup')" = "$DEPOT_A" ] || fail "payload.pickup ≠ le Place du dépôt A" "$o"
[ "$(echo "$o" | jq -r '.customer_uuid')" = "$VENDOR_A" ] || fail "customer_uuid ≠ Vendor A" "$o"
[ "$(echo "$o" | jq -r '.facilitator_uuid')" = "$VENDOR_A" ] || fail "facilitator_uuid ≠ Vendor A" "$o"
if [ -n "$DRV_A" ]; then
  [ "$(echo "$o" | jq -r '.driver')" = "$DRV_A" ] || fail "targetDriverUuid non appliqué" "$o"
fi
pass "pickup = dépôt A, customer = facilitator = Vendor A${DRV_A:+, conducteur assigné}"

step "La course est visible dans GET /flotte/commandes du transporteur"
curl -sS "$BFF_URL/flotte/commandes?limit=100" -H "Authorization: Bearer $A_TOKEN" | jq -e --arg x "$ORD" '[.data[]?.uuid] | index($x)' >/dev/null \
  || fail "la course expédiée n'apparaît pas dans /flotte/commandes de A"
pass "vue par A"

step "Appartenance : A ne peut pas expédier depuis le dépôt de B"
code="$(a_code "$(jq -n --arg d "$DEPOT_B" '{
  pickupDepotUuid:$d,
  dropoffLocationName:"X", dropoffLatitude:36.73, dropoffLongitude:3.07,
  dropoffContactName:"X", dropoffContactPhone:"0555000000",
  items:[{description:"colis",quantity:1}], price:800, podMethod:"aucune"
}')")"
[ "$code" = "404" ] || fail "expédier depuis le dépôt de B : HTTP $code (attendu 404 depot.not_found)"
[ "$(jq -r '.code // empty' </tmp/exp_resp)" = "depot.not_found" ] || fail "code ≠ depot.not_found" "$(cat /tmp/exp_resp)"
pass "dépôt d'un autre transporteur → 404 depot.not_found"

cleanup
echo
echo "================================================================"
echo "OK  le dépôt expédie : pickup = le dépôt, customer = facilitator ="
echo "    le transporteur, vue par lui ; le dépôt d'autrui est refusé."
echo "================================================================"
