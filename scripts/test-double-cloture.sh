#!/usr/bin/env bash
#
# Une déclaration d'encaissement est IMMUABLE une fois la livraison close.
#
# ── Ce que ce banc éprouve, et pourquoi il pourrait trouver un vrai défaut ─────
#
# « Livré » et « perçu X » sont un seul fait : une fois la course clôturée, le
# montant déclaré à la porte fait partie du dossier clos. Rien ne doit pouvoir le
# réécrire — surtout pas un second `POST /terminer`.
#
# Or `completeOrder` appelle `recordCollectionIfDue` **avant** la clôture
# Fleetbase, et `recordCollectionIfDue` n'a **aucune garde « déjà complétée »**
# (`transporteur.service.ts:1265`, le commentaire du code note lui-même que
# l'idempotence n'est acquise que pour une réécriture IDENTIQUE). La crainte : un
# second `/terminer {collectedAmount:0}` — « zéro perçu » est légal avec un motif
# — **écraserait** un 2000 honnête à 0, puis échouerait à re-clôturer chez
# Fleetbase. L'appelant verrait une erreur, mais le montant serait déjà corrompu.
#
# ⚠️ **La déclaration vit dans les CHAMPS PERSONNALISÉS, invisible à `fb_get`.**
# On la relit donc par la route du commerçant `GET /commercant/encaissements`,
# qui la sert via `effectiveMeta` sous `.collected[].collected_amount` — la même
# valeur que voit le commerçant à l'écran, celle qui fait foi.
#
# ── Ce qui compte comme succès ────────────────────────────────────────────────
#
# Que le montant honnête (2000) SURVIVE à la seconde clôture — que celle-ci soit
# refusée `already_*`, `not_found`, ou `complete_failed` importe moins que
# l'immuabilité du montant. Le banc RÉUSSIT si 2000 tient, il ÉCHOUE (révélant le
# défaut) s'il retombe à 0. Il est donc utile dans les deux mondes : il prouve
# l'invariant, ou il montre exactement où il se brise.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-double-cloture.sh

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

publish_cod() { # cod -> fleetbaseOrderId
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n --argjson c "$1" '{
    pickupLocationName:"Dépôt Double", pickupLatitude:36.7538, pickupLongitude:3.0588,
    pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
    dropoffLocationName:"Client Double", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
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

# Le montant ENREGISTRÉ que le commerçant voit, via effectiveMeta. "none" si absent.
recorded_amount() { # orderUuid
  local v; v="$(mapi GET /commercant/encaissements \
    | jq -r --arg o "$1" '[(.collected // [])[] | select(.uuid==$o) | .collected_amount] | .[0] // empty')"
  [ -n "$v" ] && echo "$v" || echo "none"
}

order_status() { fb_get "/int/v1/orders/$1" | jq -r '(.order//.data//.).status'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Double clôture : la déclaration d'encaissement est-elle immuable ?"
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

step "Course COD=2000, prise, démarrée, puis clôturée à 2000"
C="$(publish_cod 2000)"; [[ "$C" == ERR:* ]] && fail "Publication" "$C"
dapi POST "/transporteur/commandes/$C/accepter" '{}' >/dev/null
dapi POST "/transporteur/commandes/$C/demarrer" '{}' >/dev/null
r1="$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":2000}')"
echo "$r1" | jq -e 'type=="object" and (.statusCode|type)!="number"' >/dev/null 2>&1 \
  || fail "Première clôture à 2000 refusée" "$(echo "$r1" | jq -c '{code,message}')"
[ "$(order_status "$C")" = "completed" ] || fail "La course n'est pas clôturée après la 1ʳᵉ déclaration"
pass "Clôturée, 2000 déclarés"

step "TÉMOIN : le commerçant voit bien 2000 enregistrés"
base="$(recorded_amount "$C")"
[ "$base" = "2000" ] || fail "Le montant enregistré n'est pas 2000 mais « $base »" \
  "sans ce témoin, la suite ne prouverait rien (règle 8)"
pass "Montant enregistré = 2000"

step "ATTAQUE : une SECONDE clôture à 0 (zéro perçu, avec motif)"
r2="$(dapi POST "/transporteur/commandes/$C/terminer" '{"collectedAmount":0,"discrepancyReason":"refus_de_payer"}')"
code2="$(echo "$r2" | jq -r '.code // (if (.statusCode|type)=="number" then "HTTP_"+(.statusCode|tostring) else "2xx_ACCEPTÉ" end)')"
echo "   seconde clôture → $code2"

step "VERDICT : la seconde clôture est refusée ET le montant survit"
after="$(recorded_amount "$C")"
echo "   montant enregistré après l'attaque : $after (était 2000)"

# Le cœur : le montant honnête ne doit pas avoir bougé.
[ "$after" = "2000" ] || fail \
  "DÉFAUT — la déclaration de 2000 a été réécrite à « $after » par une clôture « $code2 »" \
  "une livraison encaissée 2000 se lit désormais « $after » chez le commerçant, en silence"

# Et une re-clôture doit être un REFUS CODÉ, jamais un succès muet : sans quoi
# le montant « survit » aujourd'hui par chance mais rien ne l'y oblige.
[ "$code2" = "order.already_terminal" ] || fail \
  "La seconde clôture n'est pas refusée par order.already_terminal (obtenu « $code2 »)" \
  "une livraison close doit refuser toute re-clôture, pas l'accepter en silence"

pass "IMMUABLE — 2000 préservé, seconde clôture refusée (order.already_terminal)"

# La course doit rester close, et non ré-ouverte par l'attaque.
[ "$(order_status "$C")" = "completed" ] || fail "La seconde clôture a changé le statut de la course"

free_z
echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ La déclaration d'encaissement d'une livraison close est immuable :"
echo "   une seconde clôture ne réécrit pas le montant déjà déclaré."
echo "════════════════════════════════════════════════════════════════"
