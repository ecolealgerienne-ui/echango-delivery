#!/usr/bin/env bash
#
# Optimisation de parcours : depuis une course déjà tenue, le conducteur
# voit-il les courses du pool proches de sa DÉPOSE — et rien d'autre ?
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
# `docs/specs_localisation_client_et_optimisation_parcours.md` §2. La route
# `GET /transporteur/commandes/:id/optimisation` réutilise l'éligibilité du
# pool (`getClaimablePoolOrders`, partagée avec « Opportunités » — règle 5)
# mais applique un filtre géographique différent : la proximité de la DÉPOSE
# de la course tenue, comparée au point d'ENLÈVEMENT de chaque candidat
# (lecture retenue dans le plan — la spec ne le précise pas explicitement).
#
# Quatre témoins, chacun avec son cas négatif (règle 8) :
#   • une course PROCHE (dans le rayon)      → APPARAÎT ;
#   • une course LOIN (hors rayon)           → ABSENTE ;
#   • une course CIBLÉE à un favori, même proche → ABSENTE (filet §2.3/§2.8) ;
#   • deux candidates à des distances différentes → triées, la plus proche
#     en premier ;
#   • une commande de référence SANS point de dépose → refus explicite
#     (409 order.optimize_no_reference_point), jamais une liste vide.
#
# ⚠️ Le dernier point est prouvé par MUTATION DU VRAI enregistrement
# Fleetbase (retrait de `payload.dropoff.location`), avec vérification que la
# mutation a bien pris avant d'en tirer une conclusion (règle 8 : une
# mutation qui ne prend pas ne prouve RIEN — le piège documenté sur
# `test-wilaya.sh`).
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-optimisation-parcours.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

mapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"; fi; }
dapi() { local tok="$1" m="$2" p="$3" b="${4:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $tok"; fi; }

free_driver() { # uuid — annule les courses non terminées de ce conducteur
  for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$1" \
      '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
    fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
  done; }

# Publie une course. Broadcast par défaut (draft + publier) ; ciblée si $5
# fourni (créée déjà assignée, non diffusée — comme test-visibilite-ciblage.sh).
publish() { # pickupLat pickupLon dropoffLat dropoffLon [targetFavouriteUuid]
  local plat="$1" plon="$2" dlat="$3" dlon="$4" target="${5:-}"
  local body o uuid
  body="$(jq -n --argjson plat "$plat" --argjson plon "$plon" \
    --argjson dlat "$dlat" --argjson dlon "$dlon" --arg target "$target" '
    {
      pickupLocationName:"Dépôt Optim", pickupLatitude:$plat, pickupLongitude:$plon,
      pickupContactName:"Commerce", pickupContactPhone:"+213555000000",
      dropoffLocationName:"Client Optim", dropoffLatitude:$dlat, dropoffLongitude:$dlon,
      dropoffContactName:"Destinataire", dropoffContactPhone:"+213555111111",
      items:[{description:"colis", quantity:1}], price:650, podMethod:"aucune"
    }
    + (if $target == "" then {draft:true} else {targetFavouriteUuid:$target} end)')"
  o="$(mapi POST /commercant/commandes "$body")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // .uuid // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 300)"; return 1; }
  [ -n "$target" ] || mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

# Cette course (uuid $2) est-elle dans les suggestions de la réponse $1 ?
has_suggestion() { echo "$1" | jq -e --arg u "$2" '[.suggestions[]?.uuid] | index($u)' >/dev/null 2>&1 && echo yes || echo no; }

echo "════════════════════════════════════════════════════════════════"
echo "  Optimisation de parcours : suggestions proches de la dépose tenue"
echo "════════════════════════════════════════════════════════════════"

step "Décor : commerçant + deux conducteurs connectables"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"

# ⚠️ Même prudence que test-filtre-wilaya.sh : on sonde un jeton réel plutôt
# que de faire confiance à `obtain_driver_token` en aveugle — certains comptes
# de test portent un mot de passe qui n'est pas le nôtre.
mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID=""; Z_TOKEN=""; Y_UUID=""; Y_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || continue
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")"
  [ "$code" = "200" ] || continue
  if [ -z "$Z_TOKEN" ]; then Z_UUID="$d"; Z_TOKEN="$DRIVER_TOKEN";
  elif [ "$d" != "$Z_UUID" ]; then Y_UUID="$d"; Y_TOKEN="$DRIVER_TOKEN"; break; fi
done
[ -n "$Z_TOKEN" ] && [ -n "$Y_TOKEN" ] || fail "Deux conducteurs connectables requis (mot de passe des comptes de test ?)"
free_driver "$Z_UUID"; free_driver "$Y_UUID"
pass "Commerçant + Z (${Z_UUID:0:8}…, tient la course de référence) + Y (${Y_UUID:0:8}…, favori pour le ciblage)"

step "Y favori (pour la course ciblée)"
for fid in $(mapi GET /commercant/transporteurs/favoris | jq -r '.data[]?.id'); do
  mapi DELETE "/commercant/transporteurs/favoris/$fid" >/dev/null 2>&1 || true
done
mapi POST /commercant/transporteurs/favoris \
  "$(jq -n --arg u "$Y_UUID" '{fleetbaseDriverUuid:$u, partyType:"driver"}')" >/dev/null
pass "Y est favori"

# Zone délibérément à l'écart d'Alger (décalage +/-2° lat, +1° lon par rapport
# aux coordonnées « DéPôT DU PARCOURS » réutilisées par tout le reste de la
# suite) — même géométrie relative, cluster déplacé.
#
# ⚠️ **Nécessaire, trouvé en faisant tourner ce banc contre la vraie instance
# Fleetbase** : à Alger, ce test partage l'espace avec des centaines de
# commandes de scénarios passés jamais nettoyées (425 commandes « sans
# conducteur » constatées le 05/09/2026) — dont plusieurs, à moins de 3 km de
# la dépose de référence historique, prenaient la place de MID dans les 10
# suggestions les plus proches (plafond `MAX_ROUTE_OPTIMIZATION_SUGGESTIONS`).
# Ce n'était pas un défaut du tri ni du plafond — les deux fonctionnaient
# exactement comme prévu — mais un témoin qui ne peut pas être fiable tant
# qu'il partage sa zone avec un historique non maîtrisé. Un rayon de 15 km
# loin de toute zone déjà utilisée rend le test indépendant de ce qui traîne.
#
#   NEAR  ≈ 0.3 km   MID ≈ 9 km   FAR ≈ 37 km (hors rayon de 15 km)
step "Course de référence : Z la tient (acceptée), sa dépose sert de repère"
REF="$(publish 34.7719 4.0589 34.7500 4.0600)"
[[ "$REF" == ERR:* ]] && fail "Publication de la course de référence" "$REF"
acc="$(dapi "$Z_TOKEN" POST "/transporteur/commandes/$REF/accepter" '{}')"
echo "$acc" | jq -e '.uuid // .id // empty' >/dev/null 2>&1 || fail "Z n'a pas pu accepter la course de référence" "$acc"
pass "Référence $REF acceptée par Z — dépose (34.7500, 4.0600)"

step "Quatre candidats publiés : proche, moyen, loin, et ciblé (proche)"
NEAR="$(publish 34.7520 4.0620 34.9000 4.2000)"; [[ "$NEAR" == ERR:* ]] && fail "Publication NEAR" "$NEAR"
MID="$(publish 34.8200 4.0500 34.9000 4.2000)";  [[ "$MID"  == ERR:* ]] && fail "Publication MID" "$MID"
FAR="$(publish 34.4703 3.8277 34.9000 4.2000)";  [[ "$FAR"  == ERR:* ]] && fail "Publication FAR" "$FAR"
TARGETED="$(publish 34.7515 4.0615 34.9000 4.2000 "$Y_UUID")"; [[ "$TARGETED" == ERR:* ]] && fail "Publication ciblée" "$TARGETED"
pass "NEAR=${NEAR:0:8}…  MID=${MID:0:8}…  FAR=${FAR:0:8}…  TARGETED=${TARGETED:0:8}… (assignée à Y, hors pool)"

step "GET .../optimisation depuis la course tenue par Z"
RESP="$(dapi "$Z_TOKEN" GET "/transporteur/commandes/$REF/optimisation")"
echo "$RESP" | jq -e '.suggestions' >/dev/null 2>&1 || fail "Réponse inattendue" "$(echo "$RESP" | head -c 300)"

[ "$(has_suggestion "$RESP" "$NEAR")" = "yes" ] || fail "NEAR (dans le rayon) devrait apparaître" "$RESP"
[ "$(has_suggestion "$RESP" "$MID")"  = "yes" ] || fail "MID (dans le rayon) devrait apparaître" "$RESP"
pass "TÉMOIN POSITIF : les deux candidats dans le rayon apparaissent"

[ "$(has_suggestion "$RESP" "$FAR")" = "no" ] || fail "FAR (hors rayon, ~37 km) NE devrait PAS apparaître" "$RESP"
pass "TÉMOIN NÉGATIF : le candidat hors rayon est absent"

[ "$(has_suggestion "$RESP" "$TARGETED")" = "no" ] || fail "TARGETED (ciblée à Y, pourtant proche) NE devrait PAS apparaître" "$RESP"
pass "TÉMOIN NÉGATIF : une course ciblée à un favori n'apparaît jamais, même en zone compatible"

step "Tri par distance croissante"
idx_near="$(echo "$RESP" | jq -r --arg u "$NEAR" '[.suggestions[]?.uuid] | index($u)')"
idx_mid="$(echo "$RESP" | jq -r --arg u "$MID" '[.suggestions[]?.uuid] | index($u)')"
[ "$idx_near" -lt "$idx_mid" ] || fail "NEAR (~0.3 km) devrait précéder MID (~9 km)" "$RESP"
pass "NEAR précède MID — trié par proximité croissante"

step "Concurrence : Y et Z acceptent NEAR en même temps → un seul gagnant"
# La suggestion n'est pas une réservation (§2.5) : le verrou de l'acceptation
# normale doit s'appliquer sans rien changer sur ce chemin — rejoué plutôt que
# supposé hérité (§2.8).
accept_bg() { curl -sS -o "$3" -w '%{http_code}' -X POST "$BFF_URL/transporteur/commandes/$1/accepter" \
  -H 'Content-Type: application/json' -H "Authorization: Bearer $2" -d '{}' > "$3.code"; }
accept_bg "$NEAR" "$Z_TOKEN" /tmp/optz &
accept_bg "$NEAR" "$Y_TOKEN" /tmp/opty &
wait
cz="$(cat /tmp/optz.code)"; cy="$(cat /tmp/opty.code)"
won=0
[ "$cz" = "200" ] || [ "$cz" = "201" ] && won=$((won+1))
[ "$cy" = "200" ] || [ "$cy" = "201" ] && won=$((won+1))
[ "$won" -eq 1 ] || fail "Deux acceptations sur la même suggestion : $won ont réussi, attendu EXACTEMENT une" "Z→$cz  Y→$cy"
holder="$(fb_get "/int/v1/orders/$NEAR" | jq -r '(.order//.data//.).driver_assigned_uuid')"
{ [ "$holder" = "$Z_UUID" ] || [ "$holder" = "$Y_UUID" ]; } || fail "La suggestion n'est portée par aucun des deux" "$holder"
pass "TÉMOIN : un seul gagnant — le verrou d'acceptation s'applique aussi aux suggestions"

step "Commande de référence SANS point de dépose → refus explicite (règle 10)"
free_driver "$Z_UUID"
REF2="$(publish 36.7719 3.0589 36.7500 3.0600)"; [[ "$REF2" == ERR:* ]] && fail "Publication REF2" "$REF2"
acc2="$(dapi "$Z_TOKEN" POST "/transporteur/commandes/$REF2/accepter" '{}')"
echo "$acc2" | jq -e '.uuid // .id // empty' >/dev/null 2>&1 || fail "Z n'a pas pu accepter REF2" "$acc2"

# Mutation du VRAI enregistrement Fleetbase — mais PAS via `PUT .../orders/:id`
# avec un `payload` reconstruit : essayé d'abord, silencieusement ignoré par
# Fleetbase (200 en retour, `dropoff.location` inchangé au relire) — `payload`
# n'est pas un champ réassignable en bloc sur l'Order, c'est une relation vers
# un `Payload`/`Place` qui a son PROPRE endpoint. `fleetbase-api.client.ts:510`
# (`updatePlace`) le fait déjà pour de vrai côté BFF : `PUT /int/v1/places/:uuid`
# avec un `location` — on réutilise le même chemin ici, dans l'autre sens.
#
# `[0, 0]` plutôt qu'un champ absent : c'est déjà la convention lue par
# `pickupPoint()`/`dropoffPoint()` (`driver-zone.ts`) pour « aucune position »
# (un point au large du golfe de Guinée n'est jamais une vraie dépose), et
# Fleetbase n'a pas montré qu'un `location` puisse être NULL sur un `Place`.
DROPOFF_PLACE="$(fb_get "/int/v1/orders/$REF2" | jq -r '(.order//.data//.).payload.dropoff.uuid')"
[ -n "$DROPOFF_PLACE" ] && [ "$DROPOFF_PLACE" != "null" ] || fail "Impossible de trouver le lieu de dépose de REF2"
fb_api PUT "/int/v1/places/$DROPOFF_PLACE" '{"location":{"type":"Point","coordinates":[0,0]}}' >/dev/null \
  || fail "Mutation (retrait du point de dépose) impossible"

# ⚠️ Règle 8 : une mutation qui ne prend pas ne prouve RIEN. On le vérifie
# avant de tirer la moindre conclusion du refus (ou de son absence).
CHECK="$(fb_get "/int/v1/orders/$REF2" | jq -c '(.order//.data//.).payload.dropoff.location.coordinates')"
[ "$CHECK" = "[0,0]" ] || fail "La mutation n'a jamais pris effet — l'essai ne prouve RIEN" "coordonnées toujours réelles: $CHECK"

code="$(curl -sS -o /tmp/optim_noref.json -w '%{http_code}' "$BFF_URL/transporteur/commandes/$REF2/optimisation" -H "Authorization: Bearer $Z_TOKEN")"
[ "$code" = "409" ] || fail "Attendu 409, reçu $code" "$(cat /tmp/optim_noref.json | head -c 300)"
[ "$(jq -r '.code' /tmp/optim_noref.json)" = "order.optimize_no_reference_point" ] \
  || fail "Mauvais code d'erreur" "$(cat /tmp/optim_noref.json)"
pass "Sans point de dépose : refus explicite (409 order.optimize_no_reference_point), pas une liste vide"

# ── Ménage : annuler toutes les courses de test ────────────────────────────
for u in "$REF" "$NEAR" "$MID" "$FAR" "$TARGETED" "$REF2"; do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true
done

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Optimisation de parcours : proche apparaît, loin et ciblée non,"
echo "   triée par distance, verrou d'acceptation intact, refus explicite"
echo "   sans point de dépose."
echo "════════════════════════════════════════════════════════════════"
