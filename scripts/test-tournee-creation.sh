#!/usr/bin/env bash
#
# Créer une TOURNÉE multi-arrêt (spec §4 depot_transporteur_national).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# `POST /flotte/tournees` : le transporteur compose une course à N arrêts —
# ici enlèvement au dépôt A, puis deux livraisons. Une SEULE commande
# Fleetbase, `payload.waypoints[]` ordonné, un seul `price`, un `codAmount`
# par arrêt.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • forme        → payload.waypoints a 3 entrées, ordre 0/1/2,
#                    types pickup/dropoff/dropoff, waypoint[0] = le Place du
#                    dépôt A ;
#   • propriété    → customer_uuid ET facilitator_uuid = le Vendor du
#                    transporteur ; ciblage conducteur appliqué ;
#   • encaissement → meta.cod_amount = SOMME des cod d'arrêt (1200 + 800),
#                    servie par la projection BFF (donc la route l'appelle) ;
#   • colis        → payload.entities : 3 colis, chacun avec destination_uuid ;
#                    le colis collecté à l'enlèvement est routé vers le DERNIER
#                    arrêt (multi-collecte : N enlèvements → 1 dépôt) ;
#   • visibilité   → la tournée est dans GET /flotte/commandes ;
#   • appartenance → un arrêt `depotUuid` d'un AUTRE transporteur → 404
#                    depot.not_found (règle 12), jamais la ressource d'autrui ;
#   • forme refusée→ une tournée d'un seul arrêt → 400 tournee.invalid_shape.
#
# ── Mutations qui DOIVENT faire échouer ce banc ────────────────────────────
#
#   • neutraliser le filtre `is_depot`/la map `depotByUuid` dans
#     `flotte.service.createTournee` (accepter tout uuid) → l'étape
#     « dépôt d'autrui » passe (201 au lieu de 404) ;
#   • dans `buildTourneeMeta`, remplacer la somme des cod par `stopCods[0].amount`
#     → le témoin `cod_amount = 2000` échoue.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-tournee-creation.sh

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
t_code() { curl -sS -o /tmp/trn_resp -w '%{http_code}' -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$1"; }

echo "================================================================"
echo "  Créer une tournée multi-arrêt (spec §4)"
echo "================================================================"

step "Décor : comptes + dépôts A et B + conducteur de A"
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
A_TOKEN="$(login "$FLEET_A")"
B_TOKEN="$(login "$FLEET_B")"
if [ -z "$B_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" -H "Content-Type: application/json" -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p,businessName:"Flotte témoin tournée"}')"
  fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
  B_TOKEN="$(login "$FLEET_B")"
fi
[ -n "$A_TOKEN" ] && [ -n "$B_TOKEN" ] || fail "connexions incomplètes"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor A introuvable"
DEPOT_A="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d '{"name":"Dépôt Tournée A","latitude":36.7550,"longitude":3.0450,"phone":"021000020","contactName":"Chef A","province":"Alger"}' | jq -r '.uuid // empty')"
DEPOT_B="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $B_TOKEN" -d '{"name":"Dépôt Tournée B","latitude":35.700,"longitude":-0.640,"phone":"041000021","contactName":"Chef B","province":"Oran"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT_A" ] && [ -n "$DEPOT_B" ] || fail "création dépôt(s) échouée"
DRV_A="$(curl -sS "$BFF_URL/flotte/drivers" -H "Authorization: Bearer $A_TOKEN" | jq -r '(.data // .)[0].uuid // empty')"
pass "A (vendor ${VENDOR_A:0:8}…, dépôt ${DEPOT_A:0:8}…, conducteur ${DRV_A:0:8}…), B (dépôt ${DEPOT_B:0:8}…)"

BODY_OK="$(jq -n --arg d "$DEPOT_A" --arg drv "$DRV_A" '{
  price: 3000,
  vehicleType: "moto",
  podMethod: "aucune",
  stops: [
    { depotUuid: $d, type: "pickup", items: [ { description: "carton 1", quantity: 2 } ] },
    { locationName: "Client Nord", latitude: 36.7300, longitude: 3.0700,
      contactName: "Client Nord", contactPhone: "0555111222", province: "Alger",
      items: [ { description: "colis A", quantity: 1 } ], codAmount: 1200 },
    { locationName: "Client Sud", latitude: 36.7000, longitude: 3.1200,
      contactName: "Client Sud", contactPhone: "0555333444", province: "Blida",
      items: [ { description: "colis B", quantity: 1 } ], codAmount: 800 }
  ]
} + (if ($drv|length) > 0 then { targetUuid: $drv } else {} end)')"

step "Le transporteur crée une tournée de 3 arrêts depuis son dépôt A"
resp="$(curl -sS -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$BODY_OK")"
ORD="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$ORD" ] || fail "création tournée échouée" "$(echo "$resp" | head -c 400)"
pass "tournée créée (${ORD:0:12}…)"

step "Forme : payload.waypoints ordonné, 1er arrêt = le dépôt A"
raw="$(fb_get "/int/v1/orders/$ORD?with[]=payload")"
o="$(echo "$raw" | jq -c '(.order//.data//.) | {
  customer_uuid, facilitator_uuid, driver: .driver_assigned_uuid,
  n: (.payload.waypoints | length),
  types: (.payload.waypoints | sort_by(.order) | map(.type)),
  first: (.payload.waypoints | sort_by(.order) | .[0].uuid),
  last: (.payload.waypoints | sort_by(.order) | .[-1].uuid),
  ents: (.payload.entities | length),
  ent_dests: (.payload.entities | map(.destination_uuid // .destination) | map(select(. != null)) | length),
  collected_dest: (.payload.entities | map(select(.meta.collected_at_stop == true)) | .[0].destination_uuid)
}')"
[ "$(echo "$o" | jq -r '.n')" = "3" ] || fail "waypoints ≠ 3" "$o"
[ "$(echo "$o" | jq -rc '.types')" = '["pickup","dropoff","dropoff"]' ] || fail "types d'arrêts inattendus" "$o"
[ "$(echo "$o" | jq -r '.first')" = "$DEPOT_A" ] || fail "1er arrêt ≠ le Place du dépôt A" "$o"
[ "$(echo "$o" | jq -r '.customer_uuid')" = "$VENDOR_A" ] || fail "customer_uuid ≠ Vendor A" "$o"
[ "$(echo "$o" | jq -r '.facilitator_uuid')" = "$VENDOR_A" ] || fail "facilitator_uuid ≠ Vendor A" "$o"
[ "$(echo "$o" | jq -r '.ents')" = "3" ] || fail "entities ≠ 3" "$o"
[ "$(echo "$o" | jq -r '.ent_dests')" = "3" ] || fail "un colis sans arrêt de destination" "$o"
[ "$(echo "$o" | jq -r '.collected_dest')" = "$(echo "$o" | jq -r '.last')" ] \
  || fail "le colis collecté à l'enlèvement n'est pas routé vers le dernier arrêt" "$o"
if [ -n "$DRV_A" ]; then
  [ "$(echo "$o" | jq -r '.driver')" = "$DRV_A" ] || fail "targetUuid (conducteur) non appliqué" "$o"
fi
pass "3 arrêts pickup/dropoff/dropoff, dépôt A en tête, colis collecté → dernier arrêt, customer = facilitator = Vendor A${DRV_A:+, conducteur assigné}"

step "Encaissement : la projection BFF sert la SOMME des cod d'arrêt"
proj="$(curl -sS "$BFF_URL/flotte/commandes/$ORD" -H "Authorization: Bearer $A_TOKEN")"
cod="$(echo "$proj" | jq -r '.meta.cod_amount // empty')"
wp="$(echo "$proj" | jq -r '.payload.waypoints | length')"
[ "$cod" = "2000" ] || fail "meta.cod_amount ≠ 2000 (1200 + 800)" "$(echo "$proj" | jq -c '{cod:.meta.cod_amount, isT:.meta.is_tournee}')"
[ "$wp" = "3" ] || fail "la projection BFF ne sert pas les 3 arrêts (route n'appelle pas la projection ?)" "$wp"
pass "meta.cod_amount = 2000, payload.waypoints = 3 via GET /flotte/commandes/:id"

step "Visibilité : la tournée est dans GET /flotte/commandes du transporteur"
curl -sS "$BFF_URL/flotte/commandes?limit=100" -H "Authorization: Bearer $A_TOKEN" | jq -e --arg x "$ORD" '[.data[]?.uuid] | index($x)' >/dev/null \
  || fail "la tournée n'apparaît pas dans /flotte/commandes de A"
pass "vue par A"

step "Appartenance : A ne peut pas mettre le dépôt de B dans sa tournée"
code="$(t_code "$(jq -n --arg d "$DEPOT_B" '{
  price: 1000,
  stops: [
    { depotUuid: $d, type: "pickup" },
    { locationName: "X", latitude: 36.73, longitude: 3.07, contactName: "X", contactPhone: "0555000000" }
  ]
}')")"
[ "$code" = "404" ] || fail "arrêt = dépôt de B : HTTP $code (attendu 404 depot.not_found)" "$(cat /tmp/trn_resp)"
[ "$(jq -r '.code // empty' </tmp/trn_resp)" = "depot.not_found" ] || fail "code ≠ depot.not_found" "$(cat /tmp/trn_resp)"
pass "dépôt d'un autre transporteur dans la tournée → 404 depot.not_found"

step "Forme refusée : une tournée d'un seul arrêt"
code="$(t_code "$(jq -n --arg d "$DEPOT_A" '{ price: 500, stops: [ { depotUuid: $d, type: "pickup" } ] }')")"
[ "$code" = "400" ] || fail "tournée à 1 arrêt : HTTP $code (attendu 400)" "$(cat /tmp/trn_resp)"
[ "$(jq -r '.code // empty' </tmp/trn_resp)" = "tournee.invalid_shape" ] \
  || [ "$(jq -r '.code // empty' </tmp/trn_resp)" = "validation.failed" ] \
  || fail "code inattendu pour une tournée à 1 arrêt" "$(cat /tmp/trn_resp)"
pass "tournée d'un seul arrêt → 400"

cleanup
echo
echo "================================================================"
echo "OK  tournée : 3 arrêts en une commande, dépôt A en tête, un seul"
echo "    prix, cod cumulé 2000, colis rattachés, vue par le transporteur ;"
echo "    le dépôt d'autrui et la tournée à un arrêt sont refusés."
echo "================================================================"
