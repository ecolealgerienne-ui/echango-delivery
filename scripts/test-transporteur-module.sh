#!/usr/bin/env bash
# Valide au curl le module transporteur du BFF (docs/specs_app_transporteur.md §3-5).
#
# Suppose la tranche auth déjà validée : lancer scripts/test-driver-auth.sh
# d'abord. Ce script réutilise le même compte driver (ou en crée un).
#
# NON exécuté dans le sandbox Claude Code (ni Docker ni Fleetbase) — écrit
# à partir du code source Fleetbase lu le 28/07/2026. Les points les plus
# incertains sont signalés ⚠️ en sortie.
set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
DRIVER_UUID="${1:-${FLEETBASE_DRIVER_UUID:-}}"
EMAIL="${EMAIL:-transporteur-test-$RANDOM@echango.local}"
PASSWORD="${PASSWORD:-motdepasse123}"

command -v jq >/dev/null 2>&1 || {
  echo "❌ jq requis : sudo apt update && sudo apt install -y jq"; exit 1; }

if [ -z "$DRIVER_UUID" ]; then
  echo "Usage : ./scripts/test-transporteur-module.sh <uuid-du-driver-fleetbase>"
  exit 1
fi

if [[ "$DRIVER_UUID" == driver_* ]]; then
  echo "❌ \"$DRIVER_UUID\" est un public_id, pas un uuid. Récupérer le uuid :"
  echo "  docker exec fleetbase-src-application-1 php artisan tinker \\"
  echo "    --execute=\"echo DB::table('drivers')->where('public_id','$DRIVER_UUID')->value('uuid');\""
  exit 1
fi

pass() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
fail() { echo "❌ $1"; echo "   Réponse : $2"; exit 1; }

api() { # method path [body]
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$BFF_URL$path" \
      -H 'Content-Type: application/json' -H "Authorization: Bearer $TOKEN" -d "$body"
  else
    curl -sS -X "$method" "$BFF_URL$path" -H "Authorization: Bearer $TOKEN"
  fi
}

echo "BFF        : $BFF_URL"
echo "Driver UUID: $DRIVER_UUID"
echo ""

# --- Auth (prérequis) -----------------------------------------------------
REG=$(curl -sS -X POST "$BFF_URL/auth/transporteur/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg u "$DRIVER_UUID" --arg e "$EMAIL" --arg p "$PASSWORD" \
        '{fleetbaseDriverUuid:$u, email:$e, password:$p, firstName:"Test", lastName:"Transporteur"}')")

TOKEN=$(echo "$REG" | jq -r '.token // empty')

if [ -z "$TOKEN" ]; then
  # Le driver est déjà lié à un compte (cas normal dès la 2e exécution, ou
  # après test-driver-auth.sh). On ne peut pas deviner l'email de ce compte —
  # il faut le relire dans la base du BFF, puis se connecter avec.
  if echo "$REG" | grep -q 'already linked'; then
    EXISTING=$(docker exec echango_bff_postgres \
      psql -U bff_user -d echango_bff -tAc \
      "SELECT email FROM \"DriverAccount\" WHERE \"fleetbaseDriverUuid\"='$DRIVER_UUID';" \
      2>/dev/null | tr -d '[:space:]' || true)

    if [ -n "$EXISTING" ]; then
      TOKEN=$(curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
        -H 'Content-Type: application/json' \
        -d "$(jq -n --arg e "$EXISTING" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
        | jq -r '.token // empty')

      if [ -n "$TOKEN" ]; then
        pass "auth — compte existant réutilisé ($EXISTING)"
      else
        echo "❌ Compte existant trouvé ($EXISTING) mais mot de passe différent."
        echo "   Relancer en le fournissant :"
        echo "     EMAIL='$EXISTING' PASSWORD='<le bon>' $0 $DRIVER_UUID"
        echo "   Ou repartir de zéro pour ce driver :"
        echo "     docker exec echango_bff_postgres psql -U bff_user -d echango_bff \\"
        echo "       -c \"DELETE FROM \\\"DriverAccount\\\" WHERE \\\"fleetbaseDriverUuid\\\"='$DRIVER_UUID';\""
        exit 1
      fi
    fi
  else
    # Register a échoué pour une autre raison : tenter quand même un login,
    # au cas où EMAIL/PASSWORD auraient été fournis explicitement.
    TOKEN=$(curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
      | jq -r '.token // empty')
  fi
fi

[ -n "$TOKEN" ] || fail "impossible d'obtenir un JWT driver" "$REG"
[ -n "${EXISTING:-}" ] || pass "auth — JWT driver obtenu"

# --- 1. Profil ------------------------------------------------------------
RESP=$(api GET /transporteur/profil)
echo "$RESP" | jq -e '.fleetbaseDriverUuid' >/dev/null 2>&1 \
  || fail "GET /transporteur/profil" "$RESP"
pass "GET  /transporteur/profil"

# --- 2. Statut en ligne ---------------------------------------------------
# Passe par POST /v1/drivers/{id}/toggle-online. On envoie toujours `online`
# explicitement : omis, Fleetbase inverse la valeur courante, ce qui
# désynchroniserait sur une requête rejouée.
RESP=$(api POST /transporteur/statut '{"online":true}')
echo "$RESP" | jq -e '.online == true' >/dev/null 2>&1 \
  || fail "POST /transporteur/statut" "$RESP"
pass "POST /transporteur/statut (online=true)"

# --- 3. Position ----------------------------------------------------------
# POST /v1/drivers/{id}/track. Alger centre.
RESP=$(api POST /transporteur/position '{"latitude":36.7538,"longitude":3.0588,"heading":90,"speed":0}')
echo "$RESP" | jq -e '.success == true' >/dev/null 2>&1 \
  || fail "POST /transporteur/position" "$RESP"
pass "POST /transporteur/position"

# --- 4. Liste des commandes ----------------------------------------------
# Le filtrage est fait DANS le BFF, jamais par paramètre serveur : §2.8 du
# journal a montré que Fleetbase ignore silencieusement les filtres non
# supportés sur /orders et renvoie toute la collection de la compagnie.
RESP=$(api GET /transporteur/commandes)
echo "$RESP" | jq -e 'has("active") and has("adhoc") and has("history")' >/dev/null 2>&1 \
  || fail "GET /transporteur/commandes" "$RESP"
N_ACTIVE=$(echo "$RESP" | jq '.active | length')
N_ADHOC=$(echo "$RESP" | jq '.adhoc | length')
pass "GET  /transporteur/commandes (actives=$N_ACTIVE, adhoc=$N_ADHOC)"

# --- 5. ⚠️ Anti-IDOR : commande d'un autre driver -------------------------
# Le test qui compte le plus. On prend une commande RÉELLE de la compagnie qui
# n'est pas assignée à ce driver, et on vérifie que le BFF la refuse. Sans ce
# filtrage côté BFF, Fleetbase la renverrait volontiers (§2.8).
OTHER=$(docker exec fleetbase-src-application-1 php artisan tinker --execute="
  \$o = DB::table('orders')
    ->whereNotNull('driver_assigned_uuid')
    ->where('driver_assigned_uuid','!=','$DRIVER_UUID')
    ->value('uuid');
  echo \$o ?: '';" 2>/dev/null | tr -d '[:space:]' || true)

if [ -n "$OTHER" ]; then
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/commandes/$OTHER" \
    -H "Authorization: Bearer $TOKEN")
  if [ "$CODE" = "404" ]; then
    pass "anti-IDOR — commande d'un autre driver refusée (404)"
  else
    fail "FUITE : commande d'un autre driver accessible (HTTP $CODE)" "$OTHER"
  fi
else
  warn "anti-IDOR non testé — aucune commande assignée à un AUTRE driver en base."
  echo "    Créer une 2e commande assignée ailleurs puis relancer : c'est le"
  echo "    contrôle le plus important de ce script."
fi

# --- 6. Rejet d'un token non-driver --------------------------------------
# Les 3 personas partagent le même émetteur JWT : un token commerçant est donc
# structurellement valide ici et doit être rejeté explicitement.
MERCHANT_TOKEN=$(curl -sS -X POST "$BFF_URL/auth/merchant/login" \
  -H 'Content-Type: application/json' \
  -d '{"email":"inexistant@echango.local","password":"x"}' | jq -r '.token // empty')
if [ -n "$MERCHANT_TOKEN" ]; then
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" \
    -H "Authorization: Bearer $MERCHANT_TOKEN")
  [ "$CODE" = "403" ] && pass "token non-driver rejeté (403)" \
    || fail "un token non-driver est accepté (HTTP $CODE)" "-"
else
  warn "rejet non-driver non testé (pas de compte commerçant sous la main)"
fi

# --- 7. Sans token --------------------------------------------------------
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil")
[ "$CODE" = "401" ] && pass "requête sans token rejetée (401)" \
  || fail "une requête sans token n'est pas rejetée (HTTP $CODE)" "-"

# --- 8. Échec de livraison ------------------------------------------------
# Testé sur une commande réellement assignée à ce driver, sinon sauté : le
# endpoint refuse (à raison) une commande qui n'est pas la sienne.
MINE=$(echo "$(api GET /transporteur/commandes)" | jq -r '.active[0].uuid // .active[0].id // empty')
if [ -n "$MINE" ]; then
  RESP=$(api POST "/transporteur/commandes/$MINE/echec" \
    '{"reason":"client_absent","notes":"Test automatisé — sonnette sans réponse"}')
  echo "$RESP" | jq -e '.reason == "client_absent"' >/dev/null 2>&1 \
    || fail "POST /transporteur/commandes/:id/echec" "$RESP"
  pass "POST /transporteur/commandes/:id/echec"
else
  warn "échec de livraison non testé — aucune commande active assignée à ce driver."
  echo "    Assigner une commande à ce driver dans la console, puis relancer."
fi

# --- Remise du driver hors ligne -----------------------------------------
api POST /transporteur/statut '{"online":false}' >/dev/null
pass "driver remis hors ligne (nettoyage)"

echo ""
echo "──────────────────────────────────────────────────────────"
echo "Non couvert par ce script, à vérifier séparément :"
echo "  - accepter/démarrer/activité : demandent une commande adhoc réelle et"
echo "    modifient un état non trivial à remettre en place. Tester à la main"
echo "    avec une commande jetable."
echo "  - update-activity attend un objet Activity COMPLET issu de la config de"
echo "    la commande, pas une chaîne de statut. Vérifier la forme exacte"
echo "    renvoyée par GET /transporteur/commandes/:id avant de câbler l'app."
echo "  - upload de photo (preuve/échec) : base64, jamais testé en vrai."
echo "──────────────────────────────────────────────────────────"
