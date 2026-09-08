#!/usr/bin/env bash
#
# Le COMMERÇANT crée une tournée multi-arrêt (spec §4, `POST /commercant/tournees`).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# Comme la version flotte, mais : `customer` = le `Vendor` du commerçant, une
# **ligne `Order` locale** est écrite (le modèle Prisma l'exige), et la cible
# est un FAVORI. Aucune cible ⇒ diffusion au pool (`adhoc: true`), que le
# commerçant suit depuis sa liste grâce à la ligne locale.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • diffusion    → sans cible : adhoc=true, aucun facilitator, aucun driver,
#                    customer_uuid = le Vendor du commerçant ;
#   • ligne locale → la réponse porte un `id` ET la tournée apparaît dans
#                    GET /commercant/commandes/:id (sinon invisible du suivi) ;
#   • ciblage fleet→ targetUuid = un favori entreprise → adhoc=false,
#                    facilitator_uuid = ce Vendor ;
#   • dépôt réseau → un arrêt `depotUuid` (dépôt d'un favori) → le Place du
#                    dépôt figure dans payload.waypoints ;
#   • encaissement → GET /commercant/commandes/:id → meta.cod_amount = somme ;
#   • forme        → une tournée d'un seul arrêt → 400.
#
# ── Mutation qui DOIT faire échouer ce banc ────────────────────────────────
#
#   Dans `commercant.service.createTournee`, retirer `adhocDistance` de l'appel
#   à `orderHelpers.createTournee` : une tournée sans cible naît alors
#   `adhoc:false` (confiée à personne) → le témoin « diffusion » échoue.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-commercant-tournee.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
FLEET="${FLEET:-app-parcours-entreprise@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; cleanup; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$HERE/lib/fleetbase.sh"

DEPOT=""; ORD1=""; ORD2=""; ORD3=""
cleanup() {
  for o in "$ORD1" "$ORD2" "$ORD3"; do
    [ -n "$o" ] && fb_api PUT "/int/v1/orders/$o" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
  done
  [ -n "$DEPOT" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT" -H "Authorization: Bearer $FLEET_TOKEN" >/dev/null 2>&1 || true
}

login() { curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty'; }
mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $M_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $M_TOKEN"; fi; }
t_code() { curl -sS -o /tmp/ct_resp -w '%{http_code}' -X POST "$BFF_URL/commercant/tournees" -H 'Content-Type: application/json' -H "Authorization: Bearer $M_TOKEN" -d "$1"; }
fb_order() { fb_get "/int/v1/orders/$1?with[]=payload" | jq -c '(.order//.data//.)'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Le commerçant crée une tournée (spec §4)"
echo "════════════════════════════════════════════════════════════════"

step "Décor : commerçant, entreprise favorite, dépôt"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
fb_activate_vendor_by_email "$FLEET" >/dev/null 2>&1 || true
M_TOKEN="$(login "$MERCHANT")"
FLEET_TOKEN="$(login "$FLEET")"
[ -n "$M_TOKEN" ] && [ -n "$FLEET_TOKEN" ] || fail "connexions incomplètes"
M_VENDOR="$(fb_get "/int/v1/vendors?email=$MERCHANT&limit=100" | jq -r --arg e "$MERCHANT" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
FLEET_VENDOR="$(fb_get "/int/v1/vendors?email=$FLEET&limit=100" | jq -r --arg e "$FLEET" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$M_VENDOR" ] && [ -n "$FLEET_VENDOR" ] || fail "Vendors introuvables"
DEPOT="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H 'Content-Type: application/json' -H "Authorization: Bearer $FLEET_TOKEN" -d '{"name":"Dépôt Cmd Tournée","latitude":36.7400,"longitude":3.0800,"phone":"021000040","contactName":"Chef","province":"Alger"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT" ] || fail "création dépôt échouée"
mapi DELETE "/commercant/transporteurs/favoris/$FLEET_VENDOR" >/dev/null 2>&1 || true
mapi POST /commercant/transporteurs/favoris "$(jq -n --arg u "$FLEET_VENDOR" '{fleetbaseDriverUuid:$u, partyType:"fleet"}')" >/dev/null
pass "commerçant (vendor ${M_VENDOR:0:8}…), entreprise favorite (${FLEET_VENDOR:0:8}…), dépôt ${DEPOT:0:8}…"

BASE_STOPS='[
  { "type":"pickup", "latitude":36.7550, "longitude":3.0450, "contactName":"Mon magasin", "contactPhone":"0555000000", "province":"Alger", "items":[{"description":"colis","quantity":1}] },
  { "type":"dropoff", "latitude":36.7300, "longitude":3.0700, "contactName":"Client A", "contactPhone":"0555111222", "province":"Alger", "items":[{"description":"colis A","quantity":1}], "codAmount":1000 }
]'

step "Sans cible : la tournée est DIFFUSÉE au pool"
resp="$(mapi POST /commercant/tournees "$(jq -n --argjson s "$BASE_STOPS" '{price:2500, stops:$s}')")"
ORD1="$(echo "$resp" | jq -r '.fleetbaseOrderId // .id // empty')"
LOCAL1="$(echo "$resp" | jq -r '.id // empty')"
[ -n "$ORD1" ] || fail "création échouée" "$(echo "$resp" | head -c 400)"
[ -n "$LOCAL1" ] || fail "aucune ligne locale (pas d'`id` dans la réponse)" "$(echo "$resp" | jq -c 'keys')"
o="$(fb_order "$ORD1")"
[ "$(echo "$o" | jq -r '.adhoc')" = "true" ] || fail "adhoc ≠ true (tournée non diffusée)" "$(echo "$o" | jq -c '{adhoc, facilitator_uuid, driver_assigned_uuid}')"
[ "$(echo "$o" | jq -r '.facilitator_uuid // "null"')" = "null" ] || fail "un facilitator est posé sur une tournée diffusée" "$o"
[ "$(echo "$o" | jq -r '.customer_uuid')" = "$M_VENDOR" ] || fail "customer_uuid ≠ le Vendor du commerçant" "$o"
[ "$(echo "$o" | jq -r '.payload.waypoints | length')" = "2" ] || fail "payload.waypoints ≠ 2" "$o"
pass "adhoc=true, aucun facilitator, customer = commerçant, 2 arrêts"

step "Ligne locale : la tournée apparaît dans le suivi du commerçant"
proj="$(mapi GET "/commercant/commandes/$LOCAL1")"
[ "$(echo "$proj" | jq -r '.payload.waypoints | length')" = "2" ] || fail "GET /commercant/commandes/:id ne sert pas les arrêts" "$(echo "$proj" | jq -c 'keys')"
[ "$(echo "$proj" | jq -r '.meta.cod_amount // empty')" = "1000" ] || fail "meta.cod_amount ≠ 1000" "$(echo "$proj" | jq -c '.meta')"
pass "suivie par le commerçant, meta.cod_amount = 1000"

step "Avec cible entreprise : confiée (facilitator), pas diffusée"
resp2="$(mapi POST /commercant/tournees "$(jq -n --argjson s "$BASE_STOPS" --arg t "$FLEET_VENDOR" '{price:2500, stops:$s, targetUuid:$t}')")"
ORD2="$(echo "$resp2" | jq -r '.fleetbaseOrderId // .id // empty')"
[ -n "$ORD2" ] || fail "création (ciblée) échouée" "$(echo "$resp2" | head -c 300)"
o2="$(fb_order "$ORD2")"
[ "$(echo "$o2" | jq -r '.adhoc')" = "false" ] || fail "tournée confiée mais adhoc=true" "$o2"
[ "$(echo "$o2" | jq -r '.facilitator_uuid')" = "$FLEET_VENDOR" ] || fail "facilitator_uuid ≠ l'entreprise ciblée" "$o2"
pass "adhoc=false, facilitator = l'entreprise favorite"

step "Un arrêt = un dépôt du réseau"
DSTOPS="$(jq -n --arg d "$DEPOT" '[
  { type:"pickup", latitude:36.7550, longitude:3.0450, contactName:"Magasin", contactPhone:"0555000000", province:"Alger" },
  { type:"dropoff", depotUuid:$d, items:[{description:"vers le dépôt",quantity:1}] }
]')"
resp3="$(mapi POST /commercant/tournees "$(jq -n --argjson s "$DSTOPS" '{price:1800, stops:$s}')")"
ORD3="$(echo "$resp3" | jq -r '.fleetbaseOrderId // .id // empty')"
[ -n "$ORD3" ] || fail "création (dépôt) échouée" "$(echo "$resp3" | head -c 400)"
o3="$(fb_order "$ORD3")"
echo "$o3" | jq -e --arg d "$DEPOT" '[.payload.waypoints[]?.uuid] | index($d)' >/dev/null \
  || fail "le Place du dépôt ne figure pas dans payload.waypoints" "$(echo "$o3" | jq -c '[.payload.waypoints[]?.uuid]')"
pass "le dépôt du réseau est un arrêt de la tournée"

step "Forme refusée : une tournée d'un seul arrêt"
code="$(t_code "$(jq -n '{price:500, stops:[{type:"pickup", latitude:36.75, longitude:3.04, contactName:"X", contactPhone:"0555000000"}]}')")"
[ "$code" = "400" ] || fail "tournée à 1 arrêt : HTTP $code (attendu 400)" "$(cat /tmp/ct_resp)"
pass "tournée d'un seul arrêt → 400"

cleanup
echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le commerçant crée une tournée : diffusée au pool par défaut (avec"
echo "   sa ligne locale de suivi), confiée à un favori entreprise sur"
echo "   ciblage, un dépôt du réseau peut être un arrêt ; la tournée à un"
echo "   arrêt est refusée."
echo "════════════════════════════════════════════════════════════════"
