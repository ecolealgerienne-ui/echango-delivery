#!/usr/bin/env bash
#
# Un favori sollicité REFUSE : la course repart au pool, et le commerçant est prévenu.
#
# ── Ce que ce banc éprouve ────────────────────────────────────────────────────
#
# Cibler un favori sort la course du pool (`driver_assigned_uuid` posé). Mais un
# favori indisponible qui **refuse** ne doit pas la bloquer : `declineOrder`
# détache la course, la **rediffuse** au réseau (`adhoc` redevient vrai) et
# **prévient le commerçant** (`order.released`). C'est la vraie remplaçante de
# l'ancien repli `pickAvailableFavourite`, et elle n'était éprouvée par aucun
# scénario — `test-sorties-de-course` n'atteint que la branche « déjà démarrée »
# d'une course du pool, jamais le détache-et-rediffuse d'une course confiée.
#
# ── Les trois témoins ─────────────────────────────────────────────────────────
#
#   1. la réponse dit `releasedToPool: true` ;
#   2. la course, chez Fleetbase, n'a plus de conducteur et `adhoc` est redevenu
#      vrai — elle est de nouveau réclamable par le réseau ;
#   3. le commerçant reçoit `order.released` dans son feed (immédiat, pas via le
#      réconciliateur).
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-refus-favori-pool.sh

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
xapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $X_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $X_TOKEN"; fi; }

order_state() { fb_get "/int/v1/orders/$1" | jq -c '(.order//.data//.) | {status, adhoc, driver_assigned_uuid}'; }
free_x() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }
has_released_notif() { # cacheOrderId
  mapi GET /commercant/notifications \
    | jq -e --arg o "$1" '[.data[]? | select(.type=="order.released" and (.order_id|tostring)==$o)] | length >= 1' \
      >/dev/null 2>&1 && echo yes || echo no; }

echo "════════════════════════════════════════════════════════════════"
echo "  Refus d'un favori sollicité → retour au pool + notification"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
# Un conducteur connectable (on sonde le jeton — comptes de test hétérogènes).
mapfile -t DRV < <(_accounted_driver_uuids)
X_UUID=""; X_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || true
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")"
  if [ "$code" = "200" ]; then X_UUID="$d"; X_TOKEN="$DRIVER_TOKEN"; break; fi
done
[ -n "$X_TOKEN" ] || fail "Aucun conducteur connectable"
free_x "$X_UUID"
# X favori du commerçant, pour pouvoir lui CIBLER la course.
mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$X_UUID" '{fleetbaseDriverUuid:$u, partyType:"driver"}')" >/dev/null 2>&1 || true
pass "Commerçant + favori X (${X_UUID:0:8}…)"

step "Course CONFIÉE à X (hors pool)"
resp="$(mapi POST /commercant/commandes "$(jq -n --arg t "$X_UUID" '{
  pickupLocationName:"Dépôt Refus", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Refus", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:650, podMethod:"aucune",
  targetFavouriteUuid:$t }')")"
C="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
CID="$(echo "$resp" | jq -r '.id // empty')"
[ -n "$C" ] && [ -n "$CID" ] || fail "Création ciblée échouée" "$(echo "$resp" | head -c 300)"
as="$(order_state "$C")"
[ "$(echo "$as" | jq -r '.driver_assigned_uuid')" = "$X_UUID" ] || fail "La course n'est pas confiée à X" "$as"
[ "$(echo "$as" | jq -r '.adhoc')" = "false" ] || fail "adhoc devrait être false (confiée)" "$as"
[ "$(has_released_notif "$CID")" = "no" ] || fail "Une notif order.released existe déjà pour $CID — décor sale"
pass "Course $C confiée à X (adhoc=false), feed propre"

step "X REFUSE la course"
r="$(xapi POST "/transporteur/commandes/$C/refuser" '{"reason":"indisponible"}')"
[ "$(echo "$r" | jq -r '.releasedToPool // empty')" = "true" ] \
  || fail "La réponse ne dit pas releasedToPool:true" "$(echo "$r" | jq -c '{code,message,releasedToPool}')"
pass "TÉMOIN 1 : releasedToPool = true"

step "TÉMOIN 2 : la course est repartie au pool (Fleetbase)"
af="$(order_state "$C")"
echo "   état : $af"
[ "$(echo "$af" | jq -r '.driver_assigned_uuid')" = "null" ] || fail "X est encore assigné après le refus" "$af"
[ "$(echo "$af" | jq -r '.adhoc')" = "true" ] || fail "adhoc devrait être redevenu true (rediffusée)" "$af"
pass "Plus de conducteur, adhoc=true — réclamable de nouveau"

step "TÉMOIN 3 : le commerçant est prévenu (order.released)"
# Immédiat (notifyOrderOwner dans declineOrder), mais on laisse une petite marge.
seen="no"; for _ in 1 2 3 4 5; do [ "$(has_released_notif "$CID")" = "yes" ] && { seen="yes"; break; }; sleep 2; done
[ "$seen" = "yes" ] || fail "Le commerçant n'a PAS reçu order.released — le désistement est muet pour lui" \
  "$(mapi GET /commercant/notifications | jq -c '[.data[]?|{type, order_id}][:5]')"
pass "TÉMOIN 3 : order.released dans le feed du commerçant"

# ── Ménage ──────────────────────────────────────────────────────────────────
mapi POST "/commercant/commandes/$C/annuler" '{}' >/dev/null 2>&1 || true
mapi DELETE "/commercant/transporteurs/favoris/$X_UUID" >/dev/null 2>&1 || true
free_x "$X_UUID"

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Un favori qui se désiste ne bloque pas la course : elle repart"
echo "   au réseau, et le commerçant l'apprend aussitôt."
echo "════════════════════════════════════════════════════════════════"
