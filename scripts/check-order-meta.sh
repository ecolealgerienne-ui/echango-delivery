#!/usr/bin/env bash
#
# Que contient réellement une commande côté Fleetbase ?
#
# Écrit pour une question précise : `meta` semble disparaître quand un admin
# affecte un transporteur depuis la console. Si c'est vrai, ce n'est pas un
# défaut d'affichage — `meta` porte le prix, le montant à encaisser, le colis
# et les précisions d'adresse. Perdre `cod_amount` signifie qu'aucun montant
# n'est réclamé à la porte, et que la déclaration d'encaissement n'a plus de
# montant attendu auquel se comparer.
#
# Le script lit la commande à l'unité, sans BFF ni app, et affiche `meta` en
# entier avec l'état d'affectation. Le lancer AVANT puis APRÈS une affectation
# depuis la console répond en deux exécutions.
#
# Usage :
#   ./scripts/check-order-meta.sh order_3iwkyblqqr
#   ./scripts/check-order-meta.sh <uuid>

set -euo pipefail

ORDER="${1:-}"
if [[ -z "$ORDER" ]]; then
  echo "Usage : $0 <public_id ou uuid de la commande>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/backend/bff/.env}"

# Lecture ligne à ligne plutôt que `source` : un token Sanctum contient un `|`,
# que le shell exécuterait.
read_env() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  local line
  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n 1)" || return 0
  [[ -n "$line" ]] || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

API_URL="${FLEETBASE_API_URL:-$(read_env FLEETBASE_API_URL)}"
API_URL="${API_URL:-http://localhost:8000}"
API_KEY="${FLEETBASE_API_KEY:-$(read_env FLEETBASE_API_KEY)}"

[[ -n "$API_KEY" ]] || { echo "FLEETBASE_API_KEY introuvable ($ENV_FILE)." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq requis." >&2; exit 1; }

fetch() {
  curl -sS --fail -H "Authorization: Bearer $API_KEY" \
    "$1/int/v1/orders/$ORDER?with[]=payload&with[]=driverAssigned"
}

# `host.docker.internal` est l'adresse de l'hôte vue depuis un conteneur : elle
# ne résout pas depuis un shell de ce même hôte.
if ! response="$(fetch "$API_URL" 2>/dev/null)"; then
  fallback="${API_URL/host.docker.internal/localhost}"
  if [[ "$fallback" != "$API_URL" ]]; then
    echo "== $API_URL injoignable, essai sur $fallback ==" >&2
    API_URL="$fallback"
    response="$(fetch "$API_URL")"
  else
    fetch "$API_URL" >/dev/null
    exit 1
  fi
fi

order="$(echo "$response" | jq '.order // .')"

echo "== $ORDER =="
echo "$order" | jq -r '"  statut      : \(.status)
  dispatché   : \(.dispatched)
  adhoc       : \(.adhoc)
  transporteur: \(.driver_assigned.name // .driver_assigned_uuid // "aucun")
  maj         : \(.updated_at)"'
echo

echo "-- meta --"
meta="$(echo "$order" | jq '.meta // {}')"
count="$(echo "$meta" | jq 'if type == "object" then (keys | length) else -1 end')"

if [[ "$count" == "-1" ]]; then
  echo "  ⚠️  meta n'est pas un objet : $(echo "$meta" | jq -c .)"
elif [[ "$count" == "0" ]]; then
  echo "  ⚠️  VIDE — tout ce que le commerçant a saisi a disparu :"
  echo "      prix, montant à encaisser, colis, précisions d'adresse."
else
  echo "$meta" | jq -r 'to_entries[] | "  \(.key) = \(.value | tostring)"'
  echo
  echo "  ($count clé(s))"
fi
echo

echo "-- champs personnalises (stockage DURABLE) --"
cfv="$(echo "$order" | jq '.custom_field_values // []')"
cfvcount="$(echo "$cfv" | jq 'length')"

if [[ "$cfvcount" == "0" ]]; then
  echo "  /!\  AUCUN - les donnees metier ne sont protegees que par meta,"
  echo "      qu'une affectation depuis la console efface."
else
  echo "$cfv" | jq -r '.[] | "  \(.custom_field.name // .custom_field_uuid) = \(.value | tostring)  [\(.value_type // "text")]"'
  echo
  echo "  ($cfvcount valeur(s))"
fi
echo

echo "-- les cles qui coutent de l'argent : ou sont-elles ? --"
for key in price cod_amount cod_goods_amount cod_includes_delivery; do
  name="$(echo "$key" | tr '_' '-')"
  durable="$(echo "$cfv" | jq -r --arg n "$name" '.[] | select(.custom_field.name == $n) | .value | tostring' | head -1)"
  fragile="$(echo "$meta" | jq -r --arg k "$key" '.[$k] // ""')"

  printf '  %-22s durable=%-12s meta=%s\n' "$key" "${durable:-ABSENT}" "${fragile:-absent}"
done
echo
echo "Lecture : \"durable\" doit etre renseigne. \"meta\" vide est NORMAL sur une"
echo "commande creee apres le 30/07/2026 : ces cles ont demenage, et les laisser"
echo "aux deux endroits ferait diverger l'affichage de la console le jour ou un"
echo "admin corrige un montant."
