#!/usr/bin/env bash
#
# Ce que le CONDUCTEUR voit du prix : la valeur, pas seulement la présence.
#
# ── Ce que ce banc éprouve, et ce qu'aucun autre ne posait ────────────────────
#
# `test-frontiere-projection.sh` vérifie que `cod_amount` **traverse** la
# projection jusqu'au conducteur — sa présence. Il ne vérifie **jamais sa
# valeur**. Or c'est sur ce nombre que le transporteur décide d'accepter une
# course et sait combien il retiendra à la porte : un `cod_amount` faux, et il
# accepte à l'aveugle ou rend la mauvaise somme.
#
# La règle, mesurée ici de bout en bout (commerçant → conducteur) :
#
#   • `meta.price` == ce que le commerçant a saisi ;
#   • livraison à la charge du destinataire (`codIncludesDelivery:false`) :
#     `cod_amount = marchandise + course` — 1300 + 650 = 1950, et
#     `cod_goods_amount = 1300` (la marchandise, conservée telle quelle) ;
#   • livraison comprise (`codIncludesDelivery:true`) : `cod_amount = marchandise`
#     — 1300, pas d'ajout ;
#   • livraison à la charge du destinataire SANS prix connu : refus
#     `order.cod_requires_price` — sinon le commerçant paierait la course à son
#     insu (`commercant.service.ts:379`).
#
# ⚠️ **Lu par le CONDUCTEUR**, pas par le commerçant : c'est la projection
# `projectOrderForDriver` qui fait foi ici, celle sur laquelle il parie. La
# course est confiée au conducteur (favori ciblé) pour être lisible sans dépendre
# de sa zone.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-tarification-conducteur.sh

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

free_z() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }

# Crée une course CIBLÉE sur Z, avec la tarification demandée. -> fleetbaseOrderId
# ou "ERR:<réponse>" (utilisé aussi pour éprouver un refus de création).
create_targeted() { # json_pricing_fields
  mapi POST /commercant/commandes "$(jq -n --arg t "$Z_UUID" --argjson pr "$1" '{
    pickupLocationName:"Dépôt Tarif", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Tarif", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
    items:[{description:"colis", quantity:1}], podMethod:"aucune",
    targetFavouriteUuid:$t } + $pr')"; }

# Ce que le conducteur lit sur la fiche. "none" si absent.
driver_meta() { # orderUuid field
  local v; v="$(dapi GET "/transporteur/commandes/$1" | jq -r --arg f "$2" '.meta[$f] // empty')"
  [ -n "$v" ] && echo "$v" || echo "none"; }

echo "════════════════════════════════════════════════════════════════"
echo "  Tarification vue par le conducteur — la valeur, pas la présence"
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
# Z favori du commerçant, pour pouvoir lui CIBLER les courses (fiche lisible).
mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$Z_UUID" '{fleetbaseDriverUuid:$u, partyType:"driver"}')" >/dev/null 2>&1 || true
pass "Commerçant + conducteur Z favori (${Z_UUID:0:8}…)"

# ── Cas A : livraison à la charge du destinataire → marchandise + course ────
step "A — codIncludesDelivery:false → cod_amount = 1300 + 650 = 1950"
CA="$(create_targeted '{"price":650,"codAmount":1300,"codIncludesDelivery":false}' | jq -r '.fleetbaseOrderId // empty')"
[ -n "$CA" ] || fail "Création A échouée"
pa="$(driver_meta "$CA" price)"; ca="$(driver_meta "$CA" cod_amount)"; ga="$(driver_meta "$CA" cod_goods_amount)"
echo "   conducteur voit : price=$pa  cod_amount=$ca  cod_goods_amount=$ga"
[ "$pa" = "650" ]  || fail "Le conducteur voit price=$pa, attendu 650 (le prix saisi par le commerçant)"
[ "$ca" = "1950" ] || fail "cod_amount=$ca, attendu 1950 (marchandise 1300 + course 650)"
[ "$ga" = "1300" ] || fail "cod_goods_amount=$ga, attendu 1300 (la marchandise, conservée)"
pass "price=650, cod_amount=1950, cod_goods_amount=1300 — ce qu'il encaissera est juste"
free_z

# ── Cas B : livraison comprise → pas d'ajout ────────────────────────────────
step "B — codIncludesDelivery:true → cod_amount = 1300 (pas d'ajout)"
CB="$(create_targeted '{"price":650,"codAmount":1300,"codIncludesDelivery":true}' | jq -r '.fleetbaseOrderId // empty')"
[ -n "$CB" ] || fail "Création B échouée"
cb="$(driver_meta "$CB" cod_amount)"; gb="$(driver_meta "$CB" cod_goods_amount)"; ib="$(driver_meta "$CB" cod_includes_delivery)"
echo "   conducteur voit : cod_amount=$cb  cod_goods_amount=$gb  cod_includes_delivery=$ib"
[ "$cb" = "1300" ] || fail "cod_amount=$cb, attendu 1300 (livraison comprise, aucun ajout)"
[ "$gb" = "1300" ] || fail "cod_goods_amount=$gb, attendu 1300"
[ "$ib" = "true" ] || fail "cod_includes_delivery=$ib, attendu true"
pass "cod_amount=1300 — la course n'est pas ajoutée deux fois"
free_z

# ── Cas C : à la charge du destinataire SANS prix → refus ───────────────────
step "C — codIncludesDelivery:false sans prix → order.cod_requires_price"
rc="$(create_targeted '{"codAmount":1300,"codIncludesDelivery":false}')"
code="$(echo "$rc" | jq -r '.code // empty')"
[ "$code" = "order.cod_requires_price" ] \
  || fail "Attendu order.cod_requires_price, obtenu « $code »" \
     "sans rémunération connue, ajouter la course ferait payer le commerçant à son insu — le refus est la bonne réponse ($(echo "$rc" | jq -c '{code,message}'))"
pass "Refusé (order.cod_requires_price) — le commerçant ne paie pas la course en douce"

# ── Ménage ──────────────────────────────────────────────────────────────────
mapi POST "/commercant/commandes/$CA/annuler" '{}' >/dev/null 2>&1 || true
mapi POST "/commercant/commandes/$CB/annuler" '{}' >/dev/null 2>&1 || true
mapi DELETE "/commercant/transporteurs/favoris/$Z_UUID" >/dev/null 2>&1 || true
free_z

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le conducteur voit le BON montant : prix saisi relayé, course"
echo "   ajoutée quand elle est à la charge du client, jamais en double,"
echo "   et refus net quand la rémunération manque."
echo "════════════════════════════════════════════════════════════════"
