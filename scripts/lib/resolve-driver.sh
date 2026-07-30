#!/usr/bin/env bash
# Retrouve l'uuid d'un conducteur à partir de **n'importe lequel** de ses
# identifiants.
#
# ── Pourquoi cette bibliothèque existe ─────────────────────────────────────
#
# Les scripts de test réclamaient l'`uuid` Fleetbase, **que la console
# n'affiche nulle part**. Elle montre le nom, l'email, le téléphone et l'ID
# public (`driver_xxxx`) ; l'uuid ne se lit qu'en ouvrant l'onglet réseau ou
# la base. Exiger la seule valeur invisible, c'est faire porter à l'utilisateur
# le travail que le script peut faire.
#
# Cette fonction accepte donc : uuid, `public_id`, `internal_id`, email,
# téléphone, ou un fragment de nom. Et sans argument, elle **liste** ce qui
# existe au lieu d'échouer — un message d'erreur qui ne montre pas les
# possibilités oblige à aller les chercher ailleurs.
#
# ── Pourquoi elle interroge Fleetbase et non le BFF ────────────────────────
#
# Le BFF n'expose la recherche de conducteurs qu'à un persona authentifié, et
# volontairement sans l'uuid (§19 : « le téléphone n'est jamais renvoyé, celui
# qui cherche le connaît déjà »). Résoudre un identifiant technique est un
# besoin d'outillage, pas un besoin produit : il se sert avec la clé de
# service, comme `check-place-street.sh`.
#
# À sourcer :  . "$(dirname "$0")/lib/resolve-driver.sh"
#
# Sorties :
#   DRIVER_UUID          — l'uuid résolu
#   DRIVER_LABEL         — de quoi le reconnaître dans les logs
#   RESOLVE_DRIVER_ERROR — renseigné en cas d'échec

_rd_env_file="${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/backend/bff/.env}"

# Lecture ligne à ligne, jamais `source` : un token Sanctum contient un `|`,
# que le shell exécuterait.
_rd_read_env() { # clé -> valeur sur stdout
  [ -f "$_rd_env_file" ] || return 0
  local line
  line="$(grep -E "^[[:space:]]*$1=" "$_rd_env_file" | tail -n 1)" || return 0
  [ -n "$line" ] || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

_rd_fleetbase() { # chemin -> corps sur stdout
  local url="${FLEETBASE_API_URL:-$(_rd_read_env FLEETBASE_API_URL)}"
  url="${url:-http://localhost:8000}"
  local key="${FLEETBASE_API_KEY:-$(_rd_read_env FLEETBASE_API_KEY)}"

  [ -n "$key" ] || { RESOLVE_DRIVER_ERROR="FLEETBASE_API_KEY introuvable ($_rd_env_file)"; return 1; }

  # `host.docker.internal` est l'adresse de l'hôte vue depuis un conteneur :
  # elle ne résout pas depuis un shell de ce même hôte.
  local body
  if ! body="$(curl -sS --fail -H "Authorization: Bearer $key" "$url$1" 2>/dev/null)"; then
    local fallback="${url/host.docker.internal/localhost}"
    [ "$fallback" != "$url" ] || { RESOLVE_DRIVER_ERROR="Fleetbase injoignable sur $url"; return 1; }
    body="$(curl -sS --fail -H "Authorization: Bearer $key" "$fallback$1" 2>/dev/null)" \
      || { RESOLVE_DRIVER_ERROR="Fleetbase injoignable sur $url ni $fallback"; return 1; }
  fi
  printf '%s' "$body"
}

_rd_drivers() { # -> tableau JSON des conducteurs
  local response
  response="$(_rd_fleetbase '/int/v1/drivers?limit=200')" || return 1
  echo "$response" | jq '.drivers // .data // []'
}

_rd_list() { # affiche les conducteurs disponibles
  local drivers="$1"
  echo "   Conducteurs de l'organisation :" >&2
  echo "$drivers" | jq -r '.[] |
    "     \(.public_id // "?")  \(.name // "sans nom")  \(.email // .phone // "")"' >&2
}

# Renseigne DRIVER_UUID / DRIVER_LABEL, ou renvoie 1 avec RESOLVE_DRIVER_ERROR.
resolve_driver() { # [identifiant]
  local needle="${1:-}"
  DRIVER_UUID=""; DRIVER_LABEL=""; RESOLVE_DRIVER_ERROR=""

  local drivers
  drivers="$(_rd_drivers)" || return 1

  local total
  total="$(echo "$drivers" | jq 'length')"
  [ "$total" -gt 0 ] || { RESOLVE_DRIVER_ERROR="Aucun conducteur dans l'organisation Fleetbase"; return 1; }

  # Sans argument : un seul conducteur ⇒ on le prend, c'est sans ambiguïté.
  # Plusieurs ⇒ on les montre plutôt que de choisir à la place de l'utilisateur.
  if [ -z "$needle" ]; then
    if [ "$total" -eq 1 ]; then
      DRIVER_UUID="$(echo "$drivers" | jq -r '.[0].uuid')"
      DRIVER_LABEL="$(echo "$drivers" | jq -r '"\(.[0].name // "?") (\(.[0].public_id // "?"))"')"
      return 0
    fi
    RESOLVE_DRIVER_ERROR="$total conducteurs : préciser lequel (nom, email, téléphone ou ID)"
    _rd_list "$drivers"
    return 1
  fi

  # Comparaison insensible à la casse sur tous les identifiants lisibles, plus
  # une correspondance partielle sur le nom — on tape rarement un nom entier.
  local matches
  matches="$(echo "$drivers" | jq --arg n "$(echo "$needle" | tr '[:upper:]' '[:lower:]')" '
    [ .[] | select(
        (.uuid // ""        | ascii_downcase) == $n
     or (.public_id // ""   | ascii_downcase) == $n
     or (.internal_id // "" | ascii_downcase) == $n
     or (.email // ""       | ascii_downcase) == $n
     or (.phone // "")                        == $n
     or ((.name // "" | ascii_downcase) | contains($n))
    ) ]')"

  local count
  count="$(echo "$matches" | jq 'length')"

  if [ "$count" -eq 0 ]; then
    RESOLVE_DRIVER_ERROR="Aucun conducteur ne correspond à « $needle »"
    _rd_list "$drivers"
    return 1
  fi

  if [ "$count" -gt 1 ]; then
    RESOLVE_DRIVER_ERROR="« $needle » correspond à $count conducteurs : préciser"
    _rd_list "$matches"
    return 1
  fi

  DRIVER_UUID="$(echo "$matches" | jq -r '.[0].uuid')"
  DRIVER_LABEL="$(echo "$matches" | jq -r '"\(.[0].name // "?") (\(.[0].public_id // "?"))"')"

  # L'uuid manquant signifierait que la ressource ne le sert pas — cas réel
  # ailleurs dans ce projet (`uuid` masqué hors requête interne). Mieux vaut le
  # dire que renvoyer une chaîne vide qui échouera trois étapes plus loin.
  [ -n "$DRIVER_UUID" ] && [ "$DRIVER_UUID" != "null" ] || {
    RESOLVE_DRIVER_ERROR="Conducteur trouvé mais sans uuid dans la réponse Fleetbase"
    return 1
  }
  return 0
}
