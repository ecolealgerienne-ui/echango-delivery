#!/usr/bin/env bash
#
# Publication : si le dispatch échoue, l'étape 1 est COMPENSÉE (rétractée).
#
# ── Ce que ce banc éprouve, et la fenêtre qu'il ferme ─────────────────────────
#
# Publier une course se fait en deux écritures NON atomiques (règle 2, aucune
# transaction ne couvre notre Postgres et le MySQL de Fleetbase joint en HTTP) :
#
#   étape 1 — rendre la course réclamable (`releaseOrderToPool` → `adhoc: true`) ;
#   étape 2 — la dispatcher.
#
# L'étape 1 a déjà rendu la course réclamable par un transporteur (le filtre
# transporteur exige `adhoc === true`, pas `dispatched`). Si l'étape 2 échoue et
# que rien ne compense, la course reste **en circulation** — un transporteur la
# voit et peut la prendre — alors que le commerçant la croit encore en brouillon.
# Une commande orpheline pour le commerçant, réelle pour le réseau.
#
# `publishOrder` compense : sur un échec du dispatch, `withdrawFromDispatch`
# remet `adhoc: false`, et la course reste `created` (donc republiable — on ne
# mémorise aucun état parallèle, exprès). Ce banc force l'échec et vérifie la
# rétractation.
#
# ── Comment l'échec est injecté, de façon DÉTERMINISTE ────────────────────────
#
# On pose le drapeau `dispatched: true` sur la course chez Fleetbase, en gardant
# `status: created`. Le garde de brouillon ne regarde que le statut, donc la
# publication démarre ; l'étape 1 (qui ne touche pas `dispatched`) réussit ; puis
# l'étape 2 se heurte à « Order has already been dispatched! » et échoue. Pas
# d'injection de panne réseau fragile : un état d'entrée qui rend l'étape 2
# impossible.
#
# ── Ce qui prouve que la COMPENSATION a joué (et pas que l'étape 1 n'a jamais
#    tourné) ─────────────────────────────────────────────────────────────────
#
# Le message d'erreur vient du DISPATCH (« already been dispatched ») : il ne
# peut venir que de l'étape 2, donc l'étape 1 a bien tourné et a posé
# `adhoc: true`. Que la course ressorte `adhoc: false` est alors nécessairement
# l'effet de la compensation. Retirer la compensation la laisserait `adhoc: true`
# — c'est ce que cette garde refuse.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-compensation-publication.sh

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
order_state() { fb_get "/int/v1/orders/$1" | jq -c '(.order//.data//.) | {status, adhoc, dispatched, driver_assigned_uuid}'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Compensation : dispatch échoué → la course est rétractée"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
# Un conducteur, pour prouver que la course rétractée ne circule PAS.
mapfile -t DRV < <(_accounted_driver_uuids)
Z_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || true
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  [ "$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")" = "200" ] \
    && { Z_TOKEN="$DRIVER_TOKEN"; break; }
done
[ -n "$Z_TOKEN" ] || fail "Aucun conducteur connectable"
pass "Commerçant + un conducteur"

step "Un brouillon (created, adhoc=false)"
resp="$(mapi POST /commercant/commandes "$(jq -n '{
  draft:true,
  pickupLocationName:"Dépôt Compensation", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Compensation", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:600, podMethod:"aucune" }')")"
C="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$C" ] || fail "Création échouée" "$(echo "$resp" | head -c 300)"
init="$(order_state "$C")"
[ "$(echo "$init" | jq -r '.adhoc')" = "false" ] || fail "Le brouillon ne devrait pas être adhoc" "$init"
pass "Brouillon $C : $init"

step "Injection : dispatched=true (statut reste created) — l'étape 2 deviendra impossible"
fb_api PUT "/int/v1/orders/$C" '{"order":{"dispatched":true}}' >/dev/null || fail "Injection impossible"
inj="$(order_state "$C")"
[ "$(echo "$inj" | jq -r '.dispatched')" = "true" ] || fail "dispatched pas posé" "$inj"
[ "$(echo "$inj" | jq -r '.status')" = "created" ] || fail "le statut a bougé (le garde de brouillon refuserait)" "$inj"
pass "dispatched=true, status=created"

step "Publication : l'étape 2 échoue, l'étape 1 doit être compensée"
pub="$(mapi POST "/commercant/commandes/$C/publier" '{}')"
code="$(echo "$pub" | jq -r '.code // empty')"
msg="$(echo "$pub" | jq -r '.message // empty')"
echo "   réponse : code=$code  message=« ${msg:0:50} »"
[ "$code" = "order.publish_failed" ] \
  || fail "La publication devrait échouer en order.publish_failed (« $code »)" "$(echo "$pub" | jq -c '{code,message}')"
# Le message vient du DISPATCH : preuve que l'étape 2 a été atteinte, donc que
# l'étape 1 a tourné et a posé adhoc=true avant l'échec.
echo "$msg" | grep -qi "dispatch" \
  || fail "Le message ne vient pas du dispatch — l'échec n'est pas à l'étape 2" "message: $msg"
pass "Publication refusée par l'étape 2 (dispatch), l'étape 1 avait donc posé adhoc=true"

step "VERDICT : la course est RÉTRACTÉE, pas laissée en circulation"
fin="$(order_state "$C")"
echo "   état après échec : $fin"
[ "$(echo "$fin" | jq -r '.adhoc')" = "false" ] \
  || fail "DÉFAUT — la course est restée adhoc=true : réclamable par un transporteur alors que le commerçant la croit en brouillon (compensation absente)" "$fin"
[ "$(echo "$fin" | jq -r '.status')" = "created" ] \
  || fail "La course devrait rester 'created' (republiable), lue « $(echo "$fin" | jq -r '.status')»"
pass "adhoc=false (rétractée), status=created (republiable)"

step "TÉMOIN aval : un transporteur ne la voit pas"
zcode="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$C" -H "Authorization: Bearer $Z_TOKEN")"
[ "$zcode" = "404" ] || fail "Un transporteur voit la course rétractée (HTTP $zcode) — elle circule encore"
pass "Le transporteur a 404 sur la course rétractée — elle ne circule pas"

# ── Ménage ──────────────────────────────────────────────────────────────────
fb_api PUT "/int/v1/orders/$C" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Un dispatch échoué ne laisse pas une course réclamable : l'étape 1"
echo "   est rétractée (adhoc=false), et la course reste republiable."
echo "════════════════════════════════════════════════════════════════"
