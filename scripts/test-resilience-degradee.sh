#!/usr/bin/env bash
#
# Fleetbase dégradé : le BFF sert un état, il ne plante pas.
#
# ── Ce que ce banc éprouve ────────────────────────────────────────────────
#
# « La disponibilité de Fleetbase est un prérequis » ne dispense pas de vérifier
# que son indisponibilité **dégrade** l'affichage au lieu de le casser. Deux
# chemins, plus la santé :
#
#   missing → une course DISPARUE de Fleetbase remonte « missing », pas un 500 ;
#   stale   → Fleetbase INJOIGNABLE rend les courses « stale » (cache), pas un 500 ;
#   health  → `/health` reste `ok` même Fleetbase à terre (il lit le local), ET
#             RAPPORTE la joignabilité de Fleetbase (`dependencies.fleetbase`) ;
#   503     → un refus dû à l'amont sort en 503 (« réessaie »), pas en 400.
#
# ⚠️ **Ce banc ARRÊTE puis RALLUME un conteneur Fleetbase.** Un `trap` garantit
# le redémarrage même en cas d'échec. À ne lancer que sur l'instance locale.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-resilience-degradee.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
FB_HTTPD="${FB_HTTPD:-fleetbase-src-httpd-1}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

# ⚠️ Rallumer Fleetbase QUOI QU'IL ARRIVE.
restore_fb() { docker start "$FB_HTTPD" >/dev/null 2>&1 || true; }
trap restore_fb EXIT

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -m 40 -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -m 40 -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }
fb_reachable() { curl -sS -m 10 "$BFF_URL/health" | jq -r '.dependencies.fleetbase.reachable // "absent"'; }

create_draft() { # label -> fleetbaseOrderId
  local o; o="$(mapi POST /commercant/commandes "$(jq -n --arg n "$1" '{
    pickupLocationName:("Dépôt "+$n), pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:("Client "+$n), dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis", quantity:1}], price:500, podMethod:"aucune", draft:true }')")"
  echo "$o" | jq -r '.fleetbaseOrderId // empty'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Résilience : Fleetbase dégradé, le BFF sert un état"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
O="$(create_draft Missing)"; [ -n "$O" ] || fail "Création O"
P="$(create_draft Stale)";   [ -n "$P" ] || fail "Création P"
# Un conducteur connectable, pour éprouver le 503 d'une liste qui interroge
# vraiment Fleetbase (la liste commerçant, elle, dégrade en « stale »).
mapfile -t DRV < <(_accounted_driver_uuids)
Z_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || true
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  [ "$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")" = "200" ] \
    && { Z_TOKEN="$DRIVER_TOKEN"; break; }
done
[ -n "$Z_TOKEN" ] || fail "Aucun conducteur connectable pour le témoin 503"
pass "Commerçant + deux courses (O=${O:0:8}…, P=${P:0:8}…) + un conducteur"

# ── health rapporte la joignabilité de Fleetbase (Fleetbase EN LIGNE) ───────
step "/health RAPPORTE la dépendance (Fleetbase en ligne → reachable=true)"
[ "$(fb_reachable)" = "true" ] || fail "/health devrait rapporter fleetbase.reachable=true" "$(curl -sS "$BFF_URL/health" | jq -c '.dependencies')"
pass "dependencies.fleetbase.reachable = true"

# ── missing : la course disparue de Fleetbase ──────────────────────────────
step "Course DISPARUE de Fleetbase → « missing », pas un 500"
# La course reste dans le cache local ; seule sa contrepartie Fleetbase part.
# Le merge doit donc la remonter marquée « missing », PAS la faire disparaître
# en silence (ce qui laisserait le commerçant croire qu'elle n'a jamais existé).
fb_api DELETE "/int/v1/orders/$O" >/dev/null 2>&1 || fail "Suppression de O chez Fleetbase impossible"
liste="$(mapi GET /commercant/commandes?limit=100)"
echo "$liste" | jq -e '.orders|type=="array"' >/dev/null 2>&1 || fail "La liste a planté après suppression" "$(echo "$liste" | head -c 200)"
echo "$liste" | jq -e '[.orders[] | select(.uuid==$o and .missing==true)] | length == 1' --arg o "$O" >/dev/null \
  || fail "O devrait remonter marquée « missing », pas disparaître" "$(echo "$liste" | jq -c '[.orders[]|{uuid,missing}]' 2>/dev/null | head -c 300)"
pass "TÉMOIN : la course disparue remonte « missing », sans planter la liste"

# ── stale : Fleetbase injoignable ──────────────────────────────────────────
step "Fleetbase INJOIGNABLE → « stale » + /health reste ok"
docker stop "$FB_HTTPD" >/dev/null 2>&1 || fail "Impossible d'arrêter $FB_HTTPD"
sleep 2

h="$(curl -sS -m 10 "$BFF_URL/health" | jq -r '.status // "ERR"')"
[ "$h" = "ok" ] || fail "/health devrait rester ok Fleetbase à terre, a rendu « $h »"
pass "/health reste « ok » (il lit le local, pas Fleetbase)"

# ⚠️ Mais il DIT que la dépendance est tombée — sans échouer lui-même.
[ "$(fb_reachable)" = "false" ] \
  || fail "/health devrait rapporter fleetbase.reachable=false Fleetbase à terre" "$(curl -sS -m 10 "$BFF_URL/health" | jq -c '.dependencies')"
pass "dependencies.fleetbase.reachable = false — l'état est rapporté, pas caché"

# ── 503 et non 400 : une liste qui interroge vraiment Fleetbase ─────────────
step "Un refus dû à l'amont sort en 503 (« réessaie »), pas en 400"
code_http="$(curl -sS -m 40 -o /tmp/res503 -w '%{http_code}' "$BFF_URL/transporteur/commandes?type=adhoc" -H "Authorization: Bearer $Z_TOKEN")"
code_err="$(jq -r '.code // empty' /tmp/res503 2>/dev/null)"
echo "   /transporteur/commandes Fleetbase à terre → HTTP $code_http, code « $code_err »"
[ "$code_http" = "503" ] \
  || fail "Devrait être 503 (Service Unavailable), a rendu $code_http" "un 400 dirait au client « ta requête est fautive » et le découragerait de réessayer"
[ "$code_err" = "order.fetch_failed" ] || fail "Le code devrait rester order.fetch_failed (« $code_err »)"
pass "TÉMOIN : HTTP 503 + order.fetch_failed — le statut dit enfin la vérité"

detail="$(mapi GET "/commercant/commandes/$P")"
echo "$detail" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "La fiche a planté Fleetbase à terre" "$(echo "$detail" | jq -c '{statusCode,code}' 2>/dev/null)"
[ "$(echo "$detail" | jq -r '.stale // false')" = "true" ] \
  || fail "La fiche devrait être « stale » Fleetbase à terre" "$(echo "$detail" | jq -c '{stale,degraded,status}' 2>/dev/null)"
pass "TÉMOIN : la fiche est « stale » (servie du cache), pas un 500"

docker start "$FB_HTTPD" >/dev/null 2>&1
for i in $(seq 1 30); do curl -s -o /dev/null -m 3 "http://localhost:8000" 2>/dev/null && break; sleep 2; done
pass "Fleetbase rallumé"

# ── Ménage ──
mapi POST "/commercant/commandes/$P/annuler" '{}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Fleetbase dégradé DÉGRADE l'affichage, il ne le casse pas :"
echo "   course disparue absorbée, fiche « stale » servie du cache,"
echo "   /health toujours ok mais RAPPORTE la dépendance à terre,"
echo "   et un refus dû à l'amont sort en 503, pas en 400."
echo "════════════════════════════════════════════════════════════════"
