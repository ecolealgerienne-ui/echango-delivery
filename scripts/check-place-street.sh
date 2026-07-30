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
#   ./scripts/check-place-street.sh
#
# Les identifiants sont lus dans backend/bff/.env. Les passer à la main reste
# possible et prime sur le fichier, mais ce n'est pas le chemin recommandé :
# **un token Sanctum contient un `|`**, que le shell interprète comme un tube
# s'il n'est pas entre guillemets — la variable part alors vide et le script
# annonce une clé manquante alors qu'elle a été fournie.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/backend/bff/.env}"

# Lecture ligne à ligne plutôt que `source` : le fichier n'est pas du shell, et
# une valeur contenant `|`, `$` ou une espace serait exécutée au lieu d'être
# lue. On ne prend que les deux clés attendues.
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

if [[ -z "$API_KEY" ]]; then
  echo "FLEETBASE_API_KEY introuvable." >&2
  echo "Cherchée dans l'environnement, puis dans $ENV_FILE." >&2
  exit 1
fi

command -v jq >/dev/null || { echo "jq requis." >&2; exit 1; }

# `host.docker.internal` est l'adresse de la machine hôte **vue depuis un
# conteneur**. C'est la bonne valeur dans le .env, que le BFF lit depuis son
# conteneur, et elle ne résout pas depuis un shell de l'hôte. Plutôt que
# d'exiger une variable à chaque appel, on retombe sur `localhost` : c'est la
# même machine, désignée depuis l'autre côté.
fetch() {
  # `--fail` et non `--fail-with-body` : ce dernier n'existe qu'à partir de
  # curl 7.76, et le corps d'une réponse en erreur ne nous sert à rien ici.
  curl -sS --fail -H "Authorization: Bearer $API_KEY" \
    "$1/int/v1/places?limit=200"
}

if ! response="$(fetch "$API_URL" 2>/dev/null)"; then
  fallback="${API_URL/host.docker.internal/localhost}"
  if [[ "$fallback" != "$API_URL" ]]; then
    echo "== $API_URL injoignable depuis ce shell, essai sur $fallback ==" >&2
    API_URL="$fallback"
    response="$(fetch "$API_URL")"
  else
    # Rejoué sans masquer la sortie : l'erreur de curl dit quoi corriger.
    fetch "$API_URL" >/dev/null
    exit 1
  fi
fi

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
