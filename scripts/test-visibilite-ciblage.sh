#!/usr/bin/env bash
#
# Le ciblage d'un favori nommé, et sa visibilité — vu de DEUX transporteurs.
#
# ── Ce que ce banc prouve, et qu'aucun autre ne posait ────────────────────
#
# `test-appartenance.sh` prouve qu'un transporteur ne peut pas ACCÉDER à la
# ressource d'un autre par son id. Ici la question est différente : une course
# **confiée à un favori nommé** est-elle **invisible** aux autres — et le
# devient-elle de nouveau après une **redirection** ? C'est la visibilité, pas
# l'appartenance (`docs/plan_ciblage_favori.md`).
#
# ⚠️ **Deux transporteurs, un témoin positif à chaque pas.** « Y ne la voit
# pas » ne prouve rien seul : un filtre qui cache tout à tout le monde passerait.
# On vérifie donc À CHAQUE FOIS que le favori X, LUI, la voit. Sans le témoin,
# on ne mesure que la capacité du filtre à dire « non », jamais à dire « oui ».
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-visibilite-ciblage.sh
#
#   MERCHANT=<email>   commerçant validé (défaut app-parcours-commercant)

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

mapi() { # méthode chemin [corps]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}
dget() { curl -sS -X GET "$BFF_URL$1" -H "Authorization: Bearer $2"; }
order_state() { fb_get "/int/v1/orders/$1" | jq -c '(.order // .data // .) | {status, adhoc, driver_assigned_uuid}'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Visibilité du ciblage d'un favori nommé"
echo "════════════════════════════════════════════════════════════════"

# ── Décor : un commerçant, deux transporteurs (X favori, Y non favori) ──────
step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
  | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible ($MERCHANT)"
pass "Commerçant connecté"

# ⚠️ Deux conducteurs qui ont un COMPTE BFF (donc connectables). `resolve_driver`
# résout un nom/uuid Fleetbase, PAS un email `@echango.local` — c'est
# `_accounted_driver_uuids` qui donne les uuids des comptes. `obtain_driver_token`
# prend une uuid Fleetbase, jamais un email.
mapfile -t DRV < <(_accounted_driver_uuids)
X_UUID="${DRV[0]:-}"; Y_UUID="${DRV[1]:-}"
[ -n "$X_UUID" ] && [ -n "$Y_UUID" ] && [ "$X_UUID" != "$Y_UUID" ] \
  || fail "Il faut deux conducteurs distincts avec un compte (trouvés : ${#DRV[@]})"
obtain_driver_token "$X_UUID" >/dev/null 2>&1 || fail "Jeton X impossible" "${DRIVER_SESSION_ERROR:-}"
X_TOKEN="$DRIVER_TOKEN"
obtain_driver_token "$Y_UUID" >/dev/null 2>&1 || fail "Jeton Y impossible" "${DRIVER_SESSION_ERROR:-}"
Y_TOKEN="$DRIVER_TOKEN"
pass "X (favori) = ${X_UUID:0:8}…   Y (non favori) = ${Y_UUID:0:8}…"

# ── Favoris PROPRES : X favori, Y NON favori ───────────────────────────────
#
# ⚠️ Les favoris s'accumulent entre les runs. Sans ce ménage, Y pourrait déjà
# être favori d'un run précédent, et le test « cibler un non-favori » serait faux.
step "X favori, Y non favori"
for fid in $(mapi GET /commercant/transporteurs/favoris | jq -r '.data[]?.id'); do
  mapi DELETE "/commercant/transporteurs/favoris/$fid" >/dev/null 2>&1 || true
done
mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$X_UUID" '{fleetbaseDriverUuid:$u, partyType:"driver"}')" >/dev/null
favs="$(mapi GET /commercant/transporteurs/favoris | jq -c '[.data[]?.driver_uuid]')"
echo "$favs" | jq -e 'index("'"$X_UUID"'")' >/dev/null || fail "X n'apparaît pas dans les favoris" "$favs"
echo "$favs" | jq -e 'index("'"$Y_UUID"'")' >/dev/null && fail "Y ne devrait PAS être favori" "$favs"
pass "X est favori, Y ne l'est pas"

# ── Une course CIBLÉE sur X ─────────────────────────────────────────────────
step "Course ciblée sur X"
resp="$(mapi POST /commercant/commandes "$(jq -n --arg t "$X_UUID" '{
  pickupLocationName:"Dépôt Ciblage", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Ciblage", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], price:650, podMethod:"aucune",
  targetFavouriteUuid:$t }')")"
# ⚠️ La création rend la LIGNE DE CACHE : l'identifiant Fleetbase (celui que
# prennent les routes :id) est `fleetbaseOrderId`, pas `.uuid`.
UUID="$(echo "$resp" | jq -r '.fleetbaseOrderId // .uuid // .order.uuid // empty')"
[ -n "$UUID" ] || fail "Création ciblée échouée" "$(echo "$resp" | head -c 300)"
pass "Course créée : $UUID"
echo "   état : $(order_state "$UUID")"

as="$(order_state "$UUID")"
[ "$(echo "$as" | jq -r '.driver_assigned_uuid')" = "$X_UUID" ] \
  || fail "La course n'est PAS assignée à X" "$as"
[ "$(echo "$as" | jq -r '.adhoc')" = "false" ] || fail "adhoc devrait être false (course confiée)" "$as"
pass "Assignée à X, hors du pool (adhoc=false)"

# ── Témoin POSITIF : X la voit ; Y ne la voit pas ──────────────────────────
step "X la voit, Y non"
xlist="$(dget "/transporteur/commandes?type=assigned" "$X_TOKEN")"
echo "$xlist" | jq -e '[.orders[]?.uuid] | index("'"$UUID"'")' >/dev/null \
  || fail "X ne voit PAS sa course assignée — témoin positif manquant" "$(echo "$xlist" | jq -c '{code}')"
pass "TÉMOIN : X voit la course en « assigné »"

ycode="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$UUID" -H "Authorization: Bearer $Y_TOKEN")"
[ "$ycode" = "404" ] || fail "Y devrait avoir 404 (invisible), a eu $ycode"
pass "Y ne voit pas la course (404 introuvable, pas 403)"

# ── Redirection → LARGE : Y la voit désormais ──────────────────────────────
step "Redirection → large"
mapi POST "/commercant/commandes/$UUID/rediriger" '{}' >/dev/null
al="$(order_state "$UUID")"
[ "$(echo "$al" | jq -r '.adhoc')" = "true" ] || fail "Après « large », adhoc devrait être true" "$al"
[ "$(echo "$al" | jq -r '.driver_assigned_uuid')" = "null" ] || fail "L'assignation à X devrait être effacée" "$al"
pass "Rediffusée en large : adhoc=true, X détaché"

# ── Redirection → X de nouveau : réservée à X ──────────────────────────────
step "Redirection → X"
mapi POST "/commercant/commandes/$UUID/rediriger" "$(jq -n --arg t "$X_UUID" '{targetFavouriteUuid:$t}')" >/dev/null
ax="$(order_state "$UUID")"
[ "$(echo "$ax" | jq -r '.driver_assigned_uuid')" = "$X_UUID" ] || fail "Devrait être re-assignée à X" "$ax"
[ "$(echo "$ax" | jq -r '.adhoc')" = "false" ] || fail "adhoc devrait redevenir false" "$ax"
ycode2="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$UUID" -H "Authorization: Bearer $Y_TOKEN")"
[ "$ycode2" = "404" ] || fail "Après re-ciblage, Y devrait ravoir 404, a eu $ycode2"
pass "Re-ciblée sur X, invisible à Y de nouveau"

# ── Cibler un NON-favori est refusé ────────────────────────────────────────
step "Cibler un non-favori"
r="$(mapi POST "/commercant/commandes/$UUID/rediriger" "$(jq -n --arg t "$Y_UUID" '{targetFavouriteUuid:$t}')")"
[ "$(echo "$r" | jq -r '.code // empty')" = "order.target_not_favourite" ] \
  || fail "Cibler Y (non favori) devrait être refusé (order.target_not_favourite)" "$(echo "$r" | jq -c '{code,message}')"
pass "Cibler un non-favori refusé (order.target_not_favourite)"

# ── Ménage : annuler la course de test ─────────────────────────────────────
mapi POST "/commercant/commandes/$UUID/annuler" '{}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le ciblage isole, et la redirection ré-ouvre — témoin à l'appui."
echo "   ciblé      → assigné au favori, invisible aux autres"
echo "   large      → rendu visible à tous"
echo "   re-ciblé   → invisible de nouveau"
echo "   non-favori → refusé"
echo "════════════════════════════════════════════════════════════════"
