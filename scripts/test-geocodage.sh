#!/usr/bin/env bash
#
# Le géocodage du BFF passe par le service transverse echango-geo (bascule du
# 05/09/2026). Ce banc éprouve la frontière BFF → echango-geo, pas Nominatim
# lui-même (celui-ci a ses propres bancs dans echango-geo/scripts/).
#
# ── Ce qu'il vérifie ──────────────────────────────────────────────────────
#
#   • une adresse connue ressort décomposée (rue / commune / wilaya / DZ) —
#     preuve que la chaîne BFF → echango-geo → Nominatim fonctionne (témoin) ;
#   • une recherche sans résultat rend { data: [] } en 200, jamais une erreur ;
#   • un point en mer rend des coordonnées et des champs vides, en 200 ;
#   • q < 3 caractères est refusé par le DTO (400) ;
#   • GEO_PANNE=1 : echango-geo coupé → /commercant/geocodage* rend 503
#     geocoding.unavailable, JAMAIS 400, et JAMAIS un 200 à libellé vide pour
#     l'inverse (c'est tout l'intérêt d'un 503 : une panne ne doit pas se lire
#     comme « point en mer »).
#
# ── Usage ────────────────────────────────────────────────────────────────────
#
#   ./scripts/test-geocodage.sh
#
#   BFF_URL         adresse du BFF (défaut http://localhost:3001)
#   EMAIL / PASSWORD  réutilise un commerçant (sinon en inscrit un — consomme
#                     le throttle d'inscription, 10/h)
#   GEO_PANNE=1      joue en plus la coupure d'echango-geo (arrête/redémarre le
#                    conteneur). Nécessite docker + GEO_COMPOSE / GEO_API_SVC.
#   GEO_COMPOSE      fichier compose d'echango-geo
#                    (défaut ../../echango-geo/docker-compose.yml)
#   GEO_API_SVC      nom du service (défaut geo-api)

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-motdepasse123}"

HERE="$(cd "$(dirname "$0")" && pwd)"
GEO_COMPOSE="${GEO_COMPOSE:-$HERE/../../echango-geo/docker-compose.yml}"
GEO_API_SVC="${GEO_API_SVC:-geo-api}"

command -v jq >/dev/null 2>&1 || { echo "❌ jq requis"; exit 1; }

. "$HERE/lib/fleetbase.sh"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✅ $1"; }
ko()   { fail=$((fail+1)); echo "  ❌ $1"; }
step() { echo; echo "── $1 ──"; }

# api <method> <path>  → remplit $HTTP (code) et $BODY (corps).
#
# ⚠️ Passe par des variables globales, PAS par la sortie standard : appelé en
# `body="$(api …)"`, il tournerait dans un sous-shell et le code HTTP capturé
# n'en ressortirait jamais — tous les tests de `$HTTP` compareraient "" à "200".
HTTP=""; BODY=""
api() {
  local out
  out="$(curl -sS -m 20 -w $'\n%{http_code}' -X "$1" "$BFF_URL$2" \
    -H "Authorization: Bearer $TOKEN")"
  HTTP="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

echo "BFF : $BFF_URL"

# ── Session commerçant ──────────────────────────────────────────────────────
#
# Le BFF crée le Vendor Fleetbase en attente : l'inscription renvoie 403
# `merchant_pending` (jamais un token) tant qu'un admin ne l'a pas activé. Tous
# les autres bancs passent par `fb_activate_vendor_by_email` (clé de service) ;
# celui-ci faisait exception et ne dépassait donc jamais la porte — la raison
# pour laquelle il n'avait jamais tourné.
step "session commerçant"
if [ -z "$EMAIL" ]; then
  EMAIL="geo-test-$RANDOM@echango.local"
  curl -sS -o /dev/null -X POST "$BFF_URL/auth/merchant/register" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
      '{email:$e,password:$p,businessName:"Geo Test",firstName:"Geo",lastName:"Test",phone:"+213555000111"}')"
  ok "commerçant inscrit ($EMAIL)"
fi
fb_activate_vendor_by_email "$EMAIL" >/dev/null 2>&1 || true
TOKEN="$(curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')" | jq -r '.token // empty')"
[ -n "$TOKEN" ] || { echo "❌ session commerçant impossible ($EMAIL)"; exit 1; }
ok "commerçant connecté ($EMAIL)"

# ── Témoin : la chaîne complète répond ────────────────────────────────────
step "témoin — recherche sans résultat"
api GET "/commercant/geocodage?q=zzzzzzzzzzzz+introuvable"
[ "$HTTP" = "200" ] && ok "200 sur requête absurde" || ko "attendu 200, obtenu $HTTP"
[ "$(echo "$BODY" | jq -r '.data | length')" = "0" ] && ok "{ data: [] }, pas une erreur" || ko "data non vide : $BODY"

# ── Recherche d'une adresse connue, décomposée ────────────────────────────
step "recherche — adresse algérienne connue"
api GET "/commercant/geocodage?q=Rue+Didouche+Mourad+Alger"
[ "$HTTP" = "200" ] && ok "200" || ko "attendu 200, obtenu $HTTP"
first="$(echo "$BODY" | jq '.data[0] // empty')"
[ -n "$first" ] && ok "au moins un résultat" || ko "aucun résultat : $BODY"
[ "$(echo "$BODY" | jq -r '.data[0].street // ""')" != "" ]   && ok "street décomposé"   || ko "street vide"
[ "$(echo "$BODY" | jq -r '.data[0].city // ""')" != "" ]     && ok "city (commune)"     || ko "city vide"
[ "$(echo "$BODY" | jq -r '.data[0].province // ""')" != "" ] && ok "province (wilaya)"  || ko "province vide"
[ "$(echo "$BODY" | jq -r '.data[0].country // ""')" = "DZ" ] && ok "country = DZ (ISO-2)" || ko "country ≠ DZ"

# ── Inverse : point terrestre (témoin) puis point en mer ──────────────────
step "inverse — point terrestre"
api GET "/commercant/geocodage/inverse?lat=36.7538&lon=3.0588"
[ "$HTTP" = "200" ] && ok "200" || ko "attendu 200, obtenu $HTTP"
[ "$(echo "$BODY" | jq -r '.label // ""')" != "" ] && ok "label non vide sur terre" || ko "label vide sur terre : $BODY"

step "inverse — plein Atlantique"
api GET "/commercant/geocodage/inverse?lat=30&lon=-40"
[ "$HTTP" = "200" ] && ok "200 (jamais une erreur)" || ko "attendu 200, obtenu $HTTP"
[ "$(echo "$BODY" | jq -r '.label // "x"')" = "" ] && ok "label vide" || ko "label non vide : $BODY"
[ "$(echo "$BODY" | jq -r '.latitude')" = "30" ] && ok "coordonnées rendues telles quelles" || ko "latitude ≠ 30"

# ── Défaut gardé : q trop court ───────────────────────────────────────────
step "validation — q < 3"
api GET "/commercant/geocodage?q=ab"
[ "$HTTP" = "400" ] && ok "400" || ko "attendu 400, obtenu $HTTP"

# ── Coupure d'echango-geo (optionnel) ────────────────────────────────────
if [ "${GEO_PANNE:-}" = "1" ]; then
  step "panne echango-geo — 503, jamais 400 ni 200-vide"
  if ! command -v docker >/dev/null 2>&1; then
    ko "docker requis pour GEO_PANNE=1"
  else
    DC=(docker compose -f "$GEO_COMPOSE")
    restore() { echo "  … redémarrage $GEO_API_SVC"; "${DC[@]}" start "$GEO_API_SVC" >/dev/null 2>&1 || true; }
    trap restore EXIT
    "${DC[@]}" stop "$GEO_API_SVC" >/dev/null 2>&1 && ok "conteneur $GEO_API_SVC arrêté" || ko "arrêt $GEO_API_SVC impossible"
    sleep 2

    api GET "/commercant/geocodage?q=alger+centre"
    [ "$HTTP" = "503" ] && ok "search → 503" || ko "search : attendu 503, obtenu $HTTP"
    [ "$HTTP" = "400" ] && ko "search a rendu 400 (la requête client est valide)" || ok "pas 400"
    [ "$(echo "$BODY" | jq -r '.code // ""')" = "geocoding.unavailable" ] && ok "code geocoding.unavailable" || ko "code inattendu : $BODY"

    api GET "/commercant/geocodage/inverse?lat=36.7538&lon=3.0588"
    [ "$HTTP" = "503" ] && ok "inverse → 503 (pas un 200 à libellé vide)" || ko "inverse : attendu 503, obtenu $HTTP"
    [ "$(echo "$BODY" | jq -r '.code // ""')" = "geocoding.unavailable" ] && ok "code geocoding.unavailable" || ko "code inattendu : $BODY"

    restore; trap - EXIT
    sleep 3
    api GET "/commercant/geocodage?q=Alger"
    [ "$HTTP" = "200" ] && ok "service revenu après redémarrage" || ko "toujours $HTTP après redémarrage"
  fi
fi

echo
echo "──────────────────────────────────────────"
echo "  $pass ok, $fail échec(s)"
[ "$fail" -eq 0 ]
