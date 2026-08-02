#!/usr/bin/env bash
# Pose le décor d'un parcours joué **dans l'application**, puis rend les
# identifiants à passer à `flutter drive`.
#
#   ./scripts/provision-app-parcours.sh
#   EMAIL=x@y.z ./scripts/provision-app-parcours.sh    # reprend un commerçant
#
# ── Pourquoi un script à part, et pourquoi en shell ─────────────────────────
#
# Le test d'intégration Flutter pilote l'application ; il ne peut donc faire que
# ce qu'un commerçant peut faire à l'écran. Or deux choses lui manquent avant de
# pouvoir commencer, et **aucune des deux n'est un geste de commerçant** :
#
#   1. **L'activation du compte.** Depuis le Lot 4, une inscription enregistre
#      une *demande* : `merchant_pending`, aucun jeton, aucune connexion tant
#      qu'un administrateur n'a pas passé le `Vendor` à `active`. Le garde est
#      volontaire et reste entier — c'est le rôle d'admin qui est tenu ici, pas
#      le garde qui est contourné. (Même parti pris que `test-parcours-argent.sh`.)
#
#   2. **Deux adresses au carnet.** Le formulaire de course exige quatre
#      coordonnées, désignées soit par la carte, soit par le carnet. Piloter une
#      carte glissante depuis un test est fragile et ne prouve rien du métier ;
#      choisir deux entrées d'un carnet est déterministe. Le carnet d'un
#      commerçant neuf est vide, donc on le remplit ici.
#
# Ce script ne teste rien : il **provisionne**. Ce qui est vérifié l'est par
# `integration_test/parcours_commercant_test.dart`, dans l'application.
#
# ⚠️ Il consomme **une inscription sur les 10/h** du throttle, comme la suite
# `run-all-scenarios.sh`. Les deux à la suite passent mal ; réutiliser un
# commerçant déjà provisionné (`EMAIL=…`) ne consomme rien.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/fleetbase.sh"

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
SUFFIX="${SUFFIX:-$RANDOM}"
EMAIL="${EMAIL:-app-parcours-$SUFFIX@echango.local}"
BUSINESS="${BUSINESS:-Boulangerie Parcours $SUFFIX}"

command -v jq >/dev/null 2>&1 || { echo "❌ jq requis." >&2; exit 1; }

pass() { echo "✅ $1"; }
info() { echo "   $1"; }
step() { echo; echo "── $1 ──"; }
fail() { echo "❌ $1" >&2; [ -n "${2:-}" ] && echo "   Réponse : $2" >&2; exit 1; }

# Reconnaît une erreur du BFF sur stdin.
#
# Par `statusCode`, jamais par `code` : `code` existe aussi sur des réponses de
# succès (un objet activité en porte un), donc le tester lirait un succès comme
# un échec. `statusCode` est le seul champ que le filtre d'exception pose sur
# **toutes** les erreurs, y compris celles sans code métier.
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

# ── 1. Le compte ────────────────────────────────────────────────────────────

step "Commerçant"

register_body="$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" --arg b "$BUSINESS" \
  '{email:$e, password:$p, businessName:$b, phone:"0550000000"}')"

# ⚠️ La route est `/auth/merchant/register`, **pas** `/auth/register/merchant`.
# Écrite à l'envers ici le 02/08/2026 : le 404 qui en est sorti n'a pas de champ
# `code`, et la première version de ce script ne regardait que `code` — elle a
# donc annoncé « ✅ Inscription enregistrée » sur une route inexistante, et n'a
# échoué que trois étapes plus loin, en accusant l'activation. D'où la lecture
# du **code HTTP** ci-dessous, qui ne peut pas manquer.
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' -d "$register_body")"
reg_status="$(tail -n1 <<<"$reg")"
reg_body="$(sed '$d' <<<"$reg")"
reg_code="$(jq -r '.code // empty' <<<"$reg_body" 2>/dev/null || true)"

# **Le refus EST le résultat attendu.** Une inscription commerçant répond 403
# `merchant_pending` : demande enregistrée, accès fermé. Mesuré, pas supposé —
# et un 2xx ici signifierait que le garde du Lot 4 a sauté, ce qui est un défaut
# bien plus grave que l'échec du provisionnement.
if [ "$reg_status" = "403" ] && [ "$reg_code" = "merchant_pending" ]; then
  pass "Demande enregistrée, accès en attente — $EMAIL"
elif [ "$reg_status" = "200" ] || [ "$reg_status" = "201" ]; then
  fail "L'inscription a délivré un accès sans validation — le garde du Lot 4 ne tient plus" "$reg_body"
else
  fail "Inscription refusée pour une raison inattendue (HTTP $reg_status)" "$reg_body"
fi

step "Activation (rôle admin, tenu par le script)"
fb_activate_vendor_by_email "$EMAIL" \
  || fail "Activation impossible : ${FLEETBASE_ERROR:-raison inconnue}"
pass "Vendor passé à « active »"

# ── 2. La session, pour poser le carnet ─────────────────────────────────────

step "Connexion"
login="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')")"
# ⚠️ Le champ s'appelle `token`. Ni `accessToken`, ni `access_token` — les deux
# ont été essayés d'abord, et un jeton vide se serait manifesté trois requêtes
# plus loin par un 401 sur le carnet d'adresses.
TOKEN="$(jq -r '.token // empty' <<<"$login")"
[ -n "$TOKEN" ] || fail "Aucun jeton délivré" "$login"
pass "Jeton obtenu"

mapi() { # méthode chemin [corps]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $TOKEN"
  fi
}

# ── 3. Le carnet ────────────────────────────────────────────────────────────
#
# Deux adresses **réelles et distantes de quelques kilomètres** : un enlèvement
# et une livraison au même point passeraient la validation tout en ne prouvant
# rien du calcul de distance ni de l'affichage d'itinéraire.

step "Carnet d'adresses"

add_address() { # nom adresse lat lon contact
  local body out
  body="$(jq -n --arg n "$1" --arg a "$2" --argjson lat "$3" --argjson lon "$4" \
    --arg c "$5" \
    '{name:$n, address:$a, latitude:$lat, longitude:$lon,
      contactName:$c, contactPhone:"0551020304", city:"Alger", country:"DZ"}')"
  out="$(mapi POST /commercant/adresses "$body")"
  if is_error <<<"$out"; then
    fail "Adresse « $1 » refusée" "$out"
  fi
  pass "Adresse « $1 »"
}

# Le carnet peut déjà les porter (reprise via `EMAIL=`) : on ne les repose que
# s'il en manque. Deux entrées de même nom rendraient le choix du test ambigu,
# et un test ambigu échoue un jour sur deux sans qu'on sache pourquoi.
book="$(mapi GET /commercant/adresses)"
have() { jq -e --arg n "$1" '[(.data // .)[]? | .name] | index($n) != null' >/dev/null 2>&1 <<<"$book"; }

PICKUP_NAME="${PICKUP_NAME:-Dépôt Alger-Centre}"
DROPOFF_NAME="${DROPOFF_NAME:-Client Hydra}"

have "$PICKUP_NAME"  || add_address "$PICKUP_NAME"  "12 rue Didouche Mourad, Alger-Centre" 36.7719 3.0589 "Karim"
have "$DROPOFF_NAME" || add_address "$DROPOFF_NAME" "8 chemin Mackley, Hydra"              36.7434 3.0290 "Nadia"
have "$PICKUP_NAME" && info "Carnet déjà pourvu, rien réécrit"

# ── 4. Ce qu'il faut à `flutter drive` ──────────────────────────────────────

step "Prêt"
info "Le décor est posé. La commande à lancer côté Windows :"
echo
cat <<CMD
  cd echango_delivery
  flutter drive \\
    --driver=test_driver/integration_test.dart \\
    --target=integration_test/parcours_commercant_test.dart \\
    -d <émulateur> \\
    --dart-define=TEST_MERCHANT_EMAIL=$EMAIL \\
    --dart-define=TEST_MERCHANT_PASSWORD=$PASSWORD \\
    --dart-define=TEST_PICKUP_NAME="$PICKUP_NAME" \\
    --dart-define=TEST_DROPOFF_NAME="$DROPOFF_NAME"
CMD
echo
info "L'application vise déjà http://10.0.2.2:3001 (ApiConfig.bffBaseUrl),"
info "l'alias de l'hôte vu depuis un émulateur Android. Sur un autre support,"
info "ajouter --dart-define=BFF_BASE_URL=…"
