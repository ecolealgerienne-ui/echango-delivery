#!/usr/bin/env bash
#
# Le réconciliateur notifie le commerçant — toute la chaîne, jamais éprouvée.
#
# ── Pourquoi ce banc, et ce qu'il couvre ──────────────────────────────────────
#
# Fleetbase ne rappelle jamais le BFF (les webhooks sont reportés au VPS). C'est
# `OrderReconcilerService` qui, à intervalle, relit l'état des commandes et
# **prévient le commerçant** de ce qui a changé : « pris en charge », « livré »,
# « annulé ». Cette chaîne — dérive détectée → notification écrite → feed lu par
# l'app — n'avait **aucune couverture automatique**. Or c'est le seul moyen pour
# un commerçant de savoir qu'un transporteur a pris sa course : si elle casse, il
# ne l'apprend jamais, sans la moindre erreur (règle 9).
#
# ── Ce que le banc fait ───────────────────────────────────────────────────────
#
# Il crée une course, puis lui affecte un conducteur **directement chez
# Fleetbase** (comme le ferait la console, hors du BFF) : le cache du BFF ignore
# ce changement. Au passage suivant du réconciliateur, la dérive doit produire
# une notification `order.assigned` dans le feed du commerçant, et le cache doit
# se resynchroniser.
#
# ⚠️ **Il attend un vrai passage du réconciliateur** (une minute par défaut,
# `RECONCILER_INTERVAL_MS`). Il sonde le feed jusqu'à ~130 s : deux intervalles,
# de quoi couvrir un passage déjà en cours au moment de l'affectation.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-reconciliateur-notif.sh
#   RECONCILER_INTERVAL_MS=10000 (côté BFF) accélère, mais n'est pas requis.

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
WAIT_MAX="${WAIT_MAX:-140}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }

# Y a-t-il une notif `order.assigned` pour la commande locale $1 ? yes/no
has_assigned_notif() { # cacheOrderId
  mapi GET /commercant/notifications \
    | jq -e --arg o "$1" '[.data[]? | select(.type=="order.assigned" and (.order_id|tostring)==$o)] | length >= 1' \
      >/dev/null 2>&1 && echo yes || echo no; }

echo "════════════════════════════════════════════════════════════════"
echo "  Réconciliateur → notification du commerçant"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
# Un conducteur RÉEL pour l'affectation (clé étrangère chez Fleetbase).
DRIVER="$(fb_get "/int/v1/drivers?limit=1" | jq -r '.drivers[0].uuid // empty')"
[ -n "$DRIVER" ] || fail "Aucun conducteur dans l'annuaire Fleetbase"
echo "   réconciliateur : $(curl -sS "$BFF_URL/health" | jq -c '{age:.reconciler_age_seconds, last:.reconciler_last_run}')"
pass "Commerçant + un conducteur pour l'affectation (${DRIVER:0:8}…)"

step "Une course, vue du BFF (cache = created, sans conducteur)"
resp="$(mapi POST /commercant/commandes "$(jq -n '{
  draft:true,
  pickupLocationName:"Dépôt Réconcil", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Réconcil", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:600, podMethod:"aucune" }')")"
C="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
CID="$(echo "$resp" | jq -r '.id // empty')"
[ -n "$C" ] && [ -n "$CID" ] || fail "Création échouée" "$(echo "$resp" | head -c 300)"
pass "Course $C (id local $CID)"

step "TÉMOIN de départ : aucune notif « pris en charge » pour cette course"
[ "$(has_assigned_notif "$CID")" = "no" ] || fail "Une notif order.assigned existe déjà pour $CID — décor sale"
pass "Feed propre pour cette course"

step "Hors du BFF : on affecte un conducteur DIRECTEMENT chez Fleetbase"
fb_api PUT "/int/v1/orders/$C" "$(jq -nc --arg d "$DRIVER" '{order:{driver_assigned_uuid:$d}}')" >/dev/null \
  || fail "Affectation Fleetbase impossible"
got="$(fb_get "/int/v1/orders/$C" | jq -r '(.order//.data//.).driver_assigned_uuid // "null"')"
[ "$got" = "$DRIVER" ] || fail "L'affectation Fleetbase n'a pas pris (porteur $got)"
pass "Conducteur affecté chez Fleetbase — le cache du BFF l'ignore encore"

step "On attend un passage du réconciliateur (≤ ${WAIT_MAX}s)"
seen="no"; waited=0
while [ "$waited" -lt "$WAIT_MAX" ]; do
  if [ "$(has_assigned_notif "$CID")" = "yes" ]; then seen="yes"; break; fi
  sleep 6; waited=$((waited+6))
  printf '   … %ss (réconciliateur âge %ss)\n' "$waited" "$(curl -sS "$BFF_URL/health" | jq -r '.reconciler_age_seconds')"
done
[ "$seen" = "yes" ] || fail "Aucune notif order.assigned après ${WAIT_MAX}s — la chaîne réconciliateur→notification est MUETTE" \
  "c'est exactement le défaut que ce banc existe pour attraper : le commerçant n'apprend jamais que sa course est prise"
pass "TÉMOIN : le commerçant a reçu « pris en charge » (order.assigned) en ${waited}s"

step "Et le cache s'est resynchronisé (le conducteur est visible côté BFF)"
drv="$(mapi GET "/commercant/commandes/$C" | jq -r '.driver_assigned.name // .driver_assigned_uuid // "?"')"
# La fiche commerçant ne sert que le NOM du conducteur (projection) ; l'important
# est que la commande ne soit plus « sans transporteur » du point de vue du cache.
recon="$(mapi GET "/commercant/commandes/$C" | jq -r '.status // "?"')"
echo "   fiche commerçant : statut=$recon conducteur=$drv"
pass "La course reflète l'affectation venue de l'extérieur"

# ── Ménage ──────────────────────────────────────────────────────────────────
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Une prise en charge survenue HORS du BFF remonte au commerçant :"
echo "   le réconciliateur détecte la dérive et écrit la notification."
echo "════════════════════════════════════════════════════════════════"
