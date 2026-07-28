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
# cryptographiquement VALIDE sur ces routes et ne peut être écarté que par le
# contrôle explicite `req.user.type !== 'transporteur'`. C'est précisément ce
# contrôle qu'on teste ici.
#
# On forge le token plutôt que de créer un compte commerçant : l'inscription
# commerçant crée un Vendor + un Contact côté Fleetbase, des effets de bord
# qu'un script de test n'a pas à laisser derrière lui. Signer nous-mêmes avec
# le vrai JWT_SECRET produit exactement ce qu'on veut éprouver — un jeton
# légitime, du mauvais type.
JWT_SECRET=$(grep -E '^JWT_SECRET=' backend/bff/.env 2>/dev/null | cut -d= -f2- | tr -d '"'"'"'' || true)

if [ -n "$JWT_SECRET" ] && command -v openssl >/dev/null 2>&1; then
  b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
  NOW=$(date +%s)
  H=$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)
  P=$(printf '%s' "{\"sub\":\"fake-merchant-id\",\"email\":\"faux@echango.local\",\"type\":\"merchant\",\"iat\":$NOW,\"exp\":$((NOW+3600))}" | b64url)
  S=$(printf '%s' "$H.$P" | openssl dgst -sha256 -hmac "$JWT_SECRET" -binary | b64url)
  FORGED="$H.$P.$S"

  CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" \
    -H "Authorization: Bearer $FORGED")
  case "$CODE" in
    403) pass "token valide mais non-driver rejeté (403)" ;;
    401) warn "token forgé rejeté en 401 — JWT_SECRET du .env ≠ celui du conteneur ?"
         echo "    Le contrôle de type n'a donc pas été atteint : non concluant." ;;
    *)   fail "FUITE : un token de type 'merchant' est accepté (HTTP $CODE)" "-" ;;
  esac
else
  warn "rejet non-driver non testé (JWT_SECRET introuvable dans backend/bff/.env, ou openssl absent)"
fi

# --- 7. Sans token --------------------------------------------------------
CODE=$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil")
[ "$CODE" = "401" ] && pass "requête sans token rejetée (401)" \
  || fail "une requête sans token n'est pas rejetée (HTTP $CODE)" "-"

# --- 8. Échec de livraison ------------------------------------------------
# Testé sur une commande réellement assignée à ce driver, sinon sauté : le
# endpoint refuse (à raison) une commande qui n'est pas la sienne.
MINE=$(echo "$(api GET /transporteur/commandes)" | jq -r '.active[0].public_id // .active[0].uuid // empty')

# Rien d'assigné, mais une opportunité adhoc disponible : on peut la réclamer
# pour dérouler le flux complet. Opt-in seulement — accepter une commande
# l'assigne ET la démarre, un état que le script ne sait pas défaire.
if [ -z "$MINE" ] && [ "${WITH_MUTATIONS:-0}" = "1" ]; then
  ADHOC=$(echo "$(api GET /transporteur/commandes)" | jq -r '.adhoc[0].public_id // .adhoc[0].uuid // empty')
  if [ -n "$ADHOC" ]; then
    RESP=$(api POST "/transporteur/commandes/$ADHOC/accepter" '{}')
    if echo "$RESP" | jq -e '.errors // .statusCode' >/dev/null 2>&1; then
      warn "POST .../accepter a échoué"
      echo "    Réponse : $(echo "$RESP" | head -c 300)"
    else
      pass "POST /transporteur/commandes/:id/accepter (commande $ADHOC réclamée)"
      MINE="$ADHOC"
    fi
  fi
fi

if [ -n "$MINE" ]; then
  # --- 8a. Transitions disponibles -----------------------------------------
  # Le détail de commande ne porte aucune donnée d'activité (§6.9) : c'est
  # cette route qui fournit à l'app les objets Activity à renvoyer ensuite à
  # update-activity. Sans elle, l'écran détail ne peut rien faire avancer.
  RESP=$(api GET "/transporteur/commandes/$MINE/activites-suivantes")
  if echo "$RESP" | jq -e 'if type=="array" then length > 0 else (.activities // []) | length > 0 end' >/dev/null 2>&1; then
    pass "GET  /transporteur/commandes/:id/activites-suivantes"
    echo "     codes proposés : $(echo "$RESP" | jq -r '(if type=="array" then . else .activities end) | map(.code) | join(", ")' 2>/dev/null)"
    echo "     preuve exigée  : $(echo "$RESP" | jq -r '(if type=="array" then . else .activities end) | map(select(.require_pod == true) | .code) | join(", ") | if . == "" then "aucune" else . end' 2>/dev/null)"
  else
    warn "activites-suivantes n'a renvoyé aucune transition"
    echo "    Réponse : $(echo "$RESP" | head -c 300)"
  fi

  # --- 8b. Envoi effectif d'une transition (opt-in) ------------------------
  # Fait réellement avancer la commande — d'où l'opt-in. On renvoie l'objet
  # Activity COMPLET tel que reçu, ce que valide OrderController@updateActivity.
  if [ "${WITH_MUTATIONS:-0}" = "1" ]; then
    ACT=$(echo "$RESP" | jq -c '(if type=="array" then . else .activities end)[0] // empty' 2>/dev/null)
    if [ -n "$ACT" ]; then
      CODE_ACT=$(echo "$ACT" | jq -r '.code')
      OUT=$(api POST "/transporteur/commandes/$MINE/activite" "$(jq -n --argjson a "$ACT" '{activity:$a}')")
      if echo "$OUT" | jq -e '.statusCode // .errors' >/dev/null 2>&1; then
        warn "POST .../activite a échoué (transition « $CODE_ACT »)"
        echo "    Réponse : $(echo "$OUT" | head -c 300)"
      else
        pass "POST /transporteur/commandes/:id/activite (« $CODE_ACT » appliquée)"
      fi
    fi

    # --- 8c. Upload de preuve photo ---------------------------------------
    # PNG 1x1 transparent en base64 : le plus petit fichier valide possible,
    # suffisant pour valider que le contrôleur accepte du base64 plutôt que
    # du multipart.
    PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
    OUT=$(api POST "/transporteur/commandes/$MINE/preuve" \
      "$(jq -n --arg p "$PNG" '{photos:[$p], remarks:"Test automatisé"}')")
    if echo "$OUT" | jq -e '.statusCode // .errors' >/dev/null 2>&1; then
      warn "POST .../preuve (upload base64) a échoué"
      echo "    Réponse : $(echo "$OUT" | head -c 300)"
    else
      pass "POST /transporteur/commandes/:id/preuve (photo base64)"
    fi
  fi

  RESP=$(api POST "/transporteur/commandes/$MINE/echec" \
    '{"reason":"client_absent","notes":"Test automatisé — sonnette sans réponse"}')
  echo "$RESP" | jq -e '.reason == "client_absent"' >/dev/null 2>&1 \
    || fail "POST /transporteur/commandes/:id/echec" "$RESP"
  pass "POST /transporteur/commandes/:id/echec"
else
  warn "échec de livraison non testé — aucune commande active assignée à ce driver."
  if [ "${WITH_MUTATIONS:-0}" != "1" ]; then
    echo "    Deux options : assigner une commande à ce driver dans la console,"
    echo "    ou relancer avec WITH_MUTATIONS=1 pour réclamer une commande adhoc"
    echo "    disponible et dérouler accepter → échec (⚠️ modifie l'état, la"
    echo "    commande restera assignée et démarrée)."
  fi
fi

# --- Remise du driver hors ligne -----------------------------------------
api POST /transporteur/statut '{"online":false}' >/dev/null
pass "driver remis hors ligne (nettoyage)"

echo ""
echo "──────────────────────────────────────────────────────────"
echo "Non couvert par ce script, à vérifier séparément :"
echo "  - démarrer/activité : modifient un état non trivial à remettre en place."
echo "    (accepter + échec sont couverts via WITH_MUTATIONS=1)"
echo "  - update-activity : les transitions sont désormais exposées par"
echo "    activites-suivantes ; reste à valider l'envoi effectif de l'une"
echo "    d'elles, qui fait avancer la commande."
echo "  - upload de photo (preuve/échec) : base64, jamais testé en vrai."
echo "──────────────────────────────────────────────────────────"
