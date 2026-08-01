#!/usr/bin/env bash
#
# Désigne le prestataire « plateforme » — le facilitateur des courses du pool.
#
# ── Pourquoi un script et pas une route ───────────────────────────────────
#
# `FleetAccount.isPlatform` n'a **aucune route**, et c'est délibéré (schéma
# Prisma) : un compte flotte qui pourrait se déclarer plateforme ferait retenir
# à ses conducteurs une rémunération qui ne leur revient pas, et se mettrait à
# recevoir l'argent de toutes les courses du pool. C'est un geste d'admin, au
# même titre que l'activation d'un fournisseur.
#
# ── Ce que ça change, et il faut le savoir avant de le lancer ────────────
#
# Sans prestataire plateforme, une course du pool se règle **conducteur ↔
# commerçant** — c'est le comportement de tout le code écrit jusqu'au
# 01/08/2026 et de toutes les lignes déjà en base.
#
# Avec, la chaîne passe à trois maillons :
#
#     conducteur ──▶ Echango ──▶ commerçant
#
# Le conducteur retient sa course (Echango est marqué plateforme, donc sa
# rémunération lui revient), doit le reste à Echango, et **c'est Echango qui
# doit au commerçant**. La commission devient recouvrable par compensation sur
# une remise qui existe enfin.
#
# ⚠️ **Les lignes déjà écrites ne bougent pas**, et c'est voulu : elles portent
# `facilitatorId = null` et restent des dettes conducteur ↔ commerçant. Une
# migration qui les réattribuerait changerait des dettes constatées, ce qu'aucun
# registre ne doit faire. Les deux formes coexistent donc le temps que les
# anciennes se soldent.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/provision-platform.sh <email-du-compte-flotte>   # désigner
#   ./scripts/provision-platform.sh --status                   # qui est-ce ?
#   ./scripts/provision-platform.sh --clear                    # retirer
#
# Le compte doit exister et être une **entreprise inscrite** (persona `fleet`) :
# c'est lui qui se connectera pour confirmer les remises reçues des conducteurs
# et déclarer celles faites aux commerçants.

set -euo pipefail

PGC="${PGC:-echango_bff_postgres}"
PGUSER="${PGUSER:-bff_user}"
PGDB="${PGDB:-echango_bff}"

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker requis"

psql_q() { docker exec "$PGC" psql -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null; }

current() { psql_q 'SELECT id || E'"'"'\t'"'"' || email FROM "FleetAccount" WHERE "isPlatform" = true;'; }

case "${1:-}" in
  --status)
    who="$(current)"
    if [ -z "$who" ]; then
      echo "Aucun prestataire plateforme — les courses du pool se règlent conducteur ↔ commerçant."
    else
      echo "Prestataire plateforme :"
      echo "$who" | sed 's/^/   /'
      # Plusieurs lignes = ambiguïté ; le BFF refuse dans ce cas, autant le dire ici.
      [ "$(echo "$who" | wc -l)" -le 1 ] \
        || echo "   ⚠️  PLUSIEURS — le BFF refusera toute clôture encaissée (cash.platform_ambiguous)"
    fi
    exit 0 ;;

  --clear)
    psql_q 'UPDATE "FleetAccount" SET "isPlatform" = false WHERE "isPlatform" = true;' >/dev/null \
      || fail "écriture impossible (conteneur $PGC joignable ?)"
    pass "Prestataire plateforme retiré — retour au règlement conducteur ↔ commerçant"
    exit 0 ;;

  "" | -h | --help)
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

EMAIL="$1"

# ⚠️ **Refus si un autre est déjà désigné.** `findFirst` côté BFF en prendrait un
# au hasard — donc l'argent d'une course irait à l'un ou à l'autre selon l'ordre
# d'insertion. Le BFF refuse d'ailleurs explicitement ce cas ; le script ne doit
# pas le créer.
existing="$(current)"
if [ -n "$existing" ]; then
  if echo "$existing" | grep -q "	$EMAIL$"; then
    pass "$EMAIL est déjà le prestataire plateforme — rien à faire"
    exit 0
  fi
  echo "❌ Un autre prestataire plateforme est déjà désigné :"
  echo "$existing" | sed 's/^/   /'
  echo "   Le retirer d'abord :  $0 --clear"
  exit 1
fi

found="$(psql_q "SELECT id FROM \"FleetAccount\" WHERE email = '$EMAIL';")"
[ -n "$found" ] || fail "Aucun compte flotte avec l'email $EMAIL — l'inscrire d'abord (/auth/flotte/register)"

psql_q "UPDATE \"FleetAccount\" SET \"isPlatform\" = true WHERE email = '$EMAIL';" >/dev/null \
  || fail "écriture impossible (conteneur $PGC joignable ?)"

# Relu, jamais déduit du code de sortie : un `UPDATE` qui ne matche rien réussit.
check="$(current)"
echo "$check" | grep -q "	$EMAIL$" \
  || fail "La désignation n'a pas pris — relu : ${check:-aucun}"

pass "$EMAIL est désormais le prestataire plateforme"
echo "   Les courses du pool se règlent maintenant : conducteur → Echango → commerçant."
echo "   ⚠️ Ce compte doit se connecter pour confirmer les remises des conducteurs,"
echo "      sans quoi leurs dettes ne s'éteindront jamais."
