#!/usr/bin/env bash
#
# Le filtre RAYON côté conducteur : la course hors du rayon du point d'ancrage
# est-elle CACHÉE ? Et sans point d'ancrage, la liste est-elle vide (pas pleine) ?
#
# ── Ce que ce banc éprouve ───────────────────────────────────────────────────
#
# Le filtre géographique des opportunités est calculé EN MÉMOIRE par le BFF
# (`pickupWithinZone` : l'enlèvement est-il à moins de `radiusKm` du point
# d'ancrage ?). ⚠️ Fleetbase ne sait PAS filtrer une liste de commandes par un
# rayon donné par requête — `GET /v1/orders?nearby` n'applique que
# `adhoc_distance` (6 km, valeur d'org), mesuré le 09/09/2026. Ce chemin n'a
# jamais été joué de bout en bout, conducteur connecté — or c'est là qu'est le
# risque le plus redouté du dépôt : une liste plus courte, sans erreur ni
# journal, est indiscernable d'une panne (règle 10).
#
# ⚠️ **Changement de sémantique depuis la wilaya** : SANS point d'ancrage, la
# liste des opportunités est **VIDE** (la wilaya absente montrait tout), et la
# réponse porte `anchorMissing: true`. L'app en fait un « posez votre point de
# base », pas une panne.
#
# ── Témoin positif ET négatif, dans les deux sens (règle 8) ──────────────────
#
#   • pas de point d'ancrage → AUCUNE des deux courses, `anchorMissing:true` ;
#   • ancre = Alger, rayon 15 → Alger visible, Blida (~45 km) CACHÉE ;
#   • ancre = Blida, rayon 15 → Blida visible, Alger CACHÉE (symétrie) ;
#   • ancre = Alger, rayon 100 → les DEUX visibles (le filtre ne cache pas tout).
#
# La symétrie prouve que le filtre décide sur la distance au point DÉCLARÉ, pas
# sur l'identité d'une course. Le contrôle positif à rayon large prouve qu'il
# n'écarte pas par défaut.
#
# ── Mutation qui doit faire ÉCHOUER ce banc (règle 8) ────────────────────────
#
#   `common/orders/driver-zone.ts` : `pickupWithinZone` → `return true;`
#   ⇒ l'étape « rayon 15 » verrait Blida (le seul filtre géographique est mort).
#
# ── Usage ───────────────────────────────────────────────────────────────────
#
#   ./scripts/test-filtre-rayon.sh

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT="${MERCHANT:-app-parcours-commercant@echango.local}"

# Alger-Centre et Blida — ~45 km, de part et d'autre d'un rayon de 15 km.
ALGER_LAT=36.7538 ; ALGER_LNG=3.0588
BLIDA_LAT=36.4703 ; BLIDA_LNG=2.8277

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
dapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $Z_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $Z_TOKEN"; fi; }

free_z() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }

# Publie une course DIFFUSÉE avec l'enlèvement aux coordonnées voulues. -> uuid
publish_bc() { # lat lng
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n --argjson lat "$1" --argjson lng "$2" '{
    draft:true,
    pickupLocationName:"Dépôt Rayon", pickupLatitude:$lat, pickupLongitude:$lng,
    pickupContactName:"Commerce", pickupContactPhone:"0551020304",
    dropoffLocationName:"Client", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"0551020305",
    items:[{description:"colis", quantity:1}], price:600, podMethod:"aucune" }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 200)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

# Pose la zone du conducteur. Args : lat lng radiusKm  — ou  "clear"
set_zone() {
  local body
  if [ "$1" = "clear" ]; then
    body='{"centerLat":null,"centerLng":null,"radiusKm":null}'
  else
    body="$(jq -nc --argjson a "$1" --argjson o "$2" --argjson r "$3" \
      '{centerLat:$a, centerLng:$o, radiusKm:$r}')"
  fi
  dapi PUT /transporteur/zone "$body" >/dev/null
}

# La course d'uuid $1 est-elle dans la liste diffusée du conducteur ? yes/no
adhoc_has() { # uuid
  dapi GET "/transporteur/commandes?type=adhoc" \
    | jq -e --arg o "$1" '[.orders[]?.uuid] | index($o)' >/dev/null 2>&1 && echo yes || echo no; }

# `anchorMissing` de la réponse adhoc.
anchor_missing() { dapi GET "/transporteur/commandes?type=adhoc" | jq -r '.anchorMissing // false'; }

echo "════════════════════════════════════════════════════════════════"
echo "  Filtre rayon côté conducteur — hors du rayon = caché ;"
echo "  pas de point d'ancrage = liste vide (pas pleine)"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
mapfile -t DRV < <(_accounted_driver_uuids)
Z_UUID=""; Z_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || true
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")"
  if [ "$code" = "200" ]; then Z_UUID="$d"; Z_TOKEN="$DRIVER_TOKEN"; break; fi
done
[ -n "$Z_TOKEN" ] || fail "Aucun conducteur connectable parmi les comptes (mot de passe ?)"
free_z
SAVED_ZONE="$(dapi GET /transporteur/zone)"
SC_LAT="$(echo "$SAVED_ZONE" | jq -c '.center.latitude // null')"
SC_LNG="$(echo "$SAVED_ZONE" | jq -c '.center.longitude // null')"
SC_R="$(echo "$SAVED_ZONE" | jq -c '.radius_km // null')"
pass "Commerçant + conducteur Z (${Z_UUID:0:8}…), zone sauvegardée"

step "Deux courses diffusées : enlèvement Alger, et enlèvement Blida (~45 km)"
OA="$(publish_bc "$ALGER_LAT" "$ALGER_LNG")"; [[ "$OA" == ERR:* ]] && fail "Publication Alger" "$OA"
OB="$(publish_bc "$BLIDA_LAT" "$BLIDA_LNG")"; [[ "$OB" == ERR:* ]] && fail "Publication Blida" "$OB"
pass "Alger=${OA:0:8}…  Blida=${OB:0:8}…"

step "Pas de point d'ancrage → AUCUNE des deux, anchorMissing:true"
set_zone clear
[ "$(anchor_missing)" = "true" ] || fail "Sans point d'ancrage, anchorMissing devrait être true" "il ne l'est pas — l'app ne saurait pas afficher le bon message"
[ "$(adhoc_has "$OA")" = "no" ] || fail "Sans point d'ancrage, aucune opportunité ne doit s'afficher (Alger visible)"
[ "$(adhoc_has "$OB")" = "no" ] || fail "Sans point d'ancrage, aucune opportunité ne doit s'afficher (Blida visible)"
pass "Liste vide + anchorMissing:true — distinct d'une panne"

step "Ancre = Alger, rayon 15 → Alger visible, Blida CACHÉE"
set_zone "$ALGER_LAT" "$ALGER_LNG" 15
[ "$(anchor_missing)" = "false" ] || fail "Avec un point d'ancrage, anchorMissing devrait être false"
[ "$(adhoc_has "$OA")" = "yes" ] || fail "rayon 15 : la course Alger a DISPARU (filtre trop large, la liste se vide en silence)"
[ "$(adhoc_has "$OB")" = "no" ]  || fail "rayon 15 : la course Blida est visible alors qu'elle NE devrait PAS (le filtre ne filtre pas)"
pass "Alger visible, Blida cachée"

step "Ancre = Blida, rayon 15 → Blida visible, Alger CACHÉE (symétrie)"
set_zone "$BLIDA_LAT" "$BLIDA_LNG" 15
[ "$(adhoc_has "$OB")" = "yes" ] || fail "ancre=Blida : la course Blida a disparu"
[ "$(adhoc_has "$OA")" = "no" ]  || fail "ancre=Blida : la course Alger est visible alors qu'elle ne devrait pas"
pass "Blida visible, Alger cachée — le filtre décide sur la distance au point déclaré"

step "Ancre = Alger, rayon 100 → les DEUX visibles (le filtre ne cache pas tout)"
set_zone "$ALGER_LAT" "$ALGER_LNG" 100
[ "$(adhoc_has "$OA")" = "yes" ] || fail "rayon 100 : la course Alger devrait être visible"
[ "$(adhoc_has "$OB")" = "yes" ] || fail "rayon 100 : la course Blida (~45 km) devrait être visible — le filtre écarte par défaut"
pass "Les deux visibles — le filtre écarte sur la distance, pas par principe"

# ── Ménage : restaurer la zone de Z, annuler les courses ────────────────────
if [ "$SC_LAT" = "null" ]; then set_zone clear
else dapi PUT /transporteur/zone "$(jq -nc --argjson a "$SC_LAT" --argjson o "$SC_LNG" --argjson r "$SC_R" '{centerLat:$a, centerLng:$o, radiusKm:$r}')" >/dev/null; fi
mapi POST "/commercant/commandes/$OA/annuler" '{}' >/dev/null 2>&1 || true
mapi POST "/commercant/commandes/$OB/annuler" '{}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le filtre rayon cache la course hors-zone et montre la bonne,"
echo "   dans les deux sens ; sans point d'ancrage, liste vide + drapeau."
echo "════════════════════════════════════════════════════════════════"
