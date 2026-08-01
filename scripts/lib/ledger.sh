#!/usr/bin/env bash
# Lectures du registre de caisse, pour les scripts de contrôle.
#
# ── Pourquoi une bibliothèque, et pourquoi celle-ci d'abord ────────────────
#
# Les deux scripts d'argent lisaient des soldes à la main, chacun à sa façon, et
# **tous deux terminaient par `printf '%.0f'` sur une valeur qui peut être
# vide**. Or `printf '%.0f' ""` rend `0` sans broncher : « le serveur n'a rien
# renvoyé » et « la dette est soldée » devenaient le même résultat.
#
# Ce n'est pas une imprécision d'affichage. Trois contrôles de ces scripts
# attendent **exactement 0** — ce sont ceux qui prouvent qu'une remise a soldé
# la dette. Un changement de contrat, une clé renommée, une réponse d'erreur :
# tout cela y passait pour un succès. C'est le « contrôle qui rassure » que la
# règle 10 nomme comme le pire endroit où mettre un repli.
#
# Constaté en réel le 01/08/2026 : « ✅ Confirmée — le conducteur est à jour
# ( DZD) ». Le montant manquant était le seul signe visible, et il était dans un
# message de succès.
#
# À sourcer :  . "$(dirname "$0")/lib/ledger.sh"

# Traduit une lecture de registre en nombre comparable — ou la rend telle quelle.
#
# ⚠️ **Ce qui n'est pas un nombre ressort INCHANGÉ**, et fait donc échouer la
# comparaison en s'affichant dans le message d'échec. La fonction ne peut pas
# refuser elle-même : elle s'emploie en substitution de commande, où un `fail`
# n'arrêterait que le sous-shell — le défaut payé le 31/07 sur les courses
# bloquantes.
amount_number() { # valeur -> nombre, ou la valeur telle quelle
  case "${1:-}" in
    # Le vocabulaire de `debt_toward`, traduit ici et nulle part ailleurs.
    aucune)        echo 0 ;;
    '')            echo '<vide>' ;;
    *[!0-9.eE+-]*) echo "$1" ;;
    *)             printf '%.0f' "$1" ;;
  esac
}

# La dette envers une contrepartie donnée.
#
# ⚠️ **Par contrepartie, jamais en sommant les soldes.** Sommer suppose que le
# compte démarre à zéro : vrai au premier run, faux ensuite — un conducteur
# réutilisé porte les dettes des runs précédents. C'est le défaut constaté en
# réel sur le scénario à deux acteurs (2600 au lieu de 1300, sur un code juste).
#
# ⚠️ **`first(…) // "aucune"` ne fonctionne pas**, et c'est le piège de ce
# fichier : sur un flux vide, `first` ne produit aucune valeur, donc `//` n'a
# rien à quoi s'appliquer et la sortie est **vide**. Le cas se produit dès
# qu'une dette est soldée — `balancesFor()` retire les soldes nuls de la liste
# (`filter(b => b.debt !== 0)`), donc la ligne n'y est plus du tout. Un tableau,
# lui, a toujours une longueur.
debt_toward() { # ledger_json counterparty_id -> nombre | aucune | sans-registre
  # Un registre sans `balances` n'est pas un registre vide : c'est une réponse
  # qu'on n'a pas su lire. Le dire par un mot qui n'est pas un nombre, pour
  # qu'aucune comparaison ne puisse l'accepter.
  echo "$1" | jq -e 'has("balances")' >/dev/null 2>&1 || { echo 'sans-registre'; return 0; }

  echo "$1" | jq -r --arg c "$2" \
    '[.balances[] | select(.counterparty_id == $c)]
     | if length == 0 then "aucune" else (.[0].debt | tostring) end'
}

# La somme des soldes d'un registre.
#
# Le registre n'expose aucun total : il n'a que `balances[].debt`, et la somme
# se fait côté client — cohérent avec « aucun solde n'est stocké ». Utile là où
# le compte est neuf et ne peut donc rien porter d'antérieur ; partout ailleurs,
# `debt_toward` est le bon outil.
ledger_total() { # ledger_json -> nombre | sans-registre
  echo "$1" | jq -e 'has("balances")' >/dev/null 2>&1 || { echo 'sans-registre'; return 0; }
  echo "$1" | jq -r '[.balances[].debt] | add // 0 | tostring'
}
