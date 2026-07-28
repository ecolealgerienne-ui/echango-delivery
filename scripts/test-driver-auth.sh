#!/usr/bin/env bash
# Valide au curl les 3 endpoints d'authentification driver du BFF :
#   POST /auth/transporteur/register
#   POST /auth/transporteur/login
#   POST /auth/transporteur/device-token
#
# À exécuter en local (WSL/Docker) — JAMAIS testé dans le sandbox Claude Code
# (ni daemon Docker, ni instance Fleetbase accessible, cf. journal §5.4).
# C'est précisément le but de ce script : ces endpoints ont été écrits par
# lecture du code source Fleetbase, sans aucun appel réel. Les surprises
# attendues en priorité sont documentées en fin de script.
set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
DRIVER_UUID="${1:-${FLEETBASE_DRIVER_UUID:-}}"

# Email aléatoire pour que le script soit rejouable sans se heurter à la
# contrainte d'unicité sur DriverAccount.email.
EMAIL="${EMAIL:-driver-test-$RANDOM@echango.local}"
PASSWORD="${PASSWORD:-motdepasse123}"

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq est requis (extraction du JWT)."
  echo "   Debian/Ubuntu/WSL : sudo apt update && sudo apt install -y jq"
  echo "   macOS             : brew install jq"
  exit 1
fi

if [ -z "$DRIVER_UUID" ]; then
  cat <<'EOF'
❌ UUID du Driver Fleetbase manquant.

Usage : ./scripts/test-driver-auth.sh <uuid-du-driver-fleetbase>

Le provisioning est manuel par décision produit (specs_app_transporteur.md
§2.1/§13 Q8) : le BFF ne CRÉE jamais un Driver, il lie un compte Echango à un
Driver Fleetbase déjà existant. Il faut donc en créer un au préalable via la
console Fleetbase (Fleet-Ops > Drivers) ou via POST /flotte/drivers, puis
récupérer son uuid (pas son public_id).
EOF
  exit 1
fi

# Piège fréquent : la console Fleetbase affiche le public_id (driver_xxxx),
# alors que le BFF compare sur le uuid. Autant le dire tout de suite plutôt
# que de laisser le register répondre "UUID inconnu", exact mais trompeur.
if [[ "$DRIVER_UUID" == driver_* ]]; then
  cat <<EOF
❌ "$DRIVER_UUID" est un public_id, pas un uuid.

Le BFF compare sur le uuid (format 8-4-4-4-12, avec tirets). Récupérer le bon
en laissant Fleetbase interroger sa propre base — pas de mot de passe à
manipuler (ceux du Postgres BFF ne marchent pas ici : autre base, autre
conteneur) :

  docker exec fleetbase-src-application-1 php artisan tinker \\
    --execute="echo DB::table('drivers')->where('public_id','$DRIVER_UUID')->value('uuid');"

Si le conteneur applicatif porte un autre nom : docker ps --format '{{.Names}}'
EOF
  exit 1
fi

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; echo "   Réponse brute : $2"; exit 1; }

echo "BFF        : $BFF_URL"
echo "Driver UUID: $DRIVER_UUID"
echo "Email test : $EMAIL"
echo ""

# --- 0. Le BFF répond-il ? ------------------------------------------------
# On tape une route publique connue ; on veut juste une réponse HTTP, peu
# importe le code, pour distinguer "BFF éteint" de "endpoint cassé".
if ! curl -sS -o /dev/null -m 5 "$BFF_URL/auth/transporteur/login" 2>/dev/null; then
  echo "❌ Aucune réponse de $BFF_URL"
  echo "   Démarrer le BFF : cd backend/bff && docker compose up"
  echo "   (ou npm run start:dev avec un Postgres joignable)"
  exit 1
fi
pass "BFF joignable"

# --- 1. Register ----------------------------------------------------------
# Vérifie au passage que le BFF sait parler à Fleetbase : registerDriver()
# appelle getAllDrivers() pour confirmer que l'UUID existe réellement. Un
# échec ici peut donc venir du BFF *ou* de la config Fleetbase (token Sanctum).
REGISTER_BODY=$(jq -n \
  --arg uuid "$DRIVER_UUID" --arg email "$EMAIL" --arg pw "$PASSWORD" \
  '{fleetbaseDriverUuid:$uuid, email:$email, password:$pw, firstName:"Test", lastName:"Driver"}')

REGISTER_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
  -H 'Content-Type: application/json' -d "$REGISTER_BODY")

echo "$REGISTER_RESP" | jq -e '.token' >/dev/null 2>&1 \
  || fail "register a échoué" "$REGISTER_RESP"
pass "register — compte créé et lié au Driver Fleetbase"

# --- 2. Login -------------------------------------------------------------
LOGIN_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "$EMAIL" --arg pw "$PASSWORD" '{email:$email, password:$pw}')")

TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token // empty')
[ -n "$TOKEN" ] || fail "login a échoué" "$LOGIN_RESP"
pass "login — JWT obtenu"

# --- 3. Device token ------------------------------------------------------
# ⚠️ L'étape la moins fiable : le BFF écrit un UserDevice côté Fleetbase avec
# un payload déduit par analogie, jamais appelé pour de vrai (journal §5.1).
# Le miroir est volontairement best-effort : la requête réussit même si
# l'écriture Fleetbase échoue (le polling REST reste fonctionnel sans push).
# Donc un 2xx ici ne prouve PAS que le miroir a marché — voir vérification
# manuelle ci-dessous.
DEVICE_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/device-token" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d '{"token":"fake-fcm-token-pour-test","platform":"android"}')

echo "$DEVICE_RESP" | jq -e '.id' >/dev/null 2>&1 \
  || fail "device-token a échoué" "$DEVICE_RESP"

if echo "$DEVICE_RESP" | jq -e '.fleetbaseUserDeviceUuid // empty' >/dev/null 2>&1; then
  pass "device-token — jeton enregistré ET miroir Fleetbase UserDevice réussi"
else
  echo "⚠️  device-token — jeton enregistré localement, mais le miroir Fleetbase"
  echo "    a échoué (fleetbaseUserDeviceUuid vide). C'est l'hypothèse non"
  echo "    vérifiée du journal §5.1. Chercher le warning dans les logs du BFF :"
  echo "      docker compose logs bff | grep -i 'mirror device token'"
  echo "    Causes probables : payload à envelopper ({user_device:{...}}), ou"
  echo "    Driver.user_uuid absent (driver Fleetbase sans User rattaché)."
fi

# --- 4. Rejets attendus ---------------------------------------------------
# Un register doit refuser un UUID inconnu. Ce test compte autant que les
# autres : §2.13 du journal a montré que GET /drivers/{uuid} renvoie TOUS les
# drivers au lieu d'un 404, donc une vérification naïve accepterait n'importe
# quel UUID. C'est ce contournement qu'on valide ici.
BOGUS_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "bogus-$RANDOM@echango.local" --arg pw "$PASSWORD" \
        '{fleetbaseDriverUuid:"00000000-0000-0000-0000-000000000000", email:$email, password:$pw}')")

if echo "$BOGUS_RESP" | jq -e '.token' >/dev/null 2>&1; then
  fail "SÉCURITÉ : un UUID Fleetbase bidon a été accepté" "$BOGUS_RESP"
fi
pass "register — UUID inconnu correctement rejeté"

echo ""
echo "──────────────────────────────────────────────────────────"
echo "Tranche auth validée. Identifiants réutilisables pour l'app :"
echo "  email    : $EMAIL"
echo "  password : $PASSWORD"
echo ""
echo "À vérifier ensuite à la main dans Fleetbase (le script ne peut pas) :"
echo "  - la ligne user_devices créée :"
echo "      docker exec fleetbase-src-database-1 mysql -uroot -p fleetbase \\"
echo "        -e \"SELECT uuid, user_uuid, platform, token FROM user_devices;\""
echo "  - qu'un 2e appel device-token avec le MÊME token fasse un upsert et"
echo "    non un doublon (comportement non vérifié, journal §5.1)."
echo "──────────────────────────────────────────────────────────"
