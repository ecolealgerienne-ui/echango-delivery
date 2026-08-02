#!/usr/bin/env bash
#
# Solde le registre d'un conducteur de test — **développement uniquement**.
#
# ── Pourquoi ce script existe ─────────────────────────────────────────────
#
# Les scénarios réutilisent le même conducteur et créent un commerçant neuf à
# chaque exécution. Sa dette envers chacun n'est donc jamais remise, et son
# **encours total** grimpe d'environ 1300 par livraison. Au bout d'une quinzaine
# de passages, `COD_DEBT_CEILING_PER_PERSON` (20000 par défaut) est atteint et
# toute course encaissée lui est refusée :
#
#     cash.ceiling_exceeded — « Ce conducteur détient déjà trop d'espèces »
#
# ⚠️ **Ce n'est pas un défaut, c'est le garde-fou qui fonctionne.** Le réflexe
# serait de desserrer le plafond pour « faire passer les tests » — c'est-à-dire
# désactiver la seule chose qui borne notre exposition, pour une raison qui n'a
# rien à voir avec le produit. Ce qu'il faut nettoyer, c'est la donnée de test.
#
# ── Ce qu'il supprime, et ce qu'il ne touche pas ─────────────────────────
#
# Les `CashCollection`, `CashRemittance` et `DriverEarning` du conducteur visé.
# Rien d'autre : ni les commandes, ni les comptes, ni les adhésions.
#
# ⚠️ **Il SUPPRIME des écritures comptables.** C'est acceptable — et seulement —
# sur une base de développement dont toutes les lignes viennent de scripts. Sur
# une base réelle ce serait une falsification : une dette constatée ne
# s'efface pas, elle se solde par une remise confirmée. D'où le garde-fou
# ci-dessous, qui refuse de tourner sans aveu explicite.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/reset-test-ledger.sh <email-ou-uuid>     # montre ce qu'il ferait
#   I_KNOW_THIS_IS_DEV=1 ./scripts/reset-test-ledger.sh <email-ou-uuid>

set -euo pipefail

PGC="${PGC:-echango_bff_postgres}"
PGUSER="${PGUSER:-bff_user}"
PGDB="${PGDB:-echango_bff}"
TARGET="${1:-}"

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; exit 1; }

command -v docker >/dev/null 2>&1 || fail "docker requis"
[ -n "$TARGET" ] || fail "Usage : $0 <email-du-compte-conducteur | uuid-fleetbase>"

q() { docker exec "$PGC" psql -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null; }

# Le compte est cherché sur les deux identifiants : l'email est ce qu'on a sous
# la main après un run, l'uuid ce que la console affiche.
# ⚠️ **Trois identifiants, et surtout un listing quand aucun ne matche.**
#
# Le script n'acceptait qu'un email ou un uuid, alors que tous les autres
# prennent le nom (`resolve_driver`) : le geste naturel après un run,
# `reset-test-ledger.sh Toto`, échouait sur « Aucun compte conducteur » **sans
# dire quoi utiliser à la place**. Motif déjà corrigé deux fois ici.
#
# ⚠️ **Et le nom ne suffira souvent pas**, ce qui est la vraie leçon de ce
# script : « Toto » est le nom du `Driver` **chez Fleetbase**, tandis que le
# compte Echango porte ses propres `firstName`/`lastName` — « Test
# Transporteur » sur nos jeux d'essai. Les deux ne coïncident pas, et rien ne
# les oblige à coïncider. Le filtre par nom est donc un confort ; c'est le
# **listing** qui fait le travail, en montrant les emails réellement
# utilisables. Une correspondance qui échoue en disant ce qui existe vaut mieux
# qu'une correspondance qui échoue en accusant une absence.
DRIVER_ID="$(q "SELECT id FROM \"DriverAccount\"
                 WHERE email = '$TARGET'
                    OR \"fleetbaseDriverUuid\" = '$TARGET'
                    OR lower(coalesce(\"firstName\",'') || ' ' || coalesce(\"lastName\",''))
                       LIKE lower('%$TARGET%')
                 LIMIT 1;")"

if [ -z "$DRIVER_ID" ]; then
  echo "❌ Aucun compte conducteur pour « $TARGET »."
  echo "   Comptes existants :"
  q "SELECT '     ' || email || '   ' || coalesce(\"firstName\",'') || ' ' || coalesce(\"lastName\",'')
       FROM \"DriverAccount\" ORDER BY \"createdAt\" DESC LIMIT 20;"
  exit 1
fi

EMAIL="$(q "SELECT email FROM \"DriverAccount\" WHERE id = '$DRIVER_ID';")"

collections="$(q "SELECT count(*) FROM \"CashCollection\" WHERE \"driverId\" = '$DRIVER_ID';")"
remittances="$(q "SELECT count(*) FROM \"CashRemittance\" WHERE \"driverId\" = '$DRIVER_ID';")"
earnings="$(q "SELECT count(*) FROM \"DriverEarning\" WHERE \"earnerType\" = 'driver' AND \"earnerId\" = '$DRIVER_ID';")"
held="$(q "SELECT coalesce(sum(\"collectedAmount\"), 0) FROM \"CashCollection\" WHERE \"driverId\" = '$DRIVER_ID';")"

echo "Conducteur : $EMAIL ($DRIVER_ID)"
echo "  encaissements : $collections   (total perçu $held)"
echo "  remises       : $remittances"
echo "  rémunérations : $earnings"

if [ "${I_KNOW_THIS_IS_DEV:-0}" != "1" ]; then
  echo
  echo "Rien n'a été supprimé. Pour le faire :"
  echo "   I_KNOW_THIS_IS_DEV=1 $0 $TARGET"
  echo
  echo "⚠️ Sur une base réelle, ne pas exécuter : une dette constatée se solde"
  echo "   par une remise confirmée, elle ne s'efface pas."
  exit 0
fi

# L'ordre suit les dépendances : rien ne référence ces trois tables entre elles,
# mais les supprimer dans l'ordre inverse de l'écriture reste plus lisible pour
# qui relit le script.
q "DELETE FROM \"CashRemittance\" WHERE \"driverId\" = '$DRIVER_ID';" >/dev/null
q "DELETE FROM \"DriverEarning\" WHERE \"earnerType\" = 'driver' AND \"earnerId\" = '$DRIVER_ID';" >/dev/null
q "DELETE FROM \"CashCollection\" WHERE \"driverId\" = '$DRIVER_ID';" >/dev/null

# Relu, jamais déduit du code de sortie : un DELETE qui ne matche rien réussit.
after="$(q "SELECT count(*) FROM \"CashCollection\" WHERE \"driverId\" = '$DRIVER_ID';")"
[ "$after" = "0" ] || fail "Il reste $after encaissement(s) après suppression"

pass "Registre de $EMAIL remis à zéro — $collections encaissement(s), $remittances remise(s), $earnings rémunération(s)"
echo "   Son encours total repart de 0 : les scénarios encaissés repassent."
