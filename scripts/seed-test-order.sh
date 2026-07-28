#!/usr/bin/env bash
# Crée une commande adhoc jetable et la dispatche, pour pouvoir relancer les
# tests du module transporteur.
#
# Pourquoi : chaque exécution de test-transporteur-module.sh en mode
# WITH_MUTATIONS=1 consomme la commande (accepter → activite → completed), donc
# il n'en reste aucune au run suivant. Recréer à la main dans la console à
# chaque fois est fastidieux.
#
# Principe : plutôt que d'inventer client/lieux/config — ce qui demanderait de
# recréer une arborescence entière — on RECOPIE ceux d'une commande existante.
# Il faut donc au moins une commande déjà en base (celle de l'autre driver
# suffit).
#
# ⚠️ NON TESTÉ dans le sandbox Claude Code (ni Docker ni Fleetbase). Écrit à
# partir des formes de payload établies au journal §2.5 (enveloppe {order:{…}})
# et §6.7 (les routes v1 s'adressent par public_id).
set -euo pipefail

ENV_FILE="${ENV_FILE:-backend/bff/.env}"
[ -f "$ENV_FILE" ] || { echo "❌ $ENV_FILE introuvable (lancer depuis la racine du repo)"; exit 1; }

FB_URL=$(grep -E '^FLEETBASE_API_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '"'"'"'')
FB_KEY=$(grep -E '^FLEETBASE_API_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"'"'"'')
FB_URL="${FB_URL:-http://localhost:8000}"

# Le .env vise le réseau Docker ; depuis l'hôte c'est localhost.
FB_URL=$(echo "$FB_URL" | sed 's|host.docker.internal|localhost|')

[ -n "$FB_KEY" ] || { echo "❌ FLEETBASE_API_KEY vide dans $ENV_FILE"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq requis : sudo apt install -y jq"; exit 1; }

fb() { # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$FB_URL$p" -H "Authorization: Bearer $FB_KEY" \
      -H 'Content-Type: application/json' -d "$b"
  else
    curl -sS -X "$m" "$FB_URL$p" -H "Authorization: Bearer $FB_KEY"
  fi
}

echo "Fleetbase : $FB_URL"

# --- 1. Trouver une commande à recopier ----------------------------------
ORDERS=$(fb GET "/int/v1/orders?limit=50")
TEMPLATE=$(echo "$ORDERS" \
  | jq -r '(.orders // .data // .) | map(select(.payload_uuid != null)) | .[0] // empty')

if [ -z "$TEMPLATE" ]; then
  echo "❌ Aucune commande existante à recopier."
  echo "   En créer une première à la main dans la console Fleetbase"
  echo "   (Fleet-Ops > Orders > New), avec un point de départ et d'arrivée."
  exit 1
fi

CONFIG=$(echo "$TEMPLATE" | jq -r '.order_config_uuid // empty')
CUSTOMER=$(echo "$TEMPLATE" | jq -r '.customer_uuid // empty')
CUSTOMER_TYPE=$(echo "$TEMPLATE" | jq -r '.customer_type // "fleet-ops:contact"')
TEMPLATE_ID=$(echo "$TEMPLATE" | jq -r '.public_id // empty')

# Les lieux ne sont pas dans la liste : il faut le détail de la commande.
#
# ⚠️ Le détail vient de l'API v1, qui n'expose QUE des identifiants publics,
# sous la clé `id` — jamais d'uuid (constaté le 28/07 : `.payload.pickup.uuid`
# revenait vide alors que la commande était bien formée). Or la création passe
# par int/v1, qui veut des uuid. Il faut donc traduire public_id → uuid via la
# liste des places.
DETAIL=$(fb GET "/v1/orders/$TEMPLATE_ID")
PICKUP_PID=$(echo "$DETAIL" | jq -r '(.data // .) | .payload.pickup.id // empty')
DROPOFF_PID=$(echo "$DETAIL" | jq -r '(.data // .) | .payload.dropoff.id // empty')

if [ -z "$PICKUP_PID" ] || [ -z "$DROPOFF_PID" ]; then
  echo "❌ La commande modèle ($TEMPLATE_ID) n'a pas de départ/arrivée exploitables."
  echo "   pickup=$PICKUP_PID dropoff=$DROPOFF_PID"
  echo "   Payload reçu :"
  echo "$DETAIL" | jq '(.data // .) | .payload' 2>/dev/null | head -c 500
  exit 1
fi

PLACES=$(fb GET "/int/v1/places?limit=200")
pid_to_uuid() {
  echo "$PLACES" | jq -r --arg p "$1" \
    '((.places // .data // .) | map(select(.public_id == $p)) | .[0].uuid) // empty'
}
PICKUP=$(pid_to_uuid "$PICKUP_PID")
DROPOFF=$(pid_to_uuid "$DROPOFF_PID")

if [ -z "$CONFIG" ] || [ -z "$PICKUP" ] || [ -z "$DROPOFF" ]; then
  echo "❌ Impossible de résoudre les lieux en uuid."
  echo "   config=$CONFIG"
  echo "   pickup  $PICKUP_PID → ${PICKUP:-(introuvable)}"
  echo "   dropoff $DROPOFF_PID → ${DROPOFF:-(introuvable)}"
  exit 1
fi
echo "✅ Modèle : $TEMPLATE_ID (départ $PICKUP_PID, arrivée $DROPOFF_PID)"

# --- 2. Créer la commande adhoc ------------------------------------------
# Enveloppe {order:{…}} obligatoire (journal §2.5).
BODY=$(jq -n --arg c "$CONFIG" --arg cu "$CUSTOMER" --arg ct "$CUSTOMER_TYPE" \
             --arg p "$PICKUP" --arg d "$DROPOFF" \
  '{order: {order_config_uuid:$c, customer_uuid:$cu, customer_type:$ct,
            adhoc:true, type:"transport",
            payload:{pickup_uuid:$p, dropoff_uuid:$d},
            meta:{seeded_by:"seed-test-order.sh"}}}')

CREATED=$(fb POST "/int/v1/orders" "$BODY")
NEW_ID=$(echo "$CREATED" | jq -r '(.order // .data // .) | .public_id // empty')

if [ -z "$NEW_ID" ]; then
  echo "❌ Création échouée. Réponse :"
  echo "$CREATED" | head -c 600
  exit 1
fi
echo "✅ Commande créée : $NEW_ID"

# --- 3. Dispatcher --------------------------------------------------------
# Déclenche le broadcast géospatial vers les drivers en ligne à proximité
# (specs_echango_delivery.md §3.2). Sans ça la commande n'apparaît pas comme
# opportunité adhoc.
# Une commande créée avec adhoc:true est déjà dispatchée par Fleetbase — le
# refus « already been dispatched » est donc un succès, pas une erreur.
DISPATCHED=$(fb POST "/v1/orders/$NEW_ID/dispatch" '{}')
if echo "$DISPATCHED" | jq -e '(.data // .) | .dispatched == true' >/dev/null 2>&1; then
  echo "✅ Commande dispatchée (adhoc)"
elif echo "$DISPATCHED" | grep -qi 'already been dispatched'; then
  echo "✅ Commande déjà dispatchée à la création (adhoc)"
else
  echo "⚠️  Dispatch incertain. Réponse :"
  echo "$DISPATCHED" | head -c 400
  echo ""
  echo "    La commande existe ; la dispatcher à la main dans la console si"
  echo "    elle n'apparaît pas en adhoc (Orders > sélection > Ordres d'envoi)."
fi

echo ""
echo "Relancer les tests :"
echo "  WITH_MUTATIONS=1 ./scripts/test-transporteur-module.sh <uuid-driver>"
echo ""
echo "⚠️  Le driver doit être EN LIGNE et positionné pour recevoir une adhoc :"
echo "    le matching est géospatial (rayon autour du point de départ)."
