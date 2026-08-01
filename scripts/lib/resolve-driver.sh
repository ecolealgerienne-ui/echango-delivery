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

. "$(dirname "${BASH_SOURCE[0]}")/fleetbase.sh"

# Affiche les conducteurs, en disant lesquels sont **du pool**.
#
# Le rattachement n'est pas un détail décoratif : seule l'entreprise d'un
# conducteur peut lui créer un compte, et Echango seulement pour ceux que
# personne n'a rattachés (`assertDriverBelongsToFleet`). Une liste qui ne le
# dit pas fait choisir au hasard, puis échouer trois lignes plus loin sur un
# 403 dont la cause n'est lisible que dans le code du serveur.
_rd_list() { # affiche les conducteurs disponibles
  local drivers="$1"
  echo "   Conducteurs de l'organisation :" >&2
  echo "$drivers" | jq -r '.[] |
    "     \(.public_id // "?")  \(.name // "sans nom")  \(.email // .phone // "")"
    + (if (.vendor_uuid // null) == null then "  [pool]" else "  [rattaché]" end)' >&2
}

# Renseigne DRIVER_UUID / DRIVER_LABEL, ou renvoie 1 avec RESOLVE_DRIVER_ERROR.
resolve_driver() { # [identifiant]
  local needle="${1:-}"
  DRIVER_UUID=""; DRIVER_LABEL=""; RESOLVE_DRIVER_ERROR=""

  # ⚠️ **Le message est posé ICI, dans le parent, et jamais dans la fonction
  # appelée.** La version précédente faisait `RESOLVE_DRIVER_ERROR="$FLEETBASE_ERROR"`
  # à l'intérieur de la lecture — c'est-à-dire dans le sous-shell de la
  # substitution de commande, où la variable meurt. Le symptôme n'était pas une
  # erreur mais un message **vide**, que l'appelant remplaçait par son repli
  # « Conducteur introuvable » : une panne réseau envoyait donc chercher un
  # conducteur qui existe. Le détail Fleetbase, lui, passe par stderr.
  local drivers
  drivers="$(fb_drivers)" || {
    RESOLVE_DRIVER_ERROR="lecture des conducteurs impossible — détail Fleetbase ci-dessus"
    return 1
  }

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
