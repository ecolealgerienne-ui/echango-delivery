#!/usr/bin/env bash
#
# Le filtre WILAYA côté conducteur : la course hors-wilaya est-elle CACHÉE ?
#
# ── Ce que ce banc éprouve, et ce que test-wilaya.sh ne posait pas ────────────
#
# `test-wilaya.sh` prouve que la wilaya **traverse** la chaîne et **survit** à une
# duplication — sa persistance. Il ne joue **jamais** le filtre : il ne connecte
# aucun conducteur pour vérifier qu'une course hors de sa wilaya lui est bien
# **invisible**. Or c'est là qu'est le risque le plus redouté du dépôt : une
# liste plus courte, sans erreur ni journal, est indiscernable d'une panne
# (règle 10). Le filtre vit dans `zoneAllowsPickup`, éprouvé en unitaire — jamais
# de bout en bout, conducteur connecté.
#
# ── Témoin positif ET négatif, dans les deux sens (règle 8) ───────────────────
#
# « Le conducteur ne voit pas la course de Blida » ne prouve rien seul : un
# filtre qui cache tout passerait. On vérifie donc, symétriquement :
#
#   • zone vide      → les DEUX courses (Alger, Blida) sont visibles ;
#   • wilaya = Alger → Alger visible, Blida CACHÉE ;
#   • wilaya = Blida → Blida visible, Alger CACHÉE.
#
# La symétrie prouve que le filtre décide sur la valeur DÉCLARÉE, pas sur
# l'identité d'une course. Le rayon est retiré (`radiusKm:null`) pour isoler la
# wilaya — sans quoi la position du conducteur brouillerait le témoin.
#
# ── Usage ─────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-filtre-wilaya.sh

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
dapi() { local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $Z_TOKEN" -d "$b"
  else curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $Z_TOKEN"; fi; }

free_z() { for u in $(fb_get "/int/v1/orders?limit=100" | jq -r --arg d "$Z_UUID" '[.orders[]? | select(.driver_assigned_uuid==$d and (.status|IN("completed","canceled","cancelled")|not))][].uuid'); do
  fb_api PUT "/int/v1/orders/$u" '{"order":{"status":"canceled","driver_assigned_uuid":null}}' >/dev/null 2>&1 || true; done; }

# Publie une course DIFFUSÉE avec la wilaya d'enlèvement voulue. -> fleetbaseOrderId
publish_bc() { # province
  local o uuid
  o="$(mapi POST /commercant/commandes "$(jq -n --arg p "$1" '{
    draft:true,
    pickupLocationName:"Dépôt Wilaya", pickupLatitude:36.7719, pickupLongitude:3.0589,
    pickupContactName:"Commerce", pickupContactPhone:"0551020304", pickupProvince:$p,
    dropoffLocationName:"Client", dropoffLatitude:36.7500, dropoffLongitude:3.0600,
    dropoffContactName:"Destinataire", dropoffContactPhone:"0551020305",
    items:[{description:"colis", quantity:1}], price:600, podMethod:"aucune" }')")"
  uuid="$(echo "$o" | jq -r '.fleetbaseOrderId // empty')"
  [ -n "$uuid" ] || { echo "ERR:$(echo "$o" | head -c 200)"; return 1; }
  mapi POST "/commercant/commandes/$uuid/publier" >/dev/null
  echo "$uuid"
}

set_zone() { # wilaya_json  (ex: '"Alger"' ou 'null')
  dapi PUT /transporteur/zone "$(jq -nc --argjson w "$1" '{wilaya:$w, radiusKm:null}')" >/dev/null; }

# La course d'uuid $1 est-elle dans la liste diffusée du conducteur ? yes/no
#
# ⚠️ **PAS de `limit` ici** : `ListDriverOrdersQueryDto` ne porte que `type`
# (route non paginée). Un `?limit=…` est un champ hors DTO, REFUSÉ par
# `forbidNonWhitelisted` en 400 — et une lecture naïve prendrait ce refus pour
# une liste vide. Le piège qui a coûté une fausse piste « liste vide » le 04/08.
adhoc_has() { # uuid
  dapi GET "/transporteur/commandes?type=adhoc" \
    | jq -e --arg o "$1" '[.orders[]?.uuid] | index($o)' >/dev/null 2>&1 && echo yes || echo no; }

echo "════════════════════════════════════════════════════════════════"
echo "  Filtre wilaya côté conducteur — la course hors-wilaya est cachée"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
fb_activate_vendor_by_email "$MERCHANT" >/dev/null 2>&1 || true
MERCHANT_TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant impossible"
mapfile -t DRV < <(_accounted_driver_uuids)
# ⚠️ Choisir un conducteur CONNECTABLE, pas le premier venu : `_accounted…` est
# non déterministe et certains comptes de test portent un mot de passe qui n'est
# pas le nôtre (ex. `argent-…@test.dz`). On sonde le jeton par un appel réel
# plutôt que de se fier au code de retour d'`obtain_driver_token` — un 401
# silencieux ferait passer une liste refusée pour une liste vide.
Z_UUID=""; Z_TOKEN=""
for d in "${DRV[@]}"; do
  obtain_driver_token "$d" >/dev/null 2>&1 || true
  [ -n "${DRIVER_TOKEN:-}" ] || continue
  code="$(curl -sS -o /dev/null -w '%{http_code}' "$BFF_URL/transporteur/profil" -H "Authorization: Bearer $DRIVER_TOKEN")"
  if [ "$code" = "200" ]; then Z_UUID="$d"; Z_TOKEN="$DRIVER_TOKEN"; break; fi
done
[ -n "$Z_TOKEN" ] || fail "Aucun conducteur connectable parmi les comptes (mot de passe ?)"
free_z
# La zone de Z est restaurée à la fin — on ne laisse pas de réglage derrière soi.
SAVED_ZONE="$(dapi GET /transporteur/zone)"
SAVED_WILAYA="$(echo "$SAVED_ZONE" | jq -c '.wilaya // null')"
pass "Commerçant + conducteur Z (${Z_UUID:0:8}…), zone sauvegardée"

step "Deux courses diffusées : enlèvement Alger, et enlèvement Blida"
OA="$(publish_bc "Alger")"; [[ "$OA" == ERR:* ]] && fail "Publication Alger" "$OA"
OB="$(publish_bc "Blida")"; [[ "$OB" == ERR:* ]] && fail "Publication Blida" "$OB"
pass "Alger=${OA:0:8}…  Blida=${OB:0:8}…"

step "Zone vide → les DEUX sont visibles (témoin positif de départ)"
set_zone 'null'
[ "$(adhoc_has "$OA")" = "yes" ] || fail "Sans zone, la course Alger devrait être visible" "elle ne l'est pas — décor ou visibilité en cause"
[ "$(adhoc_has "$OB")" = "yes" ] || fail "Sans zone, la course Blida devrait être visible"
pass "Les deux courses visibles sans filtre"

step "wilaya = Alger → Alger visible, Blida CACHÉE"
set_zone '"Alger"'
[ "$(adhoc_has "$OA")" = "yes" ] || fail "wilaya=Alger : la course Alger a DISPARU (filtre trop large, la liste vide en silence)"
[ "$(adhoc_has "$OB")" = "no" ]  || fail "wilaya=Alger : la course Blida est visible alors qu'elle NE devrait PAS (le filtre ne filtre pas)"
pass "Alger visible, Blida cachée"

step "wilaya = Blida → Blida visible, Alger CACHÉE (symétrie)"
set_zone '"Blida"'
[ "$(adhoc_has "$OB")" = "yes" ] || fail "wilaya=Blida : la course Blida a disparu"
[ "$(adhoc_has "$OA")" = "no" ]  || fail "wilaya=Blida : la course Alger est visible alors qu'elle ne devrait pas"
pass "Blida visible, Alger cachée — le filtre décide sur la wilaya déclarée, pas l'identité"

# ── Ménage : restaurer la zone de Z, annuler les courses ────────────────────
set_zone "$SAVED_WILAYA"
mapi POST "/commercant/commandes/$OA/annuler" '{}' >/dev/null 2>&1 || true
mapi POST "/commercant/commandes/$OB/annuler" '{}' >/dev/null 2>&1 || true

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Le filtre wilaya cache la course hors-zone et montre la bonne,"
echo "   dans les deux sens — témoin positif à chaque pas."
echo "════════════════════════════════════════════════════════════════"
