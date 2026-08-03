#!/usr/bin/env bash
#
# Le pool est MUTUALISÉ : un conducteur sert plusieurs commerçants.
#
# ── Ce que ce banc prouve, et pourquoi c'est LA thèse ─────────────────────
#
# `docs/specs_macro_drive_transport.md` §1.3 : « plus de commerçants → plus de
# transporteurs → plus de valeur ». L'effet réseau suppose un pool **partagé**,
# pas une flotte dédiée par commerçant. Or aucun banc ne le prouvait : les
# scénarios jouent un commerçant à la fois.
#
# Ici DEUX commerçants (A, B) publient chacun une course au pool, et UN seul
# conducteur Z — favori d'aucun des deux — accède aux deux et les prend. Si le
# pool cloisonnait par commerçant, Z ne verrait que l'un.
#
# ⚠️ **Prouvé par l'ACCÈS et l'ACCEPTATION, pas par la liste d'opportunités.**
# La liste adhoc est filtrée par zone/position/rayon — la confondre avec « le
# pool » mélangerait deux questions. Qu'un conducteur puisse RÉCLAMER une course
# de A puis une de B est la preuve directe et sans confusion que le pool ne le
# cloisonne pas.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-pool-mutualise.sh
#
#   MERCHANT_A / MERCHANT_B  commerçants validés (défauts ci-dessous)

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
. "$(dirname "$0")/lib/free-driver.sh"

login_merchant() { # email -> token sur stdout
  fb_activate_vendor_by_email "$1" >/dev/null 2>&1 || true
  curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty'
}

# Crée un BROUILLON diffusé (sans cible), le publie, et rend son uuid.
publish_broadcast() { # token label -> uuid sur stdout
  local tok="$1" label="$2" o uuid
  o="$(curl -sS -X POST "$BFF_URL/commercant/commandes" -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $tok" -d "$(jq -n --arg n "$label" '{
      pickupLocationName:("Dépôt "+$n), pickupLatitude:36.7538, pickupLongitude:3.0588,
      pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
      dropoffLocationName:("Client "+$n), dropoffLatitude:36.7500, dropoffLongitude:3.0600,
      dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
      items:[{description:"colis", quantity:1}], price:650, podMethod:"aucune",
      draft:true }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // .uuid // .order.uuid // empty')"
  [ -n "$uuid" ] || { echo "ERR_CREATE:$(echo "$o" | jq -c '{code,message}')"; return 1; }
  curl -sS -X POST "$BFF_URL/commercant/commandes/$uuid/publier" \
    -H "Authorization: Bearer $tok" >/dev/null
  echo "$uuid"
}

echo "════════════════════════════════════════════════════════════════"
echo "  Le pool est mutualisé — un conducteur, deux commerçants"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
TA="$(login_merchant "$MERCHANT_A")"; [ -n "$TA" ] || fail "Commerçant A ($MERCHANT_A)"
TB="$(login_merchant "$MERCHANT_B")"; [ -n "$TB" ] || fail "Commerçant B ($MERCHANT_B)"
pass "Deux commerçants connectés (A, B)"

# Un conducteur avec un compte BFF (connectable). Voir la note du même bloc dans
# test-visibilite-ciblage : `resolve_driver` ne résout pas un email `@echango.local`.
mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID="${DRV[0]:-}"
[ -n "$Z_UUID" ] || fail "Aucun conducteur avec un compte BFF"
# Z doit être LIBRE pour accepter (sinon « driver.unavailable »). On annule ses
# courses non terminées directement chez Fleetbase — `require_free_driver`
# dépend de fonctions (`dapi`, `pass`) définies par le scénario appelant.
for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" \
    '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
done
obtain_driver_token "$Z_UUID" >/dev/null 2>&1 || fail "Jeton Z impossible" "${DRIVER_SESSION_ERROR:-}"
Z_TOKEN="$DRIVER_TOKEN"
pass "Un conducteur Z, libre (${Z_UUID:0:8}…)"

step "A et B publient chacun une course au pool"
CA="$(publish_broadcast "$TA" "Pool-A")"; [[ "$CA" == ERR_CREATE:* ]] && fail "Publication A" "$CA"
CB="$(publish_broadcast "$TB" "Pool-B")"; [[ "$CB" == ERR_CREATE:* ]] && fail "Publication B" "$CB"
pass "Course de A : ${CA:0:8}…   Course de B : ${CB:0:8}…"

# Les deux doivent être diffusées (adhoc) et sans conducteur.
for pair in "A:$CA" "B:$CB"; do
  who="${pair%%:*}"; u="${pair#*:}"
  s="$(fb_get "/int/v1/orders/$u" | jq -c '(.order//.data//.)|{adhoc, driver_assigned_uuid}')"
  [ "$(echo "$s" | jq -r '.adhoc')" = "true" ] || fail "Course de $who pas diffusée" "$s"
done
pass "Les deux sont au pool (adhoc=true, sans conducteur)"

step "Z — un seul conducteur — VOIT les deux"
za="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$CA" -H "Authorization: Bearer $Z_TOKEN")"
zb="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$CB" -H "Authorization: Bearer $Z_TOKEN")"
[ "$za" = "200" ] || fail "Z ne voit pas la course de A ($za)"
[ "$zb" = "200" ] || fail "Z ne voit pas la course de B ($zb)"
pass "Z accède aux DEUX courses (A et B) — le pool ne le cloisonne pas"

step "Z PREND les deux — il sert les deux commerçants"
acc() { curl -sS -X POST "$BFF_URL/transporteur/commandes/$1/accepter" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $Z_TOKEN" -d '{}'; }
ra="$(acc "$CA")"; echo "$ra" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Z n'a pas pu prendre la course de A" "$(echo "$ra" | jq -c '{code,message}')"
rb="$(acc "$CB")"; echo "$rb" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Z n'a pas pu prendre la course de B" "$(echo "$rb" | jq -c '{code,message}')"

# Vérif : les deux courses portent désormais Z.
for pair in "A:$CA" "B:$CB"; do
  who="${pair%%:*}"; u="${pair#*:}"
  d="$(fb_get "/int/v1/orders/$u" | jq -r '(.order//.data//.).driver_assigned_uuid')"
  [ "$d" = "$Z_UUID" ] || fail "Course de $who non portée par Z après acceptation (driver=$d)"
done
pass "TÉMOIN : les deux courses portent Z — un conducteur a servi A ET B"

# ── Ménage : libérer Z et annuler ce qui reste ─────────────────────────────
curl -sS -X POST "$BFF_URL/transporteur/commandes/$CA/echec" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $Z_TOKEN" -d '{"reason":"client_absent"}' >/dev/null 2>&1 || true
curl -sS -X POST "$BFF_URL/transporteur/commandes/$CB/echec" -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $Z_TOKEN" -d '{"reason":"client_absent"}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le pool est mutualisé : un conducteur a vu ET pris une course"
echo "   de deux commerçants distincts. L'effet réseau ne cloisonne pas."
echo "════════════════════════════════════════════════════════════════"
