#!/usr/bin/env bash
#
# Une course « utilitaire » n'apparaît pas au conducteur « moto ».
#
# ── Ce que ce banc éprouve, et comment il isole le véhicule ───────────────
#
# La visibilité d'une opportunité dépend de trois choses : le véhicule exigé, la
# wilaya, et l'état de la course. Pour ne mesurer QUE le véhicule, on garde tout
# le reste fixe — même conducteur, même course sans wilaya — et on **bascule le
# véhicule déclaré du conducteur**. La course apparaît ou disparaît ; le seul
# variant est le véhicule.
#
# ⚠️ **La liste adhoc n'est PAS filtrée par la position** (le BFF prend toutes
# les courses sans conducteur, puis filtre véhicule + wilaya) — c'est ce qui
# rend ce test propre, sans confond géospatial.
#
# ⚠️ L'exigence est un MINIMUM, pas une égalité : « utilitaire » exige un
# utilitaire ; « voiture » l'accepte aussi (voiture < utilitaire dans l'échelle
# moto < voiture < utilitaire). Le témoin négatif porte donc sur moto ET voiture.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-filtre-vehicule.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"

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
dapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $Z_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $Z_TOKEN"; fi; }

# La course C est-elle dans la liste adhoc de Z ?
sees_it() { dapi GET "/transporteur/commandes?type=adhoc" | jq -e '[.orders[]?.uuid] | index("'"$1"'")' >/dev/null; }

echo "════════════════════════════════════════════════════════════════"
echo "  Filtre véhicule : une course « utilitaire » et un conducteur"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"

mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID="${DRV[0]:-}"; [ -n "$Z_UUID" ] || fail "Aucun conducteur avec un compte"
# Libérer Z (une course en cours le retirerait du calcul), puis jeton.
for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
done
obtain_driver_token "$Z_UUID" >/dev/null 2>&1 || fail "Jeton Z impossible" "${DRIVER_SESSION_ERROR:-}"
Z_TOKEN="$DRIVER_TOKEN"
# Zone effacée : sans wilaya, `zoneAllows` laisse tout passer, et seul le
# véhicule filtre.
dapi PUT /transporteur/zone '{"wilaya":null,"radiusKm":null}' >/dev/null
pass "Commerçant + conducteur Z (${Z_UUID:0:8}…), zone effacée"

step "Une course qui exige un UTILITAIRE (diffusée, sans wilaya)"
o="$(mapi POST /commercant/commandes "$(jq -n '{
  pickupLocationName:"Dépôt Véhicule", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Véhicule", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"gros colis", quantity:1}], price:650, podMethod:"aucune",
  vehicleType:"utilitaire", draft:true }')")"
C="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$C" ] || fail "Création échouée" "$(echo "$o" | head -c 200)"
mapi POST "/commercant/commandes/$C/publier" >/dev/null
pass "Course « utilitaire » publiée : ${C:0:8}…"

# ── Le cœur : on bascule le véhicule de Z, la course suit ──────────────────
step "moto → ne voit pas ; utilitaire → voit ; voiture → ne voit pas"

dapi POST /transporteur/vehicule '{"vehicleType":"moto"}' >/dev/null
sees_it "$C" && fail "Un « moto » NE devrait PAS voir une course « utilitaire »"
pass "moto : ne voit pas la course (correct)"

dapi POST /transporteur/vehicule '{"vehicleType":"utilitaire"}' >/dev/null
sees_it "$C" || fail "Un « utilitaire » DEVRAIT voir la course — témoin positif manquant"
pass "TÉMOIN : utilitaire voit la course"

dapi POST /transporteur/vehicule '{"vehicleType":"voiture"}' >/dev/null
sees_it "$C" && fail "Une « voiture » ne suffit pas pour une exigence « utilitaire »"
pass "voiture : ne voit pas (une voiture ne fait pas un utilitaire)"

# ── Ménage : annuler la course, remettre Z sans exigence ───────────────────
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le filtre véhicule décide de ce qu'un conducteur voit — et il tient"
echo "   dans les deux sens, témoin positif à l'appui."
echo "════════════════════════════════════════════════════════════════"
