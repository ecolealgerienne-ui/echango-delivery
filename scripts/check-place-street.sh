#!/usr/bin/env bash
#
# Est-ce que `street1` est réellement enregistré sur les lieux Fleetbase ?
#
# Répond en une exécution à la question qu'une capture d'écran ne peut pas
# trancher : la console affiche « RUE 1 : - » sur un lieu, mais il en existe
# plusieurs du même nom (chaque commande crée sa propre copie du point
# d'enlèvement), et rien ne dit lequel est l'entrée du carnet.
#
# Interroge Fleetbase directement, sans passer par le BFF ni par l'app : ce
# qui sort ici est ce qui est en base.
#
# Usage :
#   FLEETBASE_API_KEY=... ./scripts/check-place-street.sh
#   FLEETBASE_API_URL=http://localhost:8000 ./scripts/check-place-street.sh

set -euo pipefail

API_URL="${FLEETBASE_API_URL:-http://localhost:8000}"
API_KEY="${FLEETBASE_API_KEY:-}"

if [[ -z "$API_KEY" ]]; then
  echo "FLEETBASE_API_KEY manquante (le token Sanctum, pas la clé flb_live_)." >&2
  exit 1
fi

command -v jq >/dev/null || { echo "jq requis." >&2; exit 1; }

response="$(curl -sS -H "Authorization: Bearer $API_KEY" \
  "$API_URL/int/v1/places?limit=200")"

# Fleetbase enveloppe tantôt sous `places`, tantôt sous `data`.
places="$(echo "$response" | jq '.places // .data // []')"
total="$(echo "$places" | jq 'length')"

echo "== $total lieu(x) lus sur $API_URL =="
echo

echo "-- Lieux AVEC une rue enregistrée --"
with="$(echo "$places" | jq '[.[] | select((.street1 // "") != "")]')"
echo "$with" | jq -r '.[] | "  \(.public_id)  \(.name)  |  street1=\(.street1)  city=\(.city // "-")  owner=\(.owner_uuid // "aucun")"'
echo "  (total : $(echo "$with" | jq 'length'))"
echo

echo "-- Lieux appartenant à un Vendor (entrées de carnet) --"
# Les copies créées par une commande n'ont pas de propriétaire : c'est ce qui
# distingue l'entrée du carnet de ses homonymes.
echo "$places" | jq -r '.[] | select((.owner_uuid // "") != "") |
  "  \(.public_id)  \(.name)  |  street1=\(.street1 // "VIDE")  maj=\(.updated_at)"'
echo

echo "Lecture :"
echo "  • des lignes dans la 1re section  -> street1 est bien écrit ; la console"
echo "    montrait une autre copie du même lieu."
echo "  • 1re section vide, 2e non vide   -> l'écriture n'atteint pas la base ;"
echo "    c'est le BFF qu'il faut reprendre."
echo "  • 2e section vide                 -> aucune entrée de carnet ici :"
echo "    mauvaise instance, mauvaise organisation, ou owner_uuid perdu."
