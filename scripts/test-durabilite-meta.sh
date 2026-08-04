#!/usr/bin/env bash
#
# La console écrase `meta` — prix et montant à encaisser SURVIVENT.
#
# ── Le défaut fondateur, jamais prouvé de bout en bout ────────────────────────
#
# Affecter un transporteur depuis la console Fleetbase **écrase le `meta` de la
# commande** (constaté le 30/07/2026 : il ne restait que `{_index_resource:true}`).
# Prix, montant à encaisser et options disparaissaient au moment précis où
# quelqu'un prenait la course en charge. La parade a été de déplacer ces données
# vers les **champs personnalisés** (`custom_field_values`), une table séparée que
# le `PUT` de `meta` ne touche pas — et `effectiveOrderMeta` les sert par-dessus
# `meta`, la couche durable gagnant.
#
# Tout cela est prouvé en UNITAIRE (`order-custom-fields.spec.ts`). Mais la
# promesse — « un écrasement de `meta` côté console ne perd pas les montants » —
# n'a **jamais été jouée de bout en bout**. Ce banc l'écrase pour de vrai et
# vérifie que le commerçant lit toujours les bons montants.
#
# ── Le témoin négatif est indispensable ───────────────────────────────────────
#
# « Le commerçant voit toujours 700 » ne prouve rien si l'écrasement n'a pas eu
# lieu. On vérifie donc AUSSI que le `meta` BRUT a bel et bien perdu le prix —
# sinon la survie viendrait de `meta`, pas des champs personnalisés, et la
# durabilité ne serait pas démontrée.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-durabilite-meta.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }

# Ce que le commerçant lit sur sa fiche (meta effectif). "none" si absent.
merchant_meta() { # orderUuid field
  local v; v="$(mapi GET "/commercant/commandes/$1" | jq -r --arg f "$2" '.meta[$f] // empty')"
  [ -n "$v" ] && echo "$v" || echo "none"; }

raw_meta_price() { fb_get "/int/v1/orders/$1" | jq -r '(.order//.data//.).meta.price // "absent"'; }
raw_meta_keys()  { fb_get "/int/v1/orders/$1" | jq -c '(.order//.data//.).meta | keys'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Durabilité : la console écrase meta, les montants survivent"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
pass "Commerçant connecté"

step "Une course : prix 700, à encaisser 1300+700 = 2000"
resp="$(mapi POST /commercant/commandes "$(jq -n '{
  draft:true,
  pickupLocationName:"Dépôt Durabilité", pickupLatitude:36.7538, pickupLongitude:3.0588,
  pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
  dropoffLocationName:"Client Durabilité", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
  dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
  items:[{description:"colis", quantity:1}], podMethod:"aucune",
  price:700, codAmount:1300, codIncludesDelivery:false }')")"
C="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$C" ] || fail "Création échouée" "$(echo "$resp" | head -c 300)"
pass "Course $C"

step "TÉMOIN de départ : le commerçant voit 700 / 2000"
[ "$(merchant_meta "$C" price)" = "700" ]      || fail "price de départ ≠ 700 (« $(merchant_meta "$C" price) »)"
[ "$(merchant_meta "$C" cod_amount)" = "2000" ] || fail "cod_amount de départ ≠ 2000 (« $(merchant_meta "$C" cod_amount) »)"
pass "price=700, cod_amount=2000"

step "ATTAQUE : on ÉCRASE le meta comme le fait la console (assignation)"
fb_api PUT "/int/v1/orders/$C" '{"order":{"meta":{"_index_resource":true}}}' >/dev/null \
  || fail "Écrasement du meta impossible (Fleetbase)"

step "TÉMOIN NÉGATIF : le meta BRUT a bien perdu le prix"
echo "   meta brut après écrasement : $(raw_meta_keys "$C")"
[ "$(raw_meta_price "$C")" = "absent" ] \
  || fail "Le meta brut porte encore un prix (« $(raw_meta_price "$C") ») — l'écrasement n'a pas eu lieu, le test ne prouve rien"
pass "meta brut réduit à {_index_resource} — le prix n'y est plus"

step "VERDICT : le commerçant lit TOUJOURS 700 / 2000 (champs personnalisés)"
pa="$(merchant_meta "$C" price)"; ca="$(merchant_meta "$C" cod_amount)"
echo "   après écrasement, le commerçant voit : price=$pa  cod_amount=$ca"
[ "$pa" = "700" ] \
  || fail "DÉFAUT — le prix a disparu de la fiche commerçant (« $pa ») : la console l'a effacé pour de bon"
[ "$ca" = "2000" ] \
  || fail "DÉFAUT — le montant à encaisser a disparu (« $ca ») : le transporteur clôturerait sans savoir combien percevoir"
pass "DURABLE — price=700, cod_amount=2000 servis depuis les champs personnalisés, malgré le meta écrasé"

# ── Ménage ──────────────────────────────────────────────────────────────────
mapi POST "/commercant/commandes/$C/annuler" '{}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Un écrasement de meta (assignation console) ne perd ni le prix"
echo "   ni le montant à encaisser : les champs personnalisés tiennent."
echo "════════════════════════════════════════════════════════════════"
