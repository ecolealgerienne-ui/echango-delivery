#!/usr/bin/env bash
#
# Coupe l'accès d'un compte — **immédiatement**, sessions en cours comprises.
#
# ── Le trou que ce script bouche (revue du 01/08/2026, S1) ─────────────────
#
# Avant lui, il n'existait AUCUN moyen de couper un accès.
#
# `assertVendorApproved()` — le garde né du Lot 4 — n'est appelée qu'à la
# **connexion** (`loginMerchant`, `loginFleet`). Le garde par requête, lui, ne
# teste que `account.active`, et **rien dans tout `src/` n'écrit jamais ce
# champ**. Conséquence : un admin qui suspend un fournisseur depuis la console
# fait un geste qui réussit, affiche un statut vert, et **n'a aucun effet
# pendant 24 h** — la durée de vie du jeton. Pour un conducteur, `Vendor.status`
# ne s'applique même pas : aucune interface ne pouvait l'arrêter.
#
# `POST /auth/revoquer-sessions` existait, mais exige le jeton de la victime :
# elle sert à quelqu'un qui veut déconnecter ses propres appareils, pas à un
# opérateur qui doit couper un compte compromis.
#
# ── Pourquoi les deux gestes, et pas un seul ──────────────────────────────
#
# `active = false` ferme les requêtes futures ; `tokenVersion + 1` invalide les
# jetons déjà émis. Le garde teste les deux à chaque requête, donc l'un suffirait
# — mais ils ne disent pas la même chose et ne se défont pas ensemble :
# réactiver un compte remet `active` à vrai **sans** rendre leur validité aux
# jetons volés, ce qui est exactement ce qu'on veut.
#
# ── Ce que ce script ne fait pas ──────────────────────────────────────────
#
# Il ne touche **pas** à Fleetbase. Le statut du `Vendor` reste ce qu'il est, et
# c'est lui qui gouverne la prochaine connexion (Lot 4). Suspendre pour de bon
# demande donc les deux : la console pour la connexion, ce script pour la
# session en cours. Le dire plutôt que de laisser croire qu'un seul suffit —
# c'est précisément la confusion qui a laissé ce trou ouvert.
#
# Usage :
#   scripts/suspend-account.sh <email>            # coupe
#   scripts/suspend-account.sh <email> --restore  # rétablit (jetons toujours morts)
#   scripts/suspend-account.sh --list             # les comptes actuellement coupés

set -euo pipefail

PGC="${PGC:-echango_bff_postgres}"
PGUSER_="${PGUSER:-bff_user}"
PGDB_="${PGDB:-echango_bff}"

psql_() { docker exec "$PGC" psql -U "$PGUSER_" -d "$PGDB_" -tAc "$1"; }

# Les trois personas vivent dans trois tables, et c'est le point : un opérateur
# ne sait pas — et n'a pas à savoir — dans laquelle un email a été enregistré.
# Chercher dans une seule aurait rendu « compte introuvable » sur un compte qui
# existe, ce qui est la pire réponse possible à qui essaie de couper un accès.
TABLES=(MerchantAccount DriverAccount FleetAccount)

if [ "${1:-}" = "--list" ]; then
  echo "Comptes actuellement coupés :"
  found=0
  for t in "${TABLES[@]}"; do
    rows="$(psql_ "SELECT '$t' || E'\t' || email || E'\t' || \"tokenVersion\" FROM \"$t\" WHERE active = false;")"
    if [ -n "$rows" ]; then echo "$rows"; found=1; fi
  done
  [ "$found" = 1 ] || echo "  (aucun)"
  exit 0
fi

EMAIL="${1:-}"
MODE="${2:-suspend}"

if [ -z "$EMAIL" ]; then
  echo "Usage : $0 <email> [--restore]   |   $0 --list" >&2
  exit 1
fi

# Localisé AVANT d'écrire, et dans les trois tables : écrire à l'aveugle avec un
# `UPDATE ... WHERE email = ...` sur chacune rendrait « 0 ligne » indiscernable
# de « compte inexistant », et un opérateur croirait avoir coupé un accès resté
# ouvert. Sur une action de sécurité, c'est le seul défaut qui compte.
TABLE=""
for t in "${TABLES[@]}"; do
  if [ "$(psql_ "SELECT count(*) FROM \"$t\" WHERE email = '$EMAIL';")" != "0" ]; then
    [ -z "$TABLE" ] || { echo "❌ « $EMAIL » existe dans $TABLE ET $t — refus de choisir" >&2; exit 1; }
    TABLE="$t"
  fi
done

if [ -z "$TABLE" ]; then
  echo "❌ Aucun compte « $EMAIL » dans $(IFS=', '; echo "${TABLES[*]}")" >&2
  exit 1
fi

if [ "$MODE" = "--restore" ]; then
  psql_ "UPDATE \"$TABLE\" SET active = true WHERE email = '$EMAIL';" >/dev/null
  echo "✅ $TABLE « $EMAIL » rétabli."
  echo "   ⚠️ Les jetons émis avant la coupure restent invalides — c'est voulu."
else
  psql_ "UPDATE \"$TABLE\" SET active = false, \"tokenVersion\" = \"tokenVersion\" + 1 WHERE email = '$EMAIL';" >/dev/null
  echo "✅ $TABLE « $EMAIL » coupé — sessions en cours comprises."
  echo "   ⚠️ Fleetbase n'est PAS touché : pour bloquer aussi la prochaine"
  echo "      connexion, passer le fournisseur en « inactive » dans"
  echo "      Fleet-Ops → Fournisseurs (et non dans IAM → Customers, que le BFF ignore)."
fi

# Relu, jamais déduit du code de retour : un `UPDATE` qui ne matche rien répond
# « UPDATE 0 » sans erreur, et `set -e` ne s'en aperçoit pas. C'est la même
# discipline que `fb_activate_vendor_by_email`, pour la même raison.
STATE="$(psql_ "SELECT active || '/' || \"tokenVersion\" FROM \"$TABLE\" WHERE email = '$EMAIL';")"
echo "   État relu : active/tokenVersion = $STATE"
