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
  test-parcours-argent
  test-parcours-argent-flotte
  test-multi-appartenance
  test-regularisation-commercant
  test-ecart-et-dette-negative
  test-plafonds-dette
  test-sorties-de-course
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
