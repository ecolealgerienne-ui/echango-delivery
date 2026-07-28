#!/usr/bin/env bash
# Relève la forme réelle de l'objet Activity attendu par
# POST /transporteur/commandes/:id/activite.
#
# C'est le dernier inconnu bloquant avant de câbler l'écran détail de l'app :
# update-activity attend un objet Activity COMPLET issu de la config de la
# commande, pas une chaîne de statut (vérifié dans OrderController@updateActivity,
# journal §6.1). Reste à savoir sous quelle clé l'app le récupère.
#
# Prérequis : une commande assignée au driver (au besoin :
# WITH_MUTATIONS=1 ./scripts/test-transporteur-module.sh <uuid>).
set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-motdepasse123}"
DRIVER_UUID="${1:-${FLEETBASE_DRIVER_UUID:-}}"
OUT="${OUT:-/tmp/echango-order-detail.json}"

command -v jq >/dev/null 2>&1 || {
  echo "❌ jq requis : sudo apt update && sudo apt install -y jq"; exit 1; }

# Retrouver le compte driver si l'email n'est pas fourni.
if [ -z "$EMAIL" ]; then
  [ -n "$DRIVER_UUID" ] || {
    echo "Usage : ./scripts/inspect-order-activity.sh <uuid-driver>"
    echo "   ou : EMAIL=<compte> PASSWORD=<mdp> ./scripts/inspect-order-activity.sh"
    exit 1; }
  EMAIL=$(docker exec echango_bff_postgres psql -U bff_user -d echango_bff -tAc \
    "SELECT email FROM \"DriverAccount\" WHERE \"fleetbaseDriverUuid\"='$DRIVER_UUID';" \
    2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$EMAIL" ] || { echo "❌ Aucun compte driver pour $DRIVER_UUID"; exit 1; }
fi

TOKEN=$(curl -sS -X POST "$BFF_URL/auth/transporteur/login" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
  | jq -r '.token // empty')
[ -n "$TOKEN" ] || { echo "❌ Login échoué pour $EMAIL"; exit 1; }
echo "✅ Connecté : $EMAIL"

ORDER=$(curl -sS "$BFF_URL/transporteur/commandes" -H "Authorization: Bearer $TOKEN" \
  | jq -r '.active[0].public_id // .active[0].uuid // empty')

if [ -z "$ORDER" ]; then
  echo "❌ Aucune commande active assignée à ce driver."
  echo "   En réclamer une : WITH_MUTATIONS=1 ./scripts/test-transporteur-module.sh $DRIVER_UUID"
  exit 1
fi
echo "✅ Commande : $ORDER"
echo ""

curl -sS "$BFF_URL/transporteur/commandes/$ORDER" -H "Authorization: Bearer $TOKEN" > "$OUT"

echo "── Clés de premier niveau ────────────────────────────────"
jq -r 'keys[]' "$OUT" | tr '\n' ' '; echo; echo

echo "── Champs de statut / progression ────────────────────────"
jq '{status, adhoc, dispatched, started, public_id,
     order_config_uuid, tracker_data: (.tracker_data // null)}' "$OUT"
echo

echo "── Candidats « Activity » (ce que update-activity attend) ─"
FOUND=0
for k in config order_config activity activities next_activity current_activity tracker_data; do
  if jq -e --arg k "$k" 'has($k) and (.[$k] != null)' "$OUT" >/dev/null 2>&1; then
    echo "▸ .$k :"
    jq --arg k "$k" '.[$k]' "$OUT" | head -40
    echo
    FOUND=1
  fi
done

if [ "$FOUND" = "0" ]; then
  echo "Aucune de ces clés n'est présente dans la réponse."
  echo ""
  echo "⚠️  Conclusion probable : la liste des activités possibles ne vient PAS"
  echo "    du détail de commande. Elle est vraisemblablement portée par la"
  echo "    config de commande (OrderConfig), à récupérer séparément :"
  echo ""
  echo "      docker exec fleetbase-src-application-1 php artisan tinker \\"
  echo "        --execute=\"echo DB::table('order_configs')->value('flow');\""
  echo ""
  echo "    Dans ce cas, le BFF devra exposer ce flow à l'app — le module"
  echo "    transporteur n'a pas d'endpoint pour ça aujourd'hui."
fi

echo "── Étapes / waypoints ────────────────────────────────────"
jq '.payload | {pickup: (.pickup.public_id // null),
                dropoff: (.dropoff.public_id // null),
                waypoints: ((.waypoints // []) | map({public_id, status}))}' "$OUT" 2>/dev/null \
  || echo "(pas de payload exploitable)"

echo ""
echo "Réponse complète : $OUT"
