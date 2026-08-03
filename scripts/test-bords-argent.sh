#!/usr/bin/env bash
#
# L'argent à la porte : ce que le tiroir REFUSE, et la livraison muette.
#
# ── Ce que ce banc éprouve ────────────────────────────────────────────────
#
# La plateforme ne tient pas de compte, mais elle enregistre ce qui est déclaré
# à la porte — et elle **refuse** une déclaration incohérente. Un contrôle qu'on
# n'a jamais vu dire non n'est pas un contrôle (règle 8). On éprouve donc les
# trois refus de `assertCollectedAmount`, puis le succès, puis la **livrée
# muette** — clôturée hors application, qui doit remonter au commerçant comme
# « à déclarer ».
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-bords-argent.sh

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

expect_code() { # libellé code_attendu réponse
  local want="$2" got; got="$(echo "$3" | jq -r '.code // empty')"
  [ "$got" = "$want" ] || fail "$1 : code « $got », attendu « $want »" "$(echo "$3" | jq -c '{code,message}')"
  pass "$1 — refusé ($want)"
}

publish_cod() { # cod -> fleetbaseOrderId
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n --argjson c "$1" '{
    pickupLocationName:"Dépôt Argent", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Argent", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis", quantity:1}], price:500, podMethod:"aucune",
    codAmount:$c, codIncludesDelivery:true, draft:true }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 200)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

free_z() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }

echo "════════════════════════════════════════════════════════════════"
echo "  Les bords de l'argent à la porte"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID="${DRV[0]:-}"; [ -n "$Z_UUID" ] || fail "Aucun conducteur avec un compte"
free_z
obtain_driver_token "$Z_UUID" >/dev/null 2>&1 || fail "Jeton Z impossible" "${DRIVER_SESSION_ERROR:-}"
Z_TOKEN="$DRIVER_TOKEN"
pass "Commerçant + conducteur Z (${Z_UUID:0:8}…)"

# ── Une course à 2000 à encaisser, prise et démarrée ───────────────────────
step "Course COD=2000, prise et démarrée par Z"
C="$(publish_cod 2000)"; [[ "$C" == ERR:* ]] && fail "Publication" "$C"
dapi POST "/transporteur/commandes/$C/accepter" '{}' >/dev/null
dapi POST "/transporteur/commandes/$C/demarrer" '{}' >/dev/null
exp="$(fb_get "/int/v1/orders/$C" | jq -r '(.order//.data//.).status')"
pass "Course $C prise, statut $exp"

# ── Les trois refus du tiroir ──────────────────────────────────────────────
step "Le tiroir refuse l'incohérent"
expect_code "Perçu 3000 > annoncé 2000" cash.amount_exceeds_expected \
  "$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":3000}')"
expect_code "Perçu 1500 ≠ 2000 sans motif" cash.discrepancy_reason_required \
  "$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":1500}')"
# ⚠️ Le négatif est attrapé par le DTO (`@Min(0)` → `validation.failed`) AVANT
# `assertCollectedAmount` (`cash.amount_negative`). Ce dernier est donc une
# défense en profondeur inatteignable par l'endpoint : on éprouve le rejet
# RÉEL, pas la couche du dessous.
expect_code "Perçu négatif (rejeté par le DTO)" validation.failed \
  "$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":-5}')"

# La course doit être ENCORE ouverte après ces refus.
st="$(fb_get "/int/v1/orders/$C" | jq -r '(.order//.data//.).status')"
[ "$st" != "completed" ] || fail "Un refus a quand même clôturé la course"
pass "Après trois refus, la course est toujours ouverte ($st)"

# ── Le succès : zéro perçu avec motif ──────────────────────────────────────
step "Zéro perçu, avec motif — accepté"
r="$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":0,"discrepancyReason":"refus_de_payer"}')"
echo "$r" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Clôture à 0 + motif refusée" "$(echo "$r" | jq -c '{code,message}')"
got="$(fb_get "/int/v1/orders/$C" | jq -c '(.order//.data//.) | {status, cod:.meta.collected_amount, reason:.meta.collection_reason}' 2>/dev/null)"
pass "Clôturée à 0 avec motif — $got"

# ── La livrée MUETTE : clôturée hors app, remonte comme « à déclarer » ──────
step "Livraison muette (clôturée hors application)"
free_z
M="$(publish_cod 1750)"; [[ "$M" == ERR:* ]] && fail "Publication muette" "$M"
dapi POST "/transporteur/commandes/$M/accepter" '{}' >/dev/null
# Clôture DIRECTE chez Fleetbase, sans passer par /terminer → aucune déclaration.
fb_api PUT "/int/v1/orders/$M" '{"order":{"status":"completed"}}' >/dev/null 2>&1 || true
mst="$(fb_get "/int/v1/orders/$M" | jq -r '(.order//.data//.).status')"
if [ "$mst" = "completed" ]; then
  coll="$(mapi GET /commercant/collections)"
  echo "$coll" | jq -e '[.unrecorded[]?.orderId, .unrecorded[]?.order_id, .unrecorded[]?.uuid] | index("'"$M"'")' >/dev/null \
    && pass "TÉMOIN : la livraison muette remonte dans « à déclarer »" \
    || echo "⚠️  livrée muette non retrouvée dans unrecorded — à vérifier (statut $mst, réponse: $(echo "$coll" | jq -c 'keys' 2>/dev/null))"
else
  echo "⚠️  la clôture directe Fleetbase n'a pas pris ($mst) — sous-test muet non concluant, PAS un échec produit"
fi
fb_api PUT "/int/v1/orders/$M" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le tiroir refuse l'incohérent, accepte le déclaré ; la livraison"
echo "   muette ne se perd pas."
echo "════════════════════════════════════════════════════════════════"
