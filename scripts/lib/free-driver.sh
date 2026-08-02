#!/usr/bin/env bash
# Exiger un conducteur libre — ou le libérer, sur demande explicite.
#
# ── Pourquoi une bibliothèque ──────────────────────────────────────────────
#
# Ces deux fonctions vivaient dans `test-parcours-argent-flotte.sh`. Quatre
# scénarios créent désormais des courses et se heurtent au même refus
# (`driver.unavailable`), et trois d'entre eux **laissaient le conducteur
# occupé** en cas d'échec — donc se bloquaient eux-mêmes à la tentative
# suivante, sans dire pourquoi. Constaté le 01/08/2026 : cinq courses restées
# `started` par des exécutions interrompues, qui ont fait échouer le scénario
# flotte pour une raison étrangère à ce qu'il testait.
#
# Le critère de la règle 5 répond oui : si le prédicat « occupé » change côté
# serveur, il doit changer pour tous les scripts à la fois. Une copie qui diverge
# ne produit pas d'erreur — elle déclare « conducteur libre » un conducteur qui
# ne l'est pas, et l'échec survient dix étapes plus loin.
#
# À sourcer APRÈS `lib/fleetbase.sh`, et après que l'appelant ait défini
# `dapi`, `is_error`, `pass` et `fail`.
#
# ── Ce que le prédicat reprend, et pourquoi ───────────────────────────────
#
# Il est **repris de `driverIsBusy()`**, ses deux moitiés comprises : assignée et
# non terminale, **et sans signalement d'échec**. Fleetbase n'ayant pas de statut
# « échec », une course dont l'échec a été signalé reste assignée pour toujours ;
# sans cette seconde moitié, un client absent immobiliserait le conducteur à vie.
# `?type=assigned` rend exactement la première moitié, avec le signalement
# attaché quand il existe — les deux se lisent donc ici sans rien redériver.

# Les courses qui rendent le conducteur « occupé », telles que le serveur les
# compte.
#
# ⚠️ **Renseigne `BLOCKING`, et n'imprime rien.** La première version rendait la
# liste sur sa sortie standard, donc s'appelait `$(blocking_orders)` — et un
# `fail()` déclenché là-dedans n'arrête que le SOUS-SHELL de la substitution :
# son message part dans la variable au lieu de l'écran, et `set -e` tue ensuite
# le script sans un mot. Le seul cas où ce contrôle avait quelque chose à dire
# était donc le seul où il se taisait.
BLOCKING=""
read_blocking_orders() {
  local list
  list="$(dapi GET '/transporteur/commandes?type=assigned')"

  if echo "$list" | is_error; then
    fail "Lecture des courses du conducteur refusée" "$(echo "$list" | jq -c '.')"
  fi
  # Clé nommée et exigée, jamais un repli : `.orders // []` ferait passer un
  # changement de contrat pour « conducteur libre », soit le mauvais côté de
  # l'erreur — le script enchaînerait et échouerait dix étapes plus loin.
  echo "$list" | jq -e 'has("orders")' >/dev/null \
    || fail "Réponse inattendue : pas de clé « orders »" "$(echo "$list" | jq -c '.')"

  BLOCKING="$(echo "$list" | jq -r \
    '.orders[] | select(.delivery_failure == null) | "\(.uuid)  \(.status)"')"
}

# Refuse de commencer si le conducteur n'est pas libre — ou libère, sur demande
# explicite.
#
# Le refus du serveur ne dit pas QUELLE course bloque, et c'est voulu : un
# conducteur roule pour plusieurs entreprises, nommer la course serait une fuite
# commerciale. Nous ne sommes pas une entreprise, nous sommes l'opérateur : nous
# pouvons le dire, et nous le devons — sinon le script relaie « attendez qu'il
# la termine » sans dire quoi attendre, ce qui n'est pas un diagnostic.
#
# L'annulation tient le rôle de l'opérateur qui le ferait en console ; elle reste
# sous `UNBLOCK=1` parce qu'elle annule des courses réelles.
require_free_driver() {
  local busy count uuid

  read_blocking_orders
  busy="$BLOCKING"
  if [ -z "$busy" ]; then
    pass "Conducteur libre — aucune course en cours"
    return 0
  fi

  count="$(echo "$busy" | wc -l | tr -d ' ')"

  if [ "${UNBLOCK:-0}" != "1" ]; then
    echo "❌ ${DRIVER_LABEL:-$DRIVER_UUID} a déjà $count course(s) en cours."
    echo "   Toute acceptation ou affectation sera refusée (« driver.unavailable »)."
    echo
    echo "$busy" | sed 's/^/   /'
    echo
    echo "   Les terminer ou les annuler depuis la console, ou rejouer avec :"
    echo "     UNBLOCK=1 $0 ${DRIVER_HINT:-}"
    exit 1
  fi

  while read -r uuid _; do
    [ -n "$uuid" ] || continue
    fb_api PATCH /int/v1/orders/cancel "$(jq -n --arg o "$uuid" '{order:$o}')" >/dev/null \
      || fail "Annulation de $uuid impossible : ${FLEETBASE_ERROR:-}"
    echo "   annulée : $uuid"
  done <<<"$busy"

  # Relu, jamais déduit du code HTTP — même discipline que
  # `fb_activate_vendor_by_email` : un `PATCH` qui ne change rien répond 200, et
  # le refus suivant serait alors mis sur le compte du garde.
  read_blocking_orders
  [ -z "$BLOCKING" ] \
    || fail "Le conducteur reste occupé après annulation" "$(echo "$BLOCKING" | tr '\n' ' ')"
  pass "Conducteur libéré — $count course(s) annulée(s)"
}

# Rend le conducteur libre en fin de scénario — le pendant de
# `require_free_driver`, qui l'exige au début.
#
# ── Pourquoi ceci est en bibliothèque, et pas recopié (02/08/2026) ───────────
#
# `test-sorties-de-course` portait ce bloc en clair, et son commentaire disait
# déjà que le défaut avait été rencontré une fois. Il l'avait donc corrigé **chez
# lui seul** — pendant que `test-plafonds-dette`, qui tourne juste avant lui dans
# `run-all-scenarios.sh`, se terminait sur une course **acceptée et jamais
# close**.
#
# Conséquence mesurée : la suite ne passait 7/7 qu'**une fois**. Au passage
# suivant, le septième trouvait le conducteur occupé par le sixième et refusait
# de commencer — un refus parfaitement correct, sur un état que la suite s'était
# fabriqué à elle-même. Un scénario qui se dégrade avec son propre usage n'est
# pas un scénario ; c'est le même défaut que les quatorze « Transports Alpha »
# accumulés, corrigé le 01/08.
#
# ⚠️ **On ne nomme pas les courses à annuler, on relit celles qui bloquent.**
# Une liste écrite à la main vieillit à chaque partie ajoutée au scénario ; la
# relecture, non. C'est déjà ce qui avait rattrapé un trou dans le ménage de
# `test-sorties-de-course`.
release_driver() {
  local uuid n

  read_blocking_orders
  if [ -z "$BLOCKING" ]; then
    pass "Conducteur laissé libre — la suite peut se rejouer"
    return 0
  fi
  n="$(echo "$BLOCKING" | wc -l | tr -d ' ')"

  while read -r uuid _; do
    [ -n "$uuid" ] || continue
    fb_api PATCH /int/v1/orders/cancel "$(jq -n --arg o "$uuid" '{order:$o}')" >/dev/null \
      && echo "   annulée : $uuid" \
      || echo "   ⚠️  $uuid non annulée — la libérer avec UNBLOCK=1 au prochain passage"
  done <<<"$BLOCKING"

  # Relu, jamais déduit des annulations : un `PATCH` qui ne change rien répond
  # 200, et le scénario suivant mettrait le refus sur le compte de son propre
  # garde. C'est ce contrôle qui a révélé le trou précédent.
  read_blocking_orders
  [ -z "$BLOCKING" ] \
    || fail "Le conducteur reste bloqué après le ménage" "$(echo "$BLOCKING" | tr '\n' ' ')"
  pass "Conducteur laissé libre — $n course(s) close(s), la suite peut se rejouer"
}
