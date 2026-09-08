#!/usr/bin/env bash
#
# Le CONDUCTEUR parcourt une tournée : progression multi-arrêt pilotée par
# Fleetbase + encaissement ARRÊT PAR ARRÊT (spec §4, points 1 et 2 de §4.6).
#
# ── Ce que ce banc éprouve, et pourquoi ────────────────────────────────────
#
# La fiche conducteur et la feuille d'encaissement affichent le bon montant
# par arrêt (couvert en widget test). Mais la MÉCANIQUE — Fleetbase avance
# `current_waypoint_uuid` d'un arrêt au suivant à chaque `update-activity`, et
# le BFF consigne l'encaissement dans `meta.stop_collections` sans réécrire les
# précédents — n'est prouvée par aucun test qui touche le serveur. C'est ce
# trou que ce banc ferme.
#
# ── Témoins (règle 8) ──────────────────────────────────────────────────────
#
#   • avancement   → après chaque arrêt complété, `payload.current_waypoint_uuid`
#                    pointe l'arrêt SUIVANT ;
#   • enlèvement   → l'arrêt d'enlèvement se complète sans déclaration ;
#   • livraison COD sans déclaration → refusée (cash.cod_declaration_required) ;
#   • livraison COD avec déclaration → `meta.stop_collections` gagne UNE entrée,
#                    les précédentes intactes ; `meta.collected_amount` = somme
#                    courante ;
#   • fin          → le dernier arrêt complète la COMMANDE (status completed),
#                    `stop_collections` = 2 entrées (1200 puis 800), total 2000.
#
# ── Mutation qui DOIT faire échouer ce banc ────────────────────────────────
#
#   Dans `recordStopCollection`, forcer `stopCodAmounts` à `[]` (ou lire
#   `meta.cod_amount` au lieu de l'arrêt) : la 1ʳᵉ livraison réclame alors 2000,
#   `assertCollectedAmount(1200, 2000, …)` exige un motif → l'étape « livraison
#   avec déclaration » échoue.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-tournee-conducteur.sh [conducteur]

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
FLEET_A="${FLEET:-app-parcours-entreprise@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; cleanup; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$HERE/lib/fleetbase.sh"
. "$HERE/lib/resolve-driver.sh"
. "$HERE/lib/driver-session.sh"

DEPOT_A=""; ORD=""; DRV_A=""
cleanup() {
  [ -n "$ORD" ] && fb_api PUT "/int/v1/orders/$ORD" '{"order":{"status":"canceled"}}' >/dev/null 2>&1 || true
  [ -n "${DRV_A:-}" ] && declare -F free_driver >/dev/null && free_driver "$DRV_A"
  [ -n "$DEPOT_A" ] && curl -sS -X DELETE "$BFF_URL/flotte/depots/$DEPOT_A" -H "Authorization: Bearer $A_TOKEN" >/dev/null 2>&1 || true
}

login() { curl -sS -X POST "$BFF_URL/auth/login" -H "Content-Type: application/json" -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty'; }
dapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $D_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $D_TOKEN"; fi; }

# ⚠️ Chaque appel conducteur au BFF fait un `fetchEveryOrder()` (lent sur une
# org chargée). On lit donc la fiche UNE fois par tour, dans `$RO`, et les
# accesseurs parsent cette copie. `refresh` la recharge après une écriture.
RO=""
refresh() { RO="$(dapi GET "/transporteur/commandes/$ORD")"; }
cur_wp() { echo "$RO" | jq -r '.payload.current_waypoint_uuid // empty'; }
ord_status() { echo "$RO" | jq -r '.status // empty'; }
stop_cod() { echo "$RO" | jq -r --arg u "$1" '[.meta.stop_cod_amounts[]? | select(.place_uuid==$u) | .amount] | .[0] // 0'; }
collections() { echo "$RO" | jq -c '[.meta.stop_collections[]? | {place_uuid, collected_amount}]'; }
collected_total() { echo "$RO" | jq -r '.meta.collected_amount // "none"'; }
next_activity() { dapi GET "/transporteur/commandes/$ORD/activites-suivantes" | jq -c 'if type=="array" then .[0] else (.activities[0] // empty) end'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Le conducteur parcourt une tournée (spec §4 — points 1 & 2)"
echo "════════════════════════════════════════════════════════════════"

step "Décor : entreprise A, dépôt A, un conducteur avec un compte"
fb_activate_vendor_by_email "$FLEET_A" >/dev/null 2>&1 || true
A_TOKEN="$(login "$FLEET_A")"
[ -n "$A_TOKEN" ] || fail "connexion entreprise A impossible"
VENDOR_A="$(fb_get "/int/v1/vendors?email=$FLEET_A&limit=100" | jq -r --arg e "$FLEET_A" '(.vendors // .data // []) | map(select(.email==$e)) | last.uuid // empty')"
[ -n "$VENDOR_A" ] || fail "Vendor A introuvable"
DEPOT_A="$(curl -sS -X POST "$BFF_URL/flotte/depots" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d '{"name":"Dépôt Conducteur A","latitude":36.7550,"longitude":3.0450,"phone":"021000030","contactName":"Chef A","province":"Alger"}' | jq -r '.uuid // empty')"
[ -n "$DEPOT_A" ] || fail "création dépôt A échouée"

# Un conducteur qui a DÉJÀ un compte BFF — `obtain_driver_token` le réutilise
# sans passer par l'invitation (comme test-double-cloture). `createTournee` ne
# vérifie pas l'appartenance à la flotte, et `updateActivity` ne demande que
# `isAssignedTo` : cibler ce conducteur suffit.
mapfile -t DRV < <(_accounted_driver_uuids)
DRV_A=""
if [ -n "${1:-}" ]; then
  DRV_A="$(fb_get '/int/v1/drivers?limit=200' | jq -r --arg e "$1" '(.drivers // .data // []) | map(select(.email==$e or .public_id==$e))[0].uuid // empty')"
fi
[ -n "$DRV_A" ] || DRV_A="${DRV[0]:-}"
[ -n "$DRV_A" ] || fail "aucun conducteur avec un compte BFF"
free_driver() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }
free_driver "$DRV_A"
obtain_driver_token "$DRV_A" >/dev/null 2>&1 || fail "jeton conducteur impossible" "${DRIVER_SESSION_ERROR:-}"
D_TOKEN="$DRIVER_TOKEN"
pass "A (vendor ${VENDOR_A:0:8}…), dépôt ${DEPOT_A:0:8}…, conducteur ${DRV_A:0:8}… (${DRIVER_SESSION_NOTE:-session})"

step "L'entreprise crée une tournée de 3 arrêts, confiée à ce conducteur"
BODY="$(jq -n --arg d "$DEPOT_A" --arg drv "$DRV_A" '{
  price: 3000, vehicleType: "moto", podMethod: "aucune",
  targetUuid: $drv,
  stops: [
    { depotUuid: $d, type: "pickup", items: [ { description: "lot", quantity: 3 } ] },
    { locationName: "Client Nord", latitude: 36.7300, longitude: 3.0700,
      contactName: "Client Nord", contactPhone: "0555111222", province: "Alger",
      items: [ { description: "colis A", quantity: 1 } ], codAmount: 1200 },
    { locationName: "Client Sud", latitude: 36.7000, longitude: 3.1200,
      contactName: "Client Sud", contactPhone: "0555333444", province: "Blida",
      items: [ { description: "colis B", quantity: 1 } ], codAmount: 800 }
  ]
}')"
resp="$(curl -sS -X POST "$BFF_URL/flotte/tournees" -H "Content-Type: application/json" -H "Authorization: Bearer $A_TOKEN" -d "$BODY")"
ORD="$(echo "$resp" | jq -r '.fleetbaseOrderId // empty')"
[ -n "$ORD" ] || fail "création tournée échouée" "$(echo "$resp" | head -c 400)"
pass "tournée ${ORD:0:12}… confiée à ${DRV_A:0:8}…"

step "Le conducteur démarre la tournée"
sd="$(dapi POST "/transporteur/commandes/$ORD/demarrer" '{}')"
echo "$sd" | jq -e 'type=="object" and ((.statusCode // 0)|tonumber) < 300' >/dev/null 2>&1 \
  || fail "démarrage refusé" "$(echo "$sd" | jq -c '{code,message}' 2>/dev/null || echo "$sd" | head -c 200)"
refresh
FIRST_WP="$(cur_wp)"
[ -n "$FIRST_WP" ] || fail "aucun arrêt courant après démarrage — Fleetbase ne suit pas current_waypoint_uuid ?"
[ "$FIRST_WP" = "$DEPOT_A" ] || fail "l'arrêt courant n'est pas l'enlèvement (dépôt A)" "courant=$FIRST_WP"
pass "démarrée, arrêt courant = l'enlèvement (dépôt A)"

# ── Parcours des arrêts ────────────────────────────────────────────────────
#
# Le flux « service stop » de Fleetbase a plusieurs activités par arrêt
# (`enroute`, puis l'activité qui complète l'arrêt et avance
# `current_waypoint_uuid`). On applique donc les activités **jusqu'à ce que
# l'arrêt courant change**, et c'est le BFF qui nous dit laquelle exige la
# déclaration d'encaissement : elle ressort `cash.cod_declaration_required`, on
# la rejoue alors avec le montant.
declare -a DONE_STOPS=()
apply_ok() { echo "$1" | jq -e 'type=="object" and ((.statusCode // 0)|tonumber) < 300' >/dev/null 2>&1; }

for stop_i in 1 2 3 4; do
  # `$RO` est à jour (refresh au démarrage, ou après le dernier apply du tour
  # précédent).
  [ "$(ord_status)" = "completed" ] && break
  wp="$(cur_wp)"
  [ -n "$wp" ] || fail "plus d'arrêt courant alors que la commande n'est pas terminée (status $(ord_status))"
  cod="$(stop_cod "$wp")"
  step "Arrêt ${stop_i} — ${wp:0:8}…  (COD annoncé: ${cod:-0})"

  cash_step_seen=0
  for a in 1 2 3 4 5 6; do
    act="$(next_activity)"
    [ -n "$act" ] && [ "$act" != "null" ] || fail "plus d'activité pour l'arrêt ${wp:0:8}… (status $(ord_status))"
    acode="$(echo "$act" | jq -r '.code // .status // "?"')"

    r="$(dapi POST "/transporteur/commandes/$ORD/activite" "$(jq -n --argjson a "$act" '{activity:$a}')")"
    code="$(echo "$r" | jq -r '.code // empty')"

    if [ "$code" = "cash.cod_declaration_required" ]; then
      cash_step_seen=1
      [ "${cod:-0}" != "0" ] || fail "un arrêt SANS COD réclame une déclaration (${wp:0:8}…)"
      before="$(collections)"
      r="$(dapi POST "/transporteur/commandes/$ORD/activite" "$(jq -n --argjson a "$act" --argjson c "$cod" --arg w "$wp" '{activity:$a, cash:{collectedAmount:$c, waypointUuid:$w}}')")"
      apply_ok "$r" || fail "arrêt à ${cod} avec déclaration : refusé" "$(echo "$r" | jq -c '{code,message}' 2>/dev/null || echo "$r" | head -c 200)"
      refresh
      after="$(collections)"
      [ "$(echo "$after" | jq 'length')" = "$(( $(echo "$before" | jq 'length') + 1 ))" ] \
        || fail "stop_collections n'a pas gagné exactement une entrée" "avant=$before après=$after"
      echo "$after" | jq -e --arg w "$wp" --argjson c "$cod" 'any(.[]; .place_uuid==$w and .collected_amount==$c)' >/dev/null \
        || fail "l'entrée de cet arrêt n'a pas le bon montant" "$after"
      pass "activité « ${acode} » : encaissement déclaré ${cod} → stop_collections = ${after} (total $(collected_total))"
    elif apply_ok "$r"; then
      echo "   activité « ${acode} » appliquée"
      refresh
    else
      fail "activité « ${acode} » refusée" "$(echo "$r" | jq -c '{code,message}' 2>/dev/null || echo "$r" | head -c 200)"
    fi

    # L'arrêt a-t-il avancé ? (ou la commande terminée)
    [ "$(ord_status)" = "completed" ] && break
    [ "$(cur_wp)" != "$wp" ] && { echo "   → arrêt courant avancé vers $(cur_wp | cut -c1-8)…"; break; }
  done

  nwp="$(cur_wp)"; nst="$(ord_status)"
  if [ "$nst" != "completed" ]; then
    [ -n "$nwp" ] && [ "$nwp" != "$wp" ] \
      || fail "après l'arrêt ${wp:0:8}…, current_waypoint_uuid n'a pas avancé (toujours ${nwp:0:8}…)"
  fi
  if [ "${cod:-0}" != "0" ]; then
    [ "$cash_step_seen" = "1" ] || fail "l'arrêt à ${cod} s'est complété SANS jamais réclamer de déclaration" \
      "isTerminalActivity ne reconnaît pas l'activité qui complète un arrêt de tournée — le gate est à revoir"
  fi
  DONE_STOPS+=("$wp")
done

step "VERDICT"
refresh
st="$(ord_status)"
[ "$st" = "completed" ] || fail "la tournée n'est pas terminée après tous les arrêts (status $st)"
final="$(collections)"
[ "$(echo "$final" | jq 'length')" = "2" ] || fail "stop_collections attendu à 2 entrées" "$final"
echo "$final" | jq -e --arg d "$DEPOT_A" 'all(.[]; .place_uuid != $d)' >/dev/null \
  || fail "l'enlèvement (sans COD) ne devrait pas figurer dans stop_collections" "$final"
tot="$(collected_total)"
[ "$tot" = "2000" ] || fail "meta.collected_amount attendu à 2000 (1200 + 800), obtenu « $tot »" "$final"
pass "tournée terminée ; encaissements par arrêt = ${final} ; total = ${tot}"

cleanup
echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le conducteur a parcouru la tournée : Fleetbase a avancé"
echo "   current_waypoint_uuid arrêt par arrêt, le BFF a consigné chaque"
echo "   encaissement dans stop_collections sans réécrire les précédents,"
echo "   et le dernier arrêt a clôturé la commande."
echo "════════════════════════════════════════════════════════════════"
