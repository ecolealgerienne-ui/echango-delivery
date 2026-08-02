#!/usr/bin/env bash
#
# Banc d'appartenance (règle 12) : un jeton valide ne donne pas droit à la
# ressource d'un autre.
#
# Le banc de refus prouve **qui** vous êtes ; celui-ci prouve que la commande
# que vous nommez est bien la vôtre. Cette seconde vérification ne vit dans
# aucun garde — elle est répartie dans quatre-vingt-dix services et repose sur
# le fait que chaque auteur y a pensé.
#
# ⚠️ **Chaque épreuve porte son témoin** : A doit d'abord obtenir SA ressource
# (2xx), sinon un « introuvable » chez B ne prouve rien — un identifiant du
# mauvais type rend 404 partout. Sans témoin, le persona est déclaré NON
# COUVERT, jamais réussi.
#
#   ./scripts/test-appartenance.sh
#   python3 scripts/lib/appartenance.py --self-test   # 12 cas, dont 5 refus
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "❌ python3 absent — pas de banc, donc pas de verdict."
  exit 2
}

echo "── auto-test du banc ──"
python3 "$HERE/lib/appartenance.py" --self-test || {
  echo "❌ l'auto-test échoue : c'est le banc qui est en cause."
  exit 2
}

# ── Le second compte de chaque persona ───────────────────────────────────────
#
# Un compte fraîchement inscrit est **en attente de validation** : le BFF le
# dit explicitement (`merchant_pending`, `fleet_pending`) et refuse la
# connexion. Sans validation, le banc n'a pas de « B » et se déclare non
# couvert — un verdict qui accuse l'appartenance pour un problème de décor.
#
# ⚠️ **L'activation passe par l'outil existant, jamais par une copie.** C'est
# `fb_activate_vendor_by_email` qui sait le faire, elle est déjà éprouvée par
# le provisionnement des parcours, et la recopier ici créerait deux façons de
# valider un compte — donc deux occasions de diverger (règle 5).
. "$HERE/lib/fleetbase.sh"

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"

provision_b() { # route email nom_commercial
  local route="$1" email="$2" nom="$3" status
  # Connexion d'abord : une réinscription à chaque passage consommerait le
  # plafond horaire (10/h) que la suite des scénarios remplit déjà presque.
  if curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
       -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\"}" \
     | grep -q '"token"'; then
    echo "   compte B déjà actif — $email"
    return 0
  fi
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BFF_URL$route" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$PASSWORD\",\"businessName\":\"$nom\"}")"
  echo "   inscription B ($email) : HTTP $status"
  # 403 = « en attente de validation », 409 = déjà inscrit. Les deux mènent à
  # l'activation ; un 200 signalerait qu'un accès est délivré sans validation.
  case "$status" in
    200|201) echo "   ⚠️ accès délivré SANS validation — à signaler (garde du Lot 4)" ;;
  esac
  fb_activate_vendor_by_email "$email" \
    && echo "   compte B validé — $email" \
    || echo "   ⚠️ activation impossible : ${FLEETBASE_ERROR:-raison inconnue}"
}

echo
echo "── second compte de chaque persona ──"
provision_b /auth/merchant/register \
  "${MERCHANT_B_EMAIL:-appartenance-commercant-b@echango.local}" "Témoin appartenance"
provision_b /auth/flotte/register \
  "${FLEET_B_EMAIL:-appartenance-entreprise-b@echango.local}" "Flotte témoin"

echo
echo "── banc d'appartenance ──"
exec python3 "$HERE/lib/appartenance.py"
