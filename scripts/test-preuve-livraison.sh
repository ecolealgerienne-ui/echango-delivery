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
# Lit une preuve et rend « HTTP CODE ». ⚠️ On distingue DEUX 404 :
#   order.proof_not_found → l'accès a été ACCORDÉ, seul le stockage a échoué ;
#   order.not_found       → l'accès a été REFUSÉ, avant même de voir la preuve.
# C'est cette distinction qui prouve l'appartenance, indépendamment du stockage.
read_proof() { # path token
  local http; http="$(curl -sS -o /tmp/pbody -w '%{http_code}' "$BFF_URL$1" -H "Authorization: Bearer $2")"
  if [ "$http" = "200" ]; then echo "200 OK"; else echo "$http $(jq -r '.code // "?"' </tmp/pbody 2>/dev/null)"; fi
}

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

step "Le PROPRIÉTAIRE atteint la preuve (l'accès est accordé)"
# ⚠️ Sur cette instance, le stockage local des preuves n'est pas servable (URL
# `localhost:8000/storage/...` → 400) : le propriétaire obtient donc soit 200,
# soit `order.proof_not_found` — dans les DEUX cas, l'accès a été accordé et
# c'est l'étape stockage qui échoue. Ce qui compte pour l'appartenance, c'est
# que l'intrus, lui, n'atteigne JAMAIS cette étape.
zr="$(read_proof "$PROOF" "$Z_TOKEN")"
case "$zr" in "200 OK"|*"order.proof_not_found") pass "Z (déposant) atteint sa preuve — $zr" ;;
  *) fail "Z devrait atteindre sa preuve (accès accordé), a eu : $zr" ;; esac
ar="$(read_proof "/commercant/commandes/$C/preuves/$FID" "$TA")"
case "$ar" in "200 OK"|*"order.proof_not_found") pass "Commerçant A (propriétaire) atteint la preuve — $ar" ;;
  *) fail "A devrait atteindre la preuve (accès accordé), a eu : $ar" ;; esac

step "L'INTRUS est bloqué AVANT la preuve (accès refusé)"
# ⚠️ Le code doit être order.not_found (bloqué à l'accès), JAMAIS
# order.proof_not_found (qui prouverait qu'il a vu la course d'autrui).
wr="$(read_proof "$PROOF" "$W_TOKEN")"
[[ "$wr" == *"order.not_found" ]] || fail "W (autre conducteur) doit être bloqué à l'ACCÈS (order.not_found), a eu : $wr"
pass "W (autre conducteur) : bloqué à l'accès — $wr"
br="$(read_proof "/commercant/commandes/$C/preuves/$FID" "$TB")"
case "$br" in *"order.not_found"|*"order.forbidden") pass "Commerçant B (non propriétaire) : bloqué à l'accès — $br" ;;
  *) fail "B doit être bloqué à l'accès, a eu : $br" ;; esac

# Ménage
free_d "$Z_UUID"
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le propriétaire ATTEINT sa preuve (accès accordé) ; l'intrus est"
echo "   bloqué AVANT (order.not_found), jamais à l'étape stockage. L'appartenance"
echo "   tient — indépendamment de la limitation de stockage local (voir en-tête)."
echo "════════════════════════════════════════════════════════════════"
