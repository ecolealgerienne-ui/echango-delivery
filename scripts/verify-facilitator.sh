#!/usr/bin/env bash
#
# Contrôle C1 — `facilitator_type` accepte-t-il « vendor » ?
#
# ── Pourquoi ce contrôle est le plus important du chantier facilitateur ─────
#
# Tout le lot 3 repose sur une hypothèse **jamais éprouvée** : que
# `facilitator_uuid` + `facilitator_type: 'vendor'` écrits directement sur une
# commande soient acceptés ET résolus par Fleetbase. Elle est déduite par
# symétrie avec `customer_type`, qui l'est — mais le journal §2.9 note que
# `customer` a un résolveur dédié (`normalizeCustomerType()`) et que
# `facilitator` **n'en a pas**. La seule source citée pour l'analogie la
# dément donc.
#
# ── Ce que ce script prouve, et pourquoi relire ne suffit pas ───────────────
#
# `specs_echango_delivery.md` §3.1 raconte le cas d'un `customer_type` stocké
# `\Fleetbase\FleetOps\Models\Vendor` — un backslash initial en trop. Valeur
# **bien présente en base et parfaitement relisible**, et pourtant la commande
# était invisible aux filtres. Un `2xx` et un écho de colonne ne prouvent donc
# rien.
#
# On prouve la RÉSOLUTION, en trois temps :
#   1. la relation `with[]=facilitator` rend-elle le bon Vendor ?
#   2. la commande remonte-t-elle par `?facilitator=<uuid>` — avec témoin ?
#   3. la valeur stockée est-elle celle qu'on a envoyée, au caractère près ?
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/verify-facilitator.sh                  # choisit une commande close
#   ./scripts/verify-facilitator.sh <uuid-commande>  # ou celle que vous voulez
#
# La commande est **remise dans son état d'origine** à la fin, succès ou échec.

set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

# shellcheck source=lib/fleetbase.sh
. "$(dirname "$0")/lib/fleetbase.sh"

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; }
step() { echo; echo "── $1 ──"; }

ORDER_UUID="${1:-}"
RESTORE_UUID=""

# Remet la commande comme on l'a trouvée — un contrôle ne doit pas laisser de
# trace, surtout sur une donnée qui décide à qui l'argent est dû.
restore() {
  [ -n "$RESTORE_UUID" ] || return 0
  echo
  echo "Restauration de $RESTORE_UUID…"
  if fb_api PUT "/int/v1/orders/$RESTORE_UUID" \
       '{"order":{"facilitator_uuid":null,"facilitator_type":null}}' >/dev/null; then
    echo "   facilitateur retiré"
  else
    echo "   ⚠️ échec : ${FLEETBASE_ERROR:-inconnu} — à retirer à la main en console"
  fi
}
trap restore EXIT

step "0. Fournisseur et commande de test"

vendors="$(fb_get '/int/v1/vendors?limit=200')" || { fail "Fleetbase injoignable" "${FLEETBASE_ERROR:-}"; exit 1; }
VENDOR_UUID="$(echo "$vendors" | jq -r '(.vendors // .data // []) | last.uuid // empty')"
VENDOR_NAME="$(echo "$vendors" | jq -r '(.vendors // .data // []) | last.name // empty')"
[ -n "$VENDOR_UUID" ] || { fail "aucun fournisseur dans cette organisation"; exit 1; }
pass "Fournisseur : $VENDOR_NAME ($VENDOR_UUID)"

if [ -z "$ORDER_UUID" ]; then
  orders="$(fb_get '/int/v1/orders?limit=100&sort=-created_at')" || { fail "lecture des commandes"; exit 1; }
  # Une commande TERMINÉE et sans facilitateur : la modifier n'a aucun effet
  # métier, et elle sera restaurée de toute façon.
  ORDER_UUID="$(echo "$orders" | jq -r '
    (.orders // .data // [])
    | map(select((.facilitator_uuid // null) == null and (.status == "completed" or .status == "canceled")))
    | first.uuid // empty')"
fi
[ -n "$ORDER_UUID" ] || { fail "aucune commande close sans facilitateur — passez-en une en argument"; exit 1; }
pass "Commande : $ORDER_UUID"

step "1. Écriture"

written="$(fb_api PUT "/int/v1/orders/$ORDER_UUID" \
  "$(jq -n --arg v "$VENDOR_UUID" '{order:{facilitator_uuid:$v, facilitator_type:"vendor"}}')")" \
  || { fail "écriture refusée" "${FLEETBASE_ERROR:-}"; exit 1; }
RESTORE_UUID="$ORDER_UUID"
pass "PUT accepté (ce qui ne prouve encore rien)"

step "2. La valeur stockée est-elle celle qu'on a envoyée ?"

after="$(fb_get "/int/v1/orders/$ORDER_UUID?with[]=facilitator")" || { fail "relecture impossible"; exit 1; }
node="$(echo "$after" | jq -c 'if .order then .order else . end')"

got_uuid="$(echo "$node" | jq -r '.facilitator_uuid // "absent"')"
got_type="$(echo "$node" | jq -r '.facilitator_type // "absent"')"

[ "$got_uuid" = "$VENDOR_UUID" ] \
  && pass "facilitator_uuid stocké à l'identique" \
  || fail "facilitator_uuid attendu $VENDOR_UUID, stocké « $got_uuid »"

# ⚠️ Comparaison au caractère près : c'est exactement ici qu'un
# `\Fleetbase\FleetOps\Models\Vendor` passerait pour un succès si on se
# contentait de vérifier que le champ est « rempli ».
if [ "$got_type" = "vendor" ]; then
  pass "facilitator_type stocké « vendor », sans réécriture par Fleetbase"
else
  fail "facilitator_type renvoyé « $got_type » et non « vendor »" \
       "C'est la forme que Fleetbase attend réellement : à reporter dans attachFacilitator()."
fi

step "3. La relation résout-elle le bon fournisseur ?"

rel_name="$(echo "$node" | jq -r '.facilitator.name // empty')"
rel_uuid="$(echo "$node" | jq -r '.facilitator.uuid // empty')"

if [ -n "$rel_uuid" ]; then
  [ "$rel_uuid" = "$VENDOR_UUID" ] \
    && pass "with[]=facilitator rend « $rel_name » — la relation résout" \
    || fail "la relation rend $rel_uuid au lieu de $VENDOR_UUID"
else
  fail "with[]=facilitator ne rend aucune relation" \
       "Le type stocké ne correspond peut-être pas à l'alias polymorphe attendu."
fi

step "4. Le filtre, avec témoin"

real="$(fb_get "/int/v1/orders?facilitator=$VENDOR_UUID&limit=100")" || { fail "filtre injouable"; exit 1; }
witness="$(fb_get '/int/v1/orders?facilitator=00000000-0000-0000-0000-000000000000&limit=100')" || true

n_real="$(echo "$real" | jq '(.orders // .data // []) | length')"
n_witness="$(echo "${witness:-{\}}" | jq '(.orders // .data // []) | length')"
mine="$(echo "$real" | jq -r --arg u "$ORDER_UUID" '(.orders // .data // []) | map(select(.uuid == $u)) | length')"

echo "   réel : $n_real commande(s) — témoin : $n_witness"

# Le témoin est ce qui distingue « filtre appliqué » de « filtre ignoré » : les
# données cherchées sont présentes dans les deux réponses quand le filtre est
# abandonné en silence, ce que Fleetbase fait pour tout paramètre inconnu.
if [ "$n_witness" != "0" ]; then
  fail "le témoin renvoie $n_witness commande(s) — le filtre est IGNORÉ" \
       "Tout ce qui repose sur ?facilitator= est alors sans effet."
elif [ "$mine" = "1" ]; then
  pass "la commande remonte par ?facilitator=, et le témoin rend 0"
else
  fail "le filtre rend 0 pour un uuid réel : la valeur stockée n'est pas exploitable" \
       "Stockée mais invisible — le cas du backslash de specs_echango_delivery.md §3.1."
fi

echo
echo "════════════════════════════════════════════════════════════"
echo " Ce que ce contrôle décide : si les quatre points passent,"
echo " attachFacilitator() est correct et le lot 3 tient. Sinon,"
echo " c'est la forme de facilitator_type qu'il faut corriger — et"
echo " la réponse est dans la sortie ci-dessus."
echo "════════════════════════════════════════════════════════════"
