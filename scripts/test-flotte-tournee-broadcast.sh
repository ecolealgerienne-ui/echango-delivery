#!/usr/bin/env bash
#
# Une ENTREPRISE diffuse une tournée au POOL (spec §4.6 point 4).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# `POST /flotte/tournees` avec `broadcast: true` et aucune cible : la tournée
# part au pool comme une course adhoc. Le verrou d'architecture — le modèle
# `Order` exigeait un `merchantId` — est levé par `Order.merchantId` nullable +
# `Order.fleetId` : une ligne locale relie la diffusion à sa créatrice, sans
# quoi `GET /flotte/commandes` (filtré sur `facilitator`) ne la verrait pas,
# puisqu'une course diffusée n'a PAS de `facilitator_uuid`.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • diffusion   → l'ordre Fleetbase : adhoc = true, facilitator_uuid = null,
#                   driver_assigned_uuid = null, customer_uuid = le Vendor de
#                   l'entreprise ;
#   • ligne locale→ la tournée diffusée apparaît dans GET /flotte/commandes de
#                   sa créatrice (impossible sans la ligne `fleetId` : pas de
#                   facilitator à filtrer) ;
#   • détail      → GET /flotte/commandes/:id : 200 pour la créatrice,
#                   403 order.forbidden pour une autre entreprise ;
#   • contraste   → la MÊME tournée avec `targetUuid` : adhoc = false,
#                   facilitator_uuid = le Vendor, AUCUNE ligne locale (elle se
#                   retrouve par le facilitator) ;
#   • forme       → une tournée diffusée d'un seul arrêt → 400.
#
# ── Mutation qui DOIT faire échouer ce banc ────────────────────────────────
#
#   Dans `flotte.service.createTournee`, supprimer l'appel à
#   `createBroadcastCache` (ou forcer `broadcast = false`) : la tournée est
#   toujours créée chez Fleetbase mais AUCUNE ligne locale n'est écrite — le
#   témoin « ligne locale » échoue (la tournée disparaît de /flotte/commandes).
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-flotte-tournee-broadcast.sh

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

DEPOT_A=""; ORD_DIFF=""; ORD_TARGET=""
# Le conteneur Postgres du BFF, pour retirer la ligne locale `Order.fleetId`
# écrite par la diffusion — sinon `getOrders` de cette flotte reste sur le
# parcours complet à chaque scénario suivant. `test-commercant-tournee.sh`
# laisse fuir les siennes ; ici on nettoie parce que la ligne force un chemin.
BFF_PG="${BFF_PG_CONTAINER:-echango_bff_postgres}"
cleanup() {
  for o in "$ORD_DIFF" "$ORD_TARGET"; do
    [ -n "$o" ] && fb_api PUT "/int/v1/orders/$o" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
    [ -n "$o" ] && docker exec "$BFF_PG" psql -U bff_user -d echango_bff -tAc \
      "DELETE FROM \"Order\" WHERE \"fleetbaseOrderId\" = '$o';" >/dev/null 2>&1 || true
  done
  [ -n "$DEPOT_A" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_A" -H "Authorization: Bearer $A_TOKEN" >/dev/null 2>&1 || true
}

login() { curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty'; }
t_code() { curl -sS -o /tmp/fbt_resp -w '%{http_code}' -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$1"; }
fb_order() { fb_get "/int/v1/orders/$1?with[]=payload" | jq -c '(.order//.data//.)'; }

echo "================================================================"
echo "  Une entreprise diffuse une tournée au pool (spec §4.6 pt 4)"
echo "================================================================"

step "Décor : entreprises A et B, dépôt de A, un conducteur de A"
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
A_TOKEN="$(login "$FLEET_A")"
B_TOKEN="$(login "$FLEET_B")"
if [ -z "$B_TOKEN" ]; then
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" -H "Content-Type: application/json" -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p,businessName:"Flotte témoin diffusion"}')"
  fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
  B_TOKEN="$(login "$FLEET_B")"
fi
[ -n "$A_TOKEN" ] && [ -n "$B_TOKEN" ] || fail "connexions incomplètes"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor A introuvable"
DEPOT_A="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d '{"name":"Dépôt Diffusion A","latitude":36.7550,"longitude":3.0450,"phone":"021000030","contactName":"Chef A","province":"Alger"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT_A" ] || fail "création dépôt échouée"
DRV_A="$(curl -sS "$BFF_URL/flotte/drivers" -H "Authorization: Bearer $A_TOKEN" | jq -r '(.data // .)[0].uuid // empty')"
pass "A (vendor ${VENDOR_A:0:8}…, dépôt ${DEPOT_A:0:8}…, conducteur ${DRV_A:0:8}…), B connectée"

STOPS='[
  { "depotUuid": "'"$DEPOT_A"'", "type": "pickup", "items": [ { "description": "carton", "quantity": 1 } ] },
  { "locationName": "Client 1", "latitude": 36.7300, "longitude": 3.0700, "contactName": "Client 1", "contactPhone": "0555111222", "province": "Alger", "codAmount": 900 },
  { "locationName": "Client 2", "latitude": 36.7100, "longitude": 3.1000, "contactName": "Client 2", "contactPhone": "0555333444", "province": "Alger", "codAmount": 600 }
]'

# ─────────────────────────────────────────────────────────────────────────────
step "Diffusion : broadcast:true, aucune cible → tournée adhoc, sans facilitator"
resp="$(curl -sS -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$(jq -n --argjson s "$STOPS" '{price:3500, broadcast:true, stops:$s}')")"
ORD_DIFF="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$ORD_DIFF" ] || fail "création (diffusion) échouée" "$(echo "$resp" | head -c 400)"
o="$(fb_order "$ORD_DIFF")"
[ "$(echo "$o" | jq -r '.adhoc')" = "true" ] || fail "adhoc ≠ true (tournée non diffusée)" "$(echo "$o" | jq -c '{adhoc,facilitator_uuid,driver_assigned_uuid}')"
[ "$(echo "$o" | jq -r '.facilitator_uuid // "null"')" = "null" ] || fail "un facilitator est posé sur une tournée diffusée" "$o"
[ "$(echo "$o" | jq -r '.driver_assigned_uuid // "null"')" = "null" ] || fail "un conducteur est assigné sur une tournée diffusée" "$o"
[ "$(echo "$o" | jq -r '.customer_uuid')" = "$VENDOR_A" ] || fail "customer_uuid ≠ Vendor A" "$o"
[ "$(echo "$o" | jq -r '.payload.waypoints | length')" = "3" ] || fail "payload.waypoints ≠ 3" "$o"
pass "adhoc=true, aucun facilitator, aucun conducteur, customer = Vendor A, 3 arrêts"

step "Ligne locale : la tournée diffusée apparaît dans GET /flotte/commandes de A"
curl -sS "$BFF_URL/flotte/commandes?limit=100" -H "Authorization: Bearer $A_TOKEN" | jq -e --arg x "$ORD_DIFF" '[.data[]?.uuid] | index($x)' >/dev/null \
  || fail "la tournée diffusée n'apparaît PAS dans /flotte/commandes de A — pas de ligne locale ?"
pass "vue par sa créatrice (impossible sans la ligne Order.fleetId)"

step "Détail : 200 pour la créatrice, 403 pour une autre entreprise"
ca="$(curl -sS -o /tmp/fbt_da -w '%{http_code}' "$BFF_URL/flotte/commandes/$ORD_DIFF" -H "Authorization: Bearer $A_TOKEN")"
[ "$ca" = "200" ] || fail "détail refusé à la créatrice : HTTP $ca" "$(cat /tmp/fbt_da)"
[ "$(jq -r '.payload.waypoints | length' </tmp/fbt_da)" = "3" ] || fail "le détail ne sert pas les 3 arrêts" "$(cat /tmp/fbt_da | head -c 300)"
cb="$(curl -sS -o /tmp/fbt_db -w '%{http_code}' "$BFF_URL/flotte/commandes/$ORD_DIFF" -H "Authorization: Bearer $B_TOKEN")"
[ "$cb" = "403" ] || [ "$cb" = "404" ] || fail "une autre entreprise atteint la tournée diffusée de A : HTTP $cb" "$(cat /tmp/fbt_db)"
pass "détail : créatrice 200, autre entreprise $cb"

# ─────────────────────────────────────────────────────────────────────────────
step "Contraste : la MÊME tournée CONFIÉE (targetUuid) → facilitator, pas adhoc"
if [ -n "$DRV_A" ]; then
  respt="$(curl -sS -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$(jq -n --argjson s "$STOPS" --arg drv "$DRV_A" '{price:3500, targetUuid:$drv, stops:$s}')")"
  ORD_TARGET="$(echo "$respt" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$ORD_TARGET" ] || fail "création (confiée) échouée" "$(echo "$respt" | head -c 300)"
  ot="$(fb_order "$ORD_TARGET")"
  [ "$(echo "$ot" | jq -r '.adhoc')" = "false" ] || fail "tournée confiée mais adhoc=true" "$ot"
  [ "$(echo "$ot" | jq -r '.facilitator_uuid')" = "$VENDOR_A" ] || fail "facilitator_uuid ≠ Vendor A sur une tournée confiée" "$ot"
  [ "$(echo "$ot" | jq -r '.driver_assigned_uuid')" = "$DRV_A" ] || fail "conducteur ciblé non appliqué" "$ot"
  pass "confiée : adhoc=false, facilitator = Vendor A, conducteur = ${DRV_A:0:8}…"
else
  echo "   (pas de conducteur dans la flotte A — contraste confié sauté)"
fi

step "Forme refusée : une tournée diffusée d'un seul arrêt"
code="$(t_code "$(jq -n --arg d "$DEPOT_A" '{ price: 500, broadcast: true, stops: [ { depotUuid: $d, type: "pickup" } ] }')")"
[ "$code" = "400" ] || fail "tournée diffusée à 1 arrêt : HTTP $code (attendu 400)" "$(cat /tmp/fbt_resp)"
pass "tournée diffusée d'un seul arrêt → 400"

cleanup
echo
echo "================================================================"
echo "OK  Une entreprise diffuse une tournée au pool : adhoc, sans"
echo "    facilitator ni conducteur, suivie par sa créatrice via une"
echo "    ligne locale Order.fleetId ; une autre entreprise n'y accède"
echo "    pas ; la même tournée ciblée reste confiée (facilitator)."
echo "================================================================"
