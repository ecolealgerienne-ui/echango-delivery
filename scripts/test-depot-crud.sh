#!/usr/bin/env bash
#
# Dépôts de transporteur national — CRUD depuis l'espace flotte (spec §3.1).
#
# ── Ce que ce banc éprouve, et pourquoi il faut la stack réelle ─────────────
#
# Un dépôt est un `Place` Fleetbase possédé par le `Vendor` du transporteur,
# marqué `meta.is_depot = true`. Rien de tout ça — le marqueur, l'`owner_uuid`
# qui survit à un PUT, le refus de la ressource d'autrui — n'est vérifiable hors
# Fleetbase.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • création      → le dépôt apparaît dans GET /flotte/depots, et chez
#                      Fleetbase il porte meta.is_depot=true et owner_uuid = le
#                      Vendor du transporteur ;
#   • modification   → le nom change, ET l'owner_uuid SURVIT (piège
#                      updateOwnedPlace : PUT /places remplace l'objet entier) ;
#   • appartenance   → un transporteur B ne voit pas le dépôt de A, et son
#                      PUT/DELETE dessus rend depot.not_found (404), jamais la
#                      ressource (règle 12) ;
#   • suppression    → le dépôt disparaît de GET /flotte/depots.
#
# Mutation : neutraliser le filtre `meta.is_depot` de `assertOwnsDepot`, ou le
# refus, fait échouer l'étape « appartenance ».
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-depot-crud.sh

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

DEPOT=""
cleanup() {
  [ -n "$DEPOT" ] && [ -n "${TOKEN_A:-}" ] \
    && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT" -H "Authorization: Bearer $TOKEN_A" >/dev/null 2>&1 || true
}

fa() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN_A" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $TOKEN_A"; fi; }
fb_code() { curl -sS -o /dev/null -w '%{http_code}' -X "$1" "$BFF_URL$2" -H "Authorization: Bearer $TOKEN_B" ${3:+-H 'Content-Type: application/json' -d "$3"}; }

echo "================================================================"
echo "  Dépôts — CRUD, appartenance, marqueur is_depot"
echo "================================================================"

step "Décor : connexions A et B"
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
TOKEN_A="$(curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$FLEET_A" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty')"
[ -n "$TOKEN_A" ] || fail "Connexion transporteur A impossible"

# B : connexion, sinon inscription + activation (patron de test-appartenance).
TOKEN_B="$(curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" \
  -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty')"
if [ -z "$TOKEN_B" ]; then
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/flotte/register" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p,businessName:"Flotte témoin dépôts"}')"
  fb_activate_vendor_by_email "$FLEET_B" >/dev/null 2>&1 || true
  TOKEN_B="$(curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" \
    -d "$(jq -n --arg e "$FLEET_B" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty')"
fi
[ -n "$TOKEN_B" ] || fail "Connexion transporteur B impossible"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor de A introuvable"
pass "A et B connectés — Vendor A ${VENDOR_A:0:8}…"

step "Création d'un dépôt (A)"
resp="$(fa POST /flotte/depots "$(jq -n '{
  name:"Entrepôt Test Alger-Centre", latitude:36.7538, longitude:3.0588,
  phone:"021555000", contactName:"Chef Dépôt", city:"Alger", province:"Alger"
}')")"
DEPOT="$(echo "$resp" | jq -r '.uuid // empty')"
[ -n "$DEPOT" ] || fail "Création dépôt échouée" "$(echo "$resp" | head -c 200)"
[ "$(echo "$resp" | jq -r '.name')" = "Entrepôt Test Alger-Centre" ] || fail "nom non relu"
[ "$(echo "$resp" | jq -r '.contact_name')" = "Chef Dépôt" ] || fail "contact non relu"
pass "dépôt créé : ${DEPOT:0:12}…"

step "Témoin Fleetbase : is_depot posé, owner = Vendor A"
PLACE="$(fb_get "/int/v1/places?owner_uuid=$VENDOR_A&limit=100" | jq -c --arg u "$DEPOT" '(.places // .data // []) | map(select(.uuid==$u)) | .[0] // {}')"
[ "$(echo "$PLACE" | jq -r '.meta.is_depot')" = "true" ] || fail "meta.is_depot ≠ true chez Fleetbase" "$PLACE"
[ "$(echo "$PLACE" | jq -r '.owner_uuid')" = "$VENDOR_A" ] || fail "owner_uuid ≠ Vendor A" "$PLACE"
pass "meta.is_depot=true, owner_uuid = Vendor A"

step "GET /flotte/depots (A) contient le dépôt"
fa GET /flotte/depots | jq -e --arg u "$DEPOT" '[.data[]?.uuid] | index($u)' >/dev/null \
  || fail "le dépôt n'est pas dans la liste de A"
pass "listé chez A"

step "Modification (A) : le nom change, l'owner_uuid SURVIT"
fa PUT "/flotte/depots/$DEPOT" "$(jq -n '{
  name:"Entrepôt Alger-Centre (rénové)", latitude:36.7538, longitude:3.0588,
  phone:"021555111", contactName:"Nouveau Chef", province:"Alger"
}')" >/dev/null
got="$(fa GET /flotte/depots | jq -c --arg u "$DEPOT" '.data[] | select(.uuid==$u)')"
[ "$(echo "$got" | jq -r '.name')" = "Entrepôt Alger-Centre (rénové)" ] || fail "nom non modifié" "$got"
[ "$(echo "$got" | jq -r '.phone')" = "021555111" ] || fail "téléphone non modifié"
owner_now="$(fb_get "/int/v1/places?owner_uuid=$VENDOR_A&limit=100" | jq -r --arg u "$DEPOT" '(.places // .data // []) | map(select(.uuid==$u)) | .[0].owner_uuid // "GONE"')"
[ "$owner_now" = "$VENDOR_A" ] || fail "owner_uuid perdu après PUT (piège updateOwnedPlace)" "owner_uuid = $owner_now"
pass "nom + téléphone modifiés, owner_uuid intact"

step "Appartenance : B ne voit pas le dépôt de A, et ne peut pas y toucher"
fa_b_list="$(curl -sS "$BFF_URL/flotte/depots" -H "Authorization: Bearer $TOKEN_B")"
echo "$fa_b_list" | jq -e --arg u "$DEPOT" '[.data[]?.uuid] | index($u)' >/dev/null 2>&1 \
  && fail "B voit le dépôt de A dans sa liste"
c_put="$(fb_code PUT "/flotte/depots/$DEPOT" '{"name":"pirate","latitude":0,"longitude":0,"phone":"0","contactName":"x"}')"
c_del="$(fb_code DELETE "/flotte/depots/$DEPOT")"
[ "$c_put" = "404" ] || fail "PUT de B sur le dépôt de A : $c_put (attendu 404 depot.not_found, pas 403 ni 200)"
[ "$c_del" = "404" ] || fail "DELETE de B sur le dépôt de A : $c_del (attendu 404)"
# le dépôt de A est toujours là, intact
[ "$(fa GET /flotte/depots | jq -r --arg u "$DEPOT" '.data[] | select(.uuid==$u) | .name')" = "Entrepôt Alger-Centre (rénové)" ] \
  || fail "le dépôt de A a été altéré par B"
pass "B ne voit rien, ses PUT/DELETE rendent 404, le dépôt de A est intact"

step "Suppression (A)"
fa DELETE "/flotte/depots/$DEPOT" | jq -e '.deleted == true' >/dev/null || fail "suppression non confirmée"
fa GET /flotte/depots | jq -e --arg u "$DEPOT" '[.data[]?.uuid] | index($u) | not' >/dev/null \
  || fail "le dépôt est encore listé après suppression"
DEPOT=""
pass "dépôt supprimé, absent de la liste"

echo
echo "================================================================"
echo "OK  un dépôt se crée/modifie/supprime, porte meta.is_depot,"
echo "    garde son owner_uuid après un PUT, et reste privé à son"
echo "    transporteur (PUT/DELETE d'autrui → 404)."
echo "================================================================"
