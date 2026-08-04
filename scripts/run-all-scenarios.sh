#!/usr/bin/env bash
#
# Rejoue TOUS les scénarios métier, et dit lesquels passent.
#
# ── Pourquoi ce lanceur ───────────────────────────────────────────────────
#
# Les scénarios se sont accumulés un par un, et personne ne les rejoue tous :
# chacun est lancé le jour où il est écrit, puis oublié. Or ils partagent des
# bibliothèques (`lib/`), une base de données et une instance Fleetbase — un lot
# qui casse l'un casse souvent les autres, et on ne le voit qu'au prochain
# passage manuel.
#
# ⚠️ **Il s'arrête à `set +e`, délibérément.** Un `set -e` global sortirait au
# premier échec, donc on ne saurait jamais si les suivants passent — et c'est
# précisément l'information qu'on cherche quand on rejoue une suite. Chaque
# scénario est isolé, son code de sortie relevé, et le tableau final dit tout.
#
# ── Ce qu'il ne fait pas ─────────────────────────────────────────────────
#
# Il ne relance pas `flutter analyze`, `jest` ni les vérificateurs Dart : ce sont
# des contrôles statiques qui ne demandent ni Fleetbase ni le BFF, et les mêler
# ici allongerait la boucle sans rien apprendre sur les scénarios.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/run-all-scenarios.sh [conducteur]
#
#   UNBLOCK=1     libère le conducteur entre les scénarios (recommandé : chacun
#                 laisse une course en cours s'il échoue en route)
#   ONLY=motif    ne joue que les scénarios dont le nom contient `motif`
#   PACE=65       secondes de pause entre deux scénarios (0 pour enchaîner)
#
# ⚠️ **Le throttle d'inscription est la limite réelle.** Le BFF plafonne les
# inscriptions à 10 par heure ; la suite complète en consomme environ huit. Deux
# passages coup sur coup échoueront donc sur un `HTTP 429` qui n'a rien à voir
# avec le code — le tableau final le nomme explicitement plutôt que de le
# compter comme un échec métier.

set -uo pipefail   # PAS de `-e` : voir l'en-tête.

DRIVER_HINT="${1:-}"
ONLY="${ONLY:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOGDIR="${LOGDIR:-/tmp/echango-scenarios}"
mkdir -p "$LOGDIR"

# L'ordre n'est pas indifférent : les deux parcours d'argent d'abord, parce
# qu'ils sont les contrôles de non-régression du registre — si le socle est
# cassé, tout le reste échouera pour la même raison et le tableau serait illisible.
SCENARIOS=(
  # Tout en tête : il n'écrit rien. Il n'appelle que des routes qui doivent
  # **refuser**, avec des identifiants inexistants — donc il ne peut pas salir
  # le décor des suivants, et un échec ici se lit sans avoir à démêler ce que
  # les autres ont laissé.
  #
  # ⚠️ Il consomme du débit : ~260 appels cadencés, deux à trois minutes. C'est
  # le prix de 87 protections constatées plutôt que supposées.
  test-frontiere-http
  # Juste après : il pose la question suivante — « ce jeton est valide, mais
  # cette commande est-elle à lui ? ». Il n'écrit rien non plus : ses sondes
  # portent sur les ressources d'un AUTRE compte, donc elles doivent toutes
  # échouer. Le second compte de chaque persona est provisionné une seule fois.
  test-appartenance
  # Placé en tête : il ne touche ni au conducteur ni au registre, donc il ne
  # dépend d'aucun des autres et n'en dérange aucun. Son email est stable, il
  # ne consomme donc une inscription qu'à sa toute première exécution.
  test-wilaya
  test-multi-appartenance
  # Le filtre wilaya CÔTÉ CONDUCTEUR : une course hors-wilaya lui est cachée,
  # la bonne visible — dans les deux sens. test-wilaya prouve la persistance ;
  # celui-ci prouve le filtre, conducteur connecté.
  test-filtre-wilaya
  test-sorties-de-course
  # Le ciblage d'un favori nommé : ciblé = invisible aux autres, redirection
  # réversible. Deux transporteurs, témoin positif à chaque pas (règle 8).
  test-visibilite-ciblage
  # Ciblage d'un favori ENTREPRISE (facilitator) : la branche fleet, jamais jouée
  # e2e (classe du (f:any)). facilitator posé, l'entreprise voit / le pool non,
  # elle affecte son conducteur. Quatre témoins.
  test-ciblage-entreprise
  # Refus d'un favori sollicité : la course repart au pool (adhoc=true, sans
  # conducteur) et le commerçant reçoit order.released. La vraie remplaçante de
  # l'ancien repli pickAvailableFavourite, jamais éprouvée.
  test-refus-favori-pool
  # Compensation de publication : dispatch échoué (étape 2) → l'étape 1 est
  # RÉTRACTÉE (adhoc=false), la course reste republiable et ne circule pas.
  # Échec injecté de façon déterministe (dispatched=true, statut created).
  test-compensation-publication
  # Le filtre véhicule isolé : on bascule le véhicule du conducteur, tout le
  # reste fixe. moto ne voit pas « utilitaire », utilitaire oui, voiture non.
  test-filtre-vehicule
  # La thèse produit : un conducteur sert deux commerçants. Prouvé par l'accès
  # et l'acceptation, pas par la liste géospatiale (voir l'en-tête du script).
  test-pool-mutualise
  # ⚠️ Concurrence : deux acceptations SIMULTANÉES, un seul gagnant. Probabiliste
  # (plusieurs tours) — un banc de course qui « passe » une fois ne prouve rien.
  test-concurrence-acceptation
  # Les fenêtres de PERTE D'ÉCRITURE : N acteurs, une liste, en parallèle ⇒ N
  # survivants. Garde le verrou par ressource (favoris, declines) — avant lui,
  # 2/6 et 1/2. Sérialisation en-processus déterministe, donc N/N assertable.
  test-concurrence-fenetres
  # Les bords de l'argent à la porte : les trois refus du tiroir, puis la
  # livrée muette qui remonte comme « à déclarer ». Contrôle qui dit non (règle 8).
  test-bords-argent
  # L'encaissement d'une livraison CLOSE est immuable : une seconde clôture à 0
  # ne réécrit pas le montant déjà déclaré (order.already_terminal). A trouvé un
  # vrai défaut — un 2000 réécrit à 0 en HTTP 2xx, silencieusement.
  test-double-cloture
  # La tarification que le CONDUCTEUR voit, en VALEUR : price relayé, cod_amount
  # = marchandise + course (ou marchandise seule si comprise), refus sans prix.
  # test-frontiere-projection ne vérifie que la présence, jamais la valeur.
  test-tarification-conducteur
  # Durabilité : la console écrase meta (assignation) → prix et montant à
  # encaisser SURVIVENT (champs personnalisés). Le bug fondateur du 30/07, e2e.
  test-durabilite-meta
  # La preuve de livraison : le propriétaire atteint le relais, l'intrus est
  # bloqué à l'ACCÈS (order.not_found), jamais à l'étape stockage. Couvre les
  # deux dernières routes à identifiant de la règle 12.
  test-preuve-livraison
  # Cycle de vie de l'appartenance : le départ coupe les courses À VENIR
  # (driver.forbidden), jamais celle déjà confiée ; réadhérer rouvre l'accès.
  test-cycle-appartenance
  # ⚠️ **En DERNIER des bancs qui n'écrivent rien** : il a besoin
  # d'un décor RICHE — une course portant des champs personnalisés. Les courses
  # d'avant le 03/08/2026 n'en ont aucun, et il refuse alors de conclure plutôt
  # que d'annoncer « aucune fuite » sur une commande qui n'avait rien à cacher.
  # Le placer après les autres lui donne les courses qu'ils viennent de créer.
  test-frontiere-projection
  # ⚠️ Lent (~1-2 min) : il ATTEND un passage du réconciliateur (60 s par défaut).
  # Une prise en charge faite HORS du BFF (chez Fleetbase) remonte au commerçant
  # en order.assigned — toute la chaîne de notification, sinon sans couverture.
  test-reconciliateur-notif
  # ⚠️ **Vraiment en dernier, et pour une raison qui lui est propre** : il
  # ARRÊTE puis RALLUME le conteneur httpd de Fleetbase pour éprouver le mode
  # dégradé. Un `trap` rallume quoi qu'il arrive, mais tant qu'il tourne les
  # autres scénarios échoueraient — d'où sa place tout à la fin, quand plus
  # personne n'a besoin de Fleetbase.
  test-resilience-degradee
)

names=(); codes=(); notes=()

for s in "${SCENARIOS[@]}"; do
  [ -z "$ONLY" ] || case "$s" in *"$ONLY"*) ;; *) continue ;; esac
  if [ ! -x "$HERE/$s.sh" ] && [ ! -f "$HERE/$s.sh" ]; then
    names+=("$s"); codes+=(-1); notes+=("absent"); continue
  fi

  # ⚠️ **Temporisation entre scénarios, activée par défaut.**
  #
  # La connexion est plafonnée à cinq par minute. Enchaînés sans pause, les
  # scénarios se refusent mutuellement l'accès — et le refus arrivait jusqu'ici
  # déguisé en « le mot de passe ne correspond pas », qui envoyait supprimer des
  # lignes en base pour un problème qui se résout en attendant.
  #
  # Elle ne règle PAS le plafond horaire d'INSCRIPTION (10/h) : la suite en
  # consomme sept, donc elle passe dans une heure fraîche et échoue sur un
  # second passage. Le tableau final le nomme plutôt que de le laisser chercher.
  if [ "${#names[@]}" -gt 0 ] && [ "${PACE:-65}" -gt 0 ]; then
    echo "   (pause ${PACE:-65}s — plafond de connexion)"
    sleep "${PACE:-65}"
  fi

  printf '\n════ %s ════\n' "$s"
  bash "$HERE/$s.sh" "$DRIVER_HINT" >"$LOGDIR/$s.log" 2>&1
  code=$?

  # Le throttle d'inscription n'est pas un échec métier : le nommer évite de
  # chercher un bug dans le registre pendant une heure.
  note=""
  if [ "$code" -ne 0 ] && grep -q 'ThrottlerException\|HTTP 429' "$LOGDIR/$s.log" 2>/dev/null; then
    note="throttle d'inscription (429) — rejouer dans une heure"
  fi

  names+=("$s"); codes+=("$code"); notes+=("$note")
  if [ "$code" -eq 0 ]; then
    echo "✅ $s"
  else
    echo "❌ $s (code $code)${note:+ — $note}"
    tail -6 "$LOGDIR/$s.log" | sed 's/^/   /'
  fi
done

echo
echo "════════════════════════════════════════════════════════════════"
ok=0; ko=0; skipped=0
for i in "${!names[@]}"; do
  case "${codes[$i]}" in
    0)  printf '  ✅ %-34s\n' "${names[$i]}"; ok=$((ok+1)) ;;
    -1) printf '  ·  %-34s script absent\n' "${names[$i]}"; skipped=$((skipped+1)) ;;
    *)  printf '  ❌ %-34s code %s %s\n' "${names[$i]}" "${codes[$i]}" "${notes[$i]}"; ko=$((ko+1)) ;;
  esac
done
echo "════════════════════════════════════════════════════════════════"
echo "  $ok passés, $ko échoués, $skipped absents — journaux dans $LOGDIR"

[ "$ko" -eq 0 ]
