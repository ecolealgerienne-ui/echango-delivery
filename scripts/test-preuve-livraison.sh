#!/usr/bin/env bash
#
# La preuve de livraison : uploadée, relue par le RELAIS authentifié, et
# invisible à qui n'y a pas droit.
#
# ── Ce que ce banc éprouve ────────────────────────────────────────────────
#
# `CLAUDE.md` règle 12 laissait DEUX des 32 routes à identifiant non couvertes :
# les lectures de preuve, faute de décor photographique. Les voici. Une URL de
# preuve fuitée est non authentifiée — la seule bonne réponse à « la preuve de
# quelqu'un d'autre » est **introuvable**.
#
# On dépose une preuve (échec de livraison avec photo), on la relit par le relais
# du BFF (jamais l'URL Fleetbase), et on vérifie qu'un AUTRE conducteur et un
# AUTRE commerçant ne peuvent pas la lire.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-preuve-livraison.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT_A="${MERCHANT_A:-app-parcours-commercant@echango.local}"
MERCHANT_B="${MERCHANT_B:-appartenance-commercant-b@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

# Un PNG 1×1 valide, encodé base64.
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='

login_merchant() { fb_activate_vendor_by_email "$1" >/dev/null 2>&1 || true
  curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty'; }
mapiA() { curl -sS -X "$1" "$BFF_URL$2" ${3:+-H 'Content-Type: application/json' -d "$3"} -H "Authorization: Bearer $TA"; }
free_d() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }
code() { curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL$1" -H "Authorization: Bearer $2"; }

echo "════════════════════════════════════════════════════════════════"
echo "  La preuve de livraison — relais authentifié + appartenance"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
TA="$(login_merchant "$MERCHANT_A")"; [ -n "$TA" ] || fail "Commerçant A"
TB="$(login_merchant "$MERCHANT_B")"; [ -n "$TB" ] || fail "Commerçant B"
mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID="${DRV[0]:-}"; W_UUID="${DRV[1]:-}"
[ -n "$Z_UUID" ] && [ -n "$W_UUID" ] && [ "$Z_UUID" != "$W_UUID" ] || fail "Deux conducteurs distincts requis"
free_d "$Z_UUID"; free_d "$W_UUID"
obtain_driver_token "$Z_UUID" >/dev/null 2>&1 || fail "Jeton Z impossible" "${DRIVER_SESSION_ERROR:-}"; Z_TOKEN="$DRIVER_TOKEN"
obtain_driver_token "$W_UUID" >/dev/null 2>&1 || fail "Jeton W impossible" "${DRIVER_SESSION_ERROR:-}"; W_TOKEN="$DRIVER_TOKEN"
pass "Commerçants A & B, conducteurs Z (dépose) et W (intrus)"

step "Z prend une course de A et signale un échec AVEC photo"
o="$(mapiA POST /commercant/commandes "$(jq -n '{
  pickupLocationName:"Dépôt Preuve", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Preuve", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:500, podMethod:"aucune", draft:true }')")"
C="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"; [ -n "$C" ] || fail "Création" "$(echo "$o" | head -c 200)"
mapiA POST "/commercant/commandes/$C/publier" >/dev/null
curl -sS -X POST "$BFF_URL/transporteur/commandes/$C/accepter" -H 'Content-Type: application/json' -H "Authorization: Bearer $Z_TOKEN" -d '{}' >/dev/null
ech="$(curl -sS -X POST "$BFF_URL/transporteur/commandes/$C/echec" -H 'Content-Type: application/json' -H "Authorization: Bearer $Z_TOKEN" \
  -d "$(jq -n --arg p "$PNG" '{reason:"client_absent", photo:$p}')")"
echo "$ech" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 || fail "Signalement d'échec refusé" "$(echo "$ech" | jq -c '{code,message}')"

# Le chemin du relais de preuve, tel que le BFF le sert (jamais l'URL Fleetbase).
fiche="$(curl -sS "$BFF_URL/transporteur/commandes/$C" -H "Authorization: Bearer $Z_TOKEN")"
PROOF="$(echo "$fiche" | jq -r '.delivery_failure.photo_url // (.delivery_failures[0].photo_url) // empty')"
FID="$(echo "$fiche" | jq -r '.delivery_failure.id // (.delivery_failures[0].id) // empty')"
[ -n "$PROOF" ] && [ -n "$FID" ] || fail "Pas de relais de preuve sur la fiche" "$(echo "$fiche" | jq -c '{delivery_failure}' 2>/dev/null)"
[[ "$PROOF" != http* ]] || fail "Le relais expose une URL absolue (Fleetbase ?) : $PROOF"
pass "Échec signalé, preuve déposée — relais $PROOF"

step "La preuve se lit par le relais, pour qui y a droit"
zc="$(code "$PROOF" "$Z_TOKEN")"
[ "$zc" = "200" ] || fail "Le conducteur qui a déposé la preuve ne peut pas la lire ($zc)"
pass "TÉMOIN : Z (déposant) lit sa preuve (200)"

ac="$(code "/commercant/commandes/$C/preuves/$FID" "$TA")"
[ "$ac" = "200" ] || fail "Le commerçant propriétaire ne peut pas lire la preuve ($ac)"
pass "TÉMOIN : le commerçant A (propriétaire) lit la preuve (200)"

step "Elle est INVISIBLE à qui n'y a pas droit"
wc="$(code "$PROOF" "$W_TOKEN")"
[ "$wc" = "404" ] || fail "Un autre conducteur (W) devrait avoir 404, a eu $wc"
pass "W (autre conducteur) : 404 introuvable"

bc="$(code "/commercant/commandes/$C/preuves/$FID" "$TB")"
{ [ "$bc" = "404" ] || [ "$bc" = "403" ]; } || fail "Un autre commerçant (B) devrait être refusé, a eu $bc"
pass "Commerçant B (non propriétaire) : refusé ($bc)"

# Ménage
free_d "$Z_UUID"
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ La preuve se lit par le relais authentifié, et reste introuvable"
echo "   à un autre conducteur comme à un autre commerçant."
echo "════════════════════════════════════════════════════════════════"
