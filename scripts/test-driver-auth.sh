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

# Jeton propre à CETTE exécution. Une constante partagée entre runs laisse des
# UserDevice orphelins en base et rend le test de rotation ininterprétable :
# on compterait des reliquats d'anciens runs au lieu de ce qu'on vient de faire.
FCM_TOKEN="fcm-test-$RANDOM$RANDOM"

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
warn() { echo "⚠️  $1"; }
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
# L'inscription transporteur exige désormais une INVITATION émise par un
# opérateur (correction de sécurité C2 : l'ancienne version laissait n'importe
# qui s'enregistrer sur n'importe quel driver dont il connaissait l'uuid).
# L'émission est réservée au persona `fleet` : il faut donc un compte flotte.
#
# ⚠️ Depuis le Lot 0 du chantier facilitateur, l'inscription d'une entreprise
# ne délivre plus de jeton — elle enregistre une demande et répond
# `403 fleet_pending` — et la connexion est refusée tant que le `Vendor` n'est
# pas `active`. Le script tient donc le rôle de l'admin qui valide, avec la clé
# de service. Le garde n'est pas contourné : il est franchi par le geste prévu,
# et `register-merchant.sh` reste le script qui le prouve à la main.
# shellcheck source=lib/fleetbase.sh
. "$(dirname "$0")/lib/fleetbase.sh"

FLEET_EMAIL="${FLEET_EMAIL:-flotte-test-$RANDOM@echango.local}"

REG_STATUS=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BFF_URL/auth/flotte/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$FLEET_EMAIL" --arg p "$PASSWORD" \
     '{email:$e, password:$p, businessName:"Flotte de test"}')")

# 403 = demande enregistrée (le cas nominal) ; 409 = compte déjà là, réutilisé.
case "$REG_STATUS" in
  403|409) ;;
  2*) fail "l'inscription flotte a délivré un accès immédiat — le garde du Lot 0 ne s'applique pas" "HTTP $REG_STATUS" ;;
  *)  fail "inscription flotte en échec" "HTTP $REG_STATUS" ;;
esac

fb_activate_vendor_by_email "$FLEET_EMAIL" \
  || fail "activation du fournisseur opérateur impossible" "${FLEETBASE_ERROR:-}"

# Second geste d'admin : l'invitation n'est permise que si l'émetteur est le
# prestataire **plateforme** — un conducteur du pool n'appartient à aucune
# entreprise, et seul Echango peut l'inviter (Lot 0, `assertDriverBelongsToFleet`).
# shellcheck source=lib/driver-session.sh
. "$(dirname "$0")/lib/driver-session.sh"
_promote_operator_to_platform "$FLEET_EMAIL" \
  || fail "promotion de l'opérateur en prestataire plateforme impossible" "${PLATFORM_PROMOTION_ERROR:-}"

FLEET_TOKEN=$(curl -sS -X POST "$BFF_URL/auth/flotte/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$FLEET_EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
  | jq -r '.token // empty')

[ -n "$FLEET_TOKEN" ] || fail "impossible d'obtenir un compte opérateur (flotte)" "-"
pass "opérateur — compte flotte validé, promu plateforme, connecté"

INVITE=$(curl -sS -X POST "$BFF_URL/auth/transporteur/invitation" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $FLEET_TOKEN" \
  -d "$(jq -n --arg u "$DRIVER_UUID" --arg e "$EMAIL" \
     '{fleetbaseDriverUuid:$u, email:$e}')")
INVITE_TOKEN=$(echo "$INVITE" | jq -r '.invitationToken // empty')

REGISTER_RESP=""
if [ -n "$INVITE_TOKEN" ]; then
  pass "invitation émise pour le driver"
  REGISTER_BODY=$(jq -n \
    --arg t "$INVITE_TOKEN" --arg email "$EMAIL" --arg pw "$PASSWORD" \
    '{invitationToken:$t, email:$email, password:$pw, firstName:"Test", lastName:"Driver"}')
  REGISTER_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
    -H 'Content-Type: application/json' -d "$REGISTER_BODY")
else
  # Driver déjà lié : l'émission est refusée, c'est le cas normal en rejeu.
  echo "$INVITE" | grep -q 'already has an Echango account' \
    && REGISTER_RESP='{"message":"This driver is already linked to an account"}' \
    || fail "émission d'invitation échouée" "$INVITE"
fi

if echo "$REGISTER_RESP" | jq -e '.token' >/dev/null 2>&1; then
  pass "register — compte créé et lié au Driver Fleetbase"
else
  # Driver déjà lié : cas normal dès la 2e exécution. On récupère l'email du
  # compte existant pour pouvoir continuer, plutôt que d'échouer sur un
  # conflit qui n'en est pas un.
  echo "$REGISTER_RESP" | grep -q 'already linked' \
    || fail "register a échoué" "$REGISTER_RESP"

  EMAIL=$(docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "SELECT email FROM \"DriverAccount\" WHERE \"fleetbaseDriverUuid\"='$DRIVER_UUID';" \
    2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$EMAIL" ] || fail "driver déjà lié, mais compte introuvable en base" "$REGISTER_RESP"
  pass "register — driver déjà lié, compte existant réutilisé ($EMAIL)"
fi

# --- 2. Login -------------------------------------------------------------
LOGIN_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "$EMAIL" --arg pw "$PASSWORD" '{email:$email, password:$pw}')")

TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token // empty')
if [ -z "$TOKEN" ]; then
  echo "❌ login a échoué pour $EMAIL"
  echo "   Si ce compte a un autre mot de passe : PASSWORD='<le bon>' $0 $DRIVER_UUID"
  echo "   Réponse : $LOGIN_RESP"
  exit 1
fi
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
  -d "$(jq -n --arg t "$FCM_TOKEN" '{token:$t, platform:"android"}')")

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

# --- 3b. Rappel du même jeton : upsert ou doublon ? -----------------------
# Cas réel fréquent : Firebase renvoie le même jeton à chaque démarrage de
# l'app, donc cet appel se répète souvent. S'il empile des lignes, un driver
# finit avec N enregistrements identiques et reçoit N notifications.
DEVICE_RESP2=$(curl -sS -X POST "$BFF_URL/auth/transporteur/device-token" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "$(jq -n --arg t "$FCM_TOKEN" '{token:$t, platform:"android"}')")

ID1=$(echo "$DEVICE_RESP"  | jq -r '.id // empty')
ID2=$(echo "$DEVICE_RESP2" | jq -r '.id // empty')

if [ -n "$ID2" ] && [ "$ID1" = "$ID2" ]; then
  pass "device-token — rappel du même jeton réutilisé (pas de doublon côté BFF)"
else
  echo "⚠️  device-token — le rappel du même jeton a produit un enregistrement"
  echo "    différent côté BFF ($ID1 → $ID2). À corriger : l'app rappellera"
  echo "    cette route à chaque démarrage avec le même jeton Firebase."
fi

# --- 3c. Rotation de jeton : l'ancien UserDevice est-il retiré ? ----------
# Cas réel : réinstallation de l'app, effacement des données, restauration de
# sauvegarde — Firebase délivre alors un jeton différent. Sans retrait de
# l'ancien, Fleetbase pousse indéfiniment vers un appareil mort, sans jamais
# produire d'erreur (routeNotificationForFcm renvoie TOUS les devices du user).
# whereNull('deleted_at') est indispensable : les modèles Fleetbase utilisent
# SoftDeletes, et DB::table() court-circuite le scope global — sans ce filtre on
# compte les lignes supprimées et la purge paraît toujours échouer.
ROTATED="fake-fcm-token-rotation-$RANDOM"
api_post_token() {
  curl -sS -X POST "$BFF_URL/auth/transporteur/device-token" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
    -d "$(jq -n --arg t "$1" '{token:$t, platform:"android"}')"
}
ROT_RESP=$(api_post_token "$ROTATED")

if echo "$ROT_RESP" | jq -e '.id' >/dev/null 2>&1; then
  REMAINING=$(docker exec fleetbase-src-application-1 php artisan tinker \
    --execute="echo DB::table('user_devices')->where('token','$FCM_TOKEN')->whereNull('deleted_at')->count();" \
    2>/dev/null | tr -d '[:space:]' || echo "?")
  if [ "$REMAINING" = "0" ]; then
    pass "rotation de jeton — l'ancien UserDevice a bien été retiré côté Fleetbase"
  elif [ "$REMAINING" = "?" ]; then
    warn "rotation de jeton — impossible de compter les user_devices (conteneur introuvable)"
  else
    warn "rotation de jeton — $REMAINING ancien(s) UserDevice subsiste(nt)"
    echo "    Fleetbase continuera d'émettre vers un jeton mort. Voir journal §5.1."
  fi
else
  warn "rotation de jeton non testée (2e enregistrement refusé)"
fi


# --- 4. Rejets attendus ---------------------------------------------------
# Ce bloc testait auparavant qu'un `fleetbaseDriverUuid` inconnu était refusé
# au register. Il passait au vert pour une raison qui n'avait plus rien à voir
# avec ce qu'il annonçait : depuis le passage à l'invitation (revue C2), le DTO
# n'accepte plus du tout ce champ, donc la requête était rejetée par la
# validation avant même d'atteindre la moindre logique. Un test vert qui ne
# vérifie plus rien est pire qu'un test absent — il rassure.
#
# Les trois assertions ci-dessous portent sur ce qui protège réellement
# l'identité d'un transporteur aujourd'hui.

# 4.1 — Un jeton d'invitation inventé ne doit ouvrir aucun compte. C'est la
# garde qui remplace l'ancienne vérification d'UUID.
BOGUS_RESP=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg email "bogus-$RANDOM@echango.local" --arg pw "$PASSWORD" \
        '{invitationToken:"invente-mais-assez-long-pour-passer-le-dto",
          email:$email, password:$pw}')")

if echo "$BOGUS_RESP" | jq -e '.token' >/dev/null 2>&1; then
  fail "SÉCURITÉ : une invitation inventée a été acceptée" "$BOGUS_RESP"
fi
echo "$BOGUS_RESP" | grep -qi 'invitation' \
  || fail "invitation inventée rejetée, mais pas par le contrôle attendu" "$BOGUS_RESP"
pass "register — invitation inventée correctement rejetée"

# 4.2 — Un transporteur ne doit pas pouvoir s'émettre une invitation. Sans ce
# garde, l'inscription sur invitation ne vaudrait rien : n'importe quel driver
# se ferait un jeton pour l'identité d'un autre.
SELF_INVITE=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$BFF_URL/auth/transporteur/invitation" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" \
  -d "$(jq -n --arg u "$DRIVER_UUID" '{fleetbaseDriverUuid:$u}')")
[ "$SELF_INVITE" = "403" ] \
  || fail "SÉCURITÉ : un transporteur a pu émettre une invitation (HTTP $SELF_INVITE)" "-"
pass "invitation — un transporteur ne peut pas s'en émettre (403)"

# 4.3 — Et personne sans jeton du tout.
ANON_INVITE=$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST "$BFF_URL/auth/transporteur/invitation" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$DRIVER_UUID" '{fleetbaseDriverUuid:$u}')")
[ "$ANON_INVITE" = "401" ] \
  || fail "SÉCURITÉ : invitation émise sans authentification (HTTP $ANON_INVITE)" "-"
pass "invitation — refusée sans authentification (401)"

echo ""
echo "──────────────────────────────────────────────────────────"
echo "Tranche auth validée. Identifiants réutilisables pour l'app :"
echo "  email    : $EMAIL"
echo "  password : $PASSWORD"
echo ""
echo ""
echo "──────────────────────────────────────────────────────────"
echo "Inspection manuelle si besoin — l'état des devices de ce driver :"
echo ""
echo "    docker exec fleetbase-src-application-1 php artisan tinker \\"
echo "      --execute=\"print_r(DB::table('user_devices')->get(['uuid','public_id','token'])->toArray());\""
echo "──────────────────────────────────────────────────────────"
