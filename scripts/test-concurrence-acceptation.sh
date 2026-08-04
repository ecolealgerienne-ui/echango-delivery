#!/usr/bin/env bash
#
# Deux conducteurs, une course, le MÊME instant : un seul doit gagner.
#
# ── Ce que ce banc cherche, et pourquoi il est différent ──────────────────
#
# Les autres scénarios jouent des gestes SÉQUENTIELS. Celui-ci lance deux
# `accepter` **en parallèle** sur la même course diffusée. C'est le classique de
# toute place de marché : deux indépendants tapent « Prendre » à la même seconde.
#
# ⚠️ **La garde d'assignation est un lire-puis-agir** (`acceptOrder` lit
# `driver_assigned_uuid` puis assigne). Entre les deux, l'autre peut avoir
# assigné : c'est la fenêtre que ce banc éprouve. Le résultat correct est **un
# seul 2xx**, l'autre refusé — et la course portée par **exactement un**
# conducteur. Deux succès seraient une double-assignation : la course promise à
# deux personnes, l'argent compté deux fois.
#
# ⚠️ **Un banc de concurrence est probabiliste.** Un seul essai peut « passer »
# par chance (les deux requêtes sérialisées par le réseau). On répète, et on
# refuse de conclure « sûr » sur un unique tour — `ROUNDS` tours, un échec suffit.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-concurrence-acceptation.sh
#   ROUNDS=5   nombre de courses éprouvées (défaut 4)

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"
ROUNDS="${ROUNDS:-4}"

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

# Libère un conducteur : annule ses courses non terminées (Fleetbase direct).
free_driver() { # uuid
  for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" \
      '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
    fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
  done; }

publish_broadcast() { # -> fleetbaseOrderId
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n '{
    pickupLocationName:"Dépôt Concurrence", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Concurrence", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis", quantity:1}], price:650, podMethod:"aucune", draft:true }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 200)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

echo "════════════════════════════════════════════════════════════════"
echo "  Concurrence : deux 'accepter' simultanés, un seul gagnant"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"

mapfile -t DRV < <(_accounted_driver_uuids)
X_UUID="${DRV[0]:-}"; Y_UUID="${DRV[1]:-}"
[ -n "$X_UUID" ] && [ -n "$Y_UUID" ] && [ "$X_UUID" != "$Y_UUID" ] || fail "Deux conducteurs distincts requis"
free_driver "$X_UUID"; free_driver "$Y_UUID"
obtain_driver_token "$X_UUID" >/dev/null 2>&1 || fail "Jeton X impossible" "${DRIVER_SESSION_ERROR:-}"
X_TOKEN="$DRIVER_TOKEN"
obtain_driver_token "$Y_UUID" >/dev/null 2>&1 || fail "Jeton Y impossible" "${DRIVER_SESSION_ERROR:-}"
Y_TOKEN="$DRIVER_TOKEN"
pass "Commerçant + deux conducteurs (${X_UUID:0:8}…, ${Y_UUID:0:8}…)"

accept_bg() { # url token outfile
  curl -sS -o "$3" -w '%{http_code}' -X POST "$BFF_URL/transporteur/commandes/$1/accepter" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $2" -d '{}' > "$3.code"
}

step "$ROUNDS tours — deux acceptations lancées EN PARALLÈLE"
for r in $(seq 1 "$ROUNDS"); do
  free_driver "$X_UUID"; free_driver "$Y_UUID"
  C="$(publish_broadcast)"; [[ "$C" == ERR:* ]] && fail "Publication (tour $r)" "$C"

  # Les deux requêtes partent avant que l'une ait fini : c'est tout l'objet.
  accept_bg "$C" "$X_TOKEN" /tmp/cx &
  accept_bg "$C" "$Y_TOKEN" /tmp/cy &
  wait

  cx="$(cat /tmp/cx.code)"; cy="$(cat /tmp/cy.code)"
  # Combien ont RÉUSSI (2xx) ?
  won=0
  [ "$cx" = "200" ] || [ "$cx" = "201" ] && won=$((won+1))
  [ "$cy" = "200" ] || [ "$cy" = "201" ] && won=$((won+1))

  # Vérité de terrain : la course porte QUI, chez Fleetbase ?
  holder="$(fb_get "/int/v1/orders/$C" | jq -r '(.order//.data//.).driver_assigned_uuid')"

  echo "   tour $r : X→$cx  Y→$cy  | gagnants(2xx)=$won  | portée par ${holder:0:8}…"

  [ "$won" -eq 1 ] || fail "Tour $r : $won acceptations ont réussi — attendu EXACTEMENT une (double-assignation ?)" \
    "X: $(cat /tmp/cx | jq -c '{code}' 2>/dev/null)  Y: $(cat /tmp/cy | jq -c '{code}' 2>/dev/null)"
  { [ "$holder" = "$X_UUID" ] || [ "$holder" = "$Y_UUID" ]; } \
    || fail "Tour $r : la course n'est portée par aucun des deux ($holder)"
  free_driver "$X_UUID"; free_driver "$Y_UUID"
done

pass "TÉMOIN : sur $ROUNDS tours, TOUJOURS exactement un gagnant, jamais deux"

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ La course ne se donne qu'une fois : la garde d'assignation tient"
echo "   sous deux acceptations simultanées, sur $ROUNDS tours."
echo "════════════════════════════════════════════════════════════════"
