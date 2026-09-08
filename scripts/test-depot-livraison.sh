#!/usr/bin/env bash
#
# Livraison d'un commerçant VERS un dépôt de transporteur (spec §3.2).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# `destinationType: 'depot'` + `depotUuid` : la course a pour dépose le `Place`
# du dépôt (aucun `Place` de livraison créé), elle est CONFIÉE d'office au
# transporteur propriétaire (`facilitator`), elle ne part pas au pool, et
# l'encaissement y est interdit. Le dépôt doit appartenir à un transporteur du
# RÉSEAU du commerçant (un favori entreprise).
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • vers dépôt      → payload.dropoff = le Place du dépôt (uuid exact),
#                       facilitator_uuid = le Vendor du transporteur, adhoc=false ;
#   • contraste       → la MÊME course en 'client' part au pool (adhoc=true) ;
#   • COD interdit    → destinationType:'depot' + codAmount → 400
#                       order.cod_to_depot_forbidden ;
#   • hors réseau     → un dépôt d'un transporteur NON favori → 400
#                       order.depot_not_in_network.
#
# Mutation : forcer `resolveDestinationDepot` à accepter n'importe quel dépôt
# (retirer le filtre favoris) fait passer l'étape « hors réseau » — donc échouer.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-depot-livraison.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
FLEET_A="${FLEET:-app-parcours-entreprise@echango.local}"
FLEET_B="${FLEET_B_EMAIL:-appartenance-entreprise-b@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "OK $1"; }
fail() { echo "XX $1"; [ -n "${2:-}" ] && echo "   $2"; cleanup; exit 1; }
step() { echo; echo "-- $1 --"; }

. "$HERE/lib/fleetbase.sh"

DEPOT_A=""; DEPOT_B=""; ORD_DEPOT=""; ORD_CLIENT=""
cleanup() {
  for o in "$ORD_DEPOT" "$ORD_CLIENT"; do
    [ -n "$o" ] && curl -sS -X POST "$BFF_URL/commercant/commandes/$o/annuler" -H "Authorization: Bearer $M_TOKEN" -d '{}' >/dev/null 2>&1 || true
  done
  [ -n "$DEPOT_A" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_A" -H "Authorization: Bearer $A_TOKEN" >/dev/null 2>&1 || true
  [ -n "$DEPOT_B" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_B" -H "Authorization: Bearer $B_TOKEN" >/dev/null 2>&1 || true
  [ -n "${VENDOR_A:-}" ] && curl -sS -X DELETE "$BFF_URL/commercant/transporteurs/favoris/$VENDOR_A" -H "Authorization: Bearer $M_TOKEN" >/dev/null 2>&1 || true
}

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H "Content-Type: application/json" -H "Authorization: Bearer $M_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $M_TOKEN"; fi; }
m_code() { curl -sS -o /tmp/depot_resp -w '%{http_code}' -X "$1" "$BFF_URL$2" -H "Content-Type: application/json" -H "Authorization: Bearer $M_TOKEN" -d "$3"; }
login() { curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty'; }

# corps d'une commande, destinationType/depotUuid/codAmount surchargés via $1 (objet jq)
order_body() { jq -n --argjson over "$1" '{
  pickupLocationName:"Boulangerie", pickupLatitude:36.7719, pickupLongitude:3.0589,
  pickupContactName:"Commerce", pickupContactPhone:"0551020304", pickupProvince:"Alger",
  dropoffLocationName:"Client", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"0551020305",
  items:[{description:"colis", quantity:1}], price:700, podMethod:"aucune"
} + $over'; }

echo "================================================================"
echo "  Livraison commerçant → dépôt de transporteur (spec §3.2)"
echo "================================================================"

step "Décor : comptes"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
M_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty')"
A_TOKEN="$(login "$FLEET_A")"
B_TOKEN="$(login "$FLEET_B")"
if [ -z "$B_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" -H "Content-Type: application/json" -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p,businessName:"Flotte témoin dépôt livraison"}')"
  fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
  B_TOKEN="$(login "$FLEET_B")"
fi
[ -n "$M_TOKEN" ] && [ -n "$A_TOKEN" ] && [ -n "$B_TOKEN" ] || fail "connexions incomplètes (M=$([ -n "$M_TOKEN" ]&&echo ok) A=$([ -n "$A_TOKEN" ]&&echo ok) B=$([ -n "$B_TOKEN" ]&&echo ok))"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor A introuvable"
pass "commerçant + transporteurs A et B connectés"

step "A et B créent chacun un dépôt"
DEPOT_A="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" \
  -d '{"name":"Dépôt A Alger","latitude":36.7600,"longitude":3.0500,"phone":"021000001","contactName":"Chef A","province":"Alger"}' | jq -r '.uuid // empty')"
DEPOT_B="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $B_TOKEN" \
  -d '{"name":"Dépôt B Oran","latitude":35.6970,"longitude":-0.6300,"phone":"041000002","contactName":"Chef B","province":"Oran"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT_A" ] && [ -n "$DEPOT_B" ] || fail "création dépôt(s) échouée (A=$DEPOT_A B=$DEPOT_B)"
pass "Dépôt A ${DEPOT_A:0:8}…  Dépôt B ${DEPOT_B:0:8}…"

step "Le commerçant met le transporteur A en favori (party_type fleet)"
mapi DELETE "/commercant/transporteurs/favoris/$VENDOR_A" >/dev/null 2>&1 || true
mapi POST /commercant/transporteurs/favoris "$(jq -n --arg u "$VENDOR_A" '{fleetbaseDriverUuid:$u, partyType:"fleet"}')" \
  | jq -e '.added == true' >/dev/null || fail "mise en favori de A refusée"
pass "A est favori du commerçant"

step "Course VERS le dépôt A"
resp="$(mapi POST /commercant/commandes "$(order_body "$(jq -n --arg d "$DEPOT_A" '{destinationType:"depot", depotUuid:$d}')")")"
ORD_DEPOT="$(echo "$resp" | jq -r '.fleetbaseOrderId // .uuid // empty')"
[ -n "$ORD_DEPOT" ] || fail "création course vers dépôt échouée" "$(echo "$resp" | head -c 300)"
o="$(fb_get "/int/v1/orders/$ORD_DEPOT" | jq -c '(.order//.data//.) | {adhoc, facilitator_uuid, dropoff:(.payload.dropoff.uuid // .payload.dropoff_uuid), dropoff_prov:(.payload.dropoff.province)}')"
[ "$(echo "$o" | jq -r '.dropoff')" = "$DEPOT_A" ] || fail "payload.dropoff ≠ le Place du dépôt A" "$o"
[ "$(echo "$o" | jq -r '.facilitator_uuid')" = "$VENDOR_A" ] || fail "facilitator_uuid ≠ Vendor A" "$o"
[ "$(echo "$o" | jq -r '.adhoc')" = "false" ] || fail "adhoc devrait être false (course confiée)" "$o"
# pas dans le pool ; visible dans les commandes de A
if curl -sS "$BFF_URL/flotte/opportunites?limit=100" -H "Authorization: Bearer $A_TOKEN" | jq -e --arg x "$ORD_DEPOT" '[.data[]?.uuid] | index($x)' >/dev/null; then
  fail "la course vers dépôt apparaît dans les opportunités du pool"
fi
curl -sS "$BFF_URL/flotte/commandes?limit=100" -H "Authorization: Bearer $A_TOKEN" | jq -e --arg x "$ORD_DEPOT" '[.data[]?.uuid] | index($x)' >/dev/null \
  || fail "la course vers dépôt n'apparaît pas dans /flotte/commandes de A"
pass "dropoff = dépôt A, facilitator = A, adhoc=false, hors pool, vue par A"

step "Contraste : la MÊME course en 'client' part au pool"
resp="$(mapi POST /commercant/commandes "$(order_body '{}')")"
ORD_CLIENT="$(echo "$resp" | jq -r '.fleetbaseOrderId // .uuid // empty')"
[ -n "$ORD_CLIENT" ] || fail "création course client échouée"
[ "$(fb_get "/int/v1/orders/$ORD_CLIENT" | jq -r '(.order//.data//.).adhoc')" = "true" ] \
  || fail "une course 'client' sans favori devrait être adhoc=true"
pass "course 'client' → adhoc=true (diffusée)"

step "Refus : encaissement vers un dépôt"
code="$(m_code POST /commercant/commandes "$(order_body "$(jq -n --arg d "$DEPOT_A" '{destinationType:"depot", depotUuid:$d, codAmount:2000}')")")"
[ "$code" = "400" ] || fail "COD vers dépôt : HTTP $code (attendu 400)"
[ "$(jq -r '.code // empty' </tmp/depot_resp)" = "order.cod_to_depot_forbidden" ] \
  || fail "code ≠ order.cod_to_depot_forbidden" "$(cat /tmp/depot_resp)"
pass "COD vers dépôt refusé (order.cod_to_depot_forbidden)"

step "Refus : dépôt hors réseau (dépôt B, B non favori)"
code="$(m_code POST /commercant/commandes "$(order_body "$(jq -n --arg d "$DEPOT_B" '{destinationType:"depot", depotUuid:$d}')")")"
[ "$code" = "400" ] || fail "dépôt hors réseau : HTTP $code (attendu 400)"
[ "$(jq -r '.code // empty' </tmp/depot_resp)" = "order.depot_not_in_network" ] \
  || fail "code ≠ order.depot_not_in_network" "$(cat /tmp/depot_resp)"
pass "dépôt d'un transporteur non favori refusé (order.depot_not_in_network)"

cleanup
echo
echo "================================================================"
echo "OK  une livraison vers un dépôt : dropoff = le dépôt, confiée à"
echo "    son transporteur, hors pool ; COD interdit ; hors réseau refusé."
echo "================================================================"
