#!/usr/bin/env bash
#
# La bascule du géocodage vers echango-geo, éprouvée SANS monter tout le BFF.
#
# ── Pourquoi ce check à part de test-geocodage.sh ─────────────────────────
#
# `test-geocodage.sh` passe par le vrai chemin commerçant (session, route
# `/commercant/geocodage*`) : il faut le BFF, Fleetbase et Postgres debout.
# Celui-ci pilote directement `GeocodingService` compilé contre une instance
# echango-geo — c'est la frontière BFF → echango-geo, et rien d'autre.
# Utile quand on veut valider la classe sans provisionner un commerçant.
#
# ── Ce qu'il vérifie ─────────────────────────────────────────────────────
#
#   • une adresse connue ressort décomposée (street / city / province / DZ) ;
#   • une recherche sans résultat rend [], jamais une exception ;
#   • un point en mer rend coords + champs vides (200), pas d'erreur ;
#   • echango-geo injoignable → search ET reverse lèvent 503
#     `geocoding.unavailable`, JAMAIS un Place à libellé vide ; `ping()` rend
#     `reachable:false` sans lever.
#
# ── Usage ────────────────────────────────────────────────────────────────
#
#   ./scripts/check-geo-bascule.sh
#
#   GEO_SERVICE_URL    instance echango-geo (défaut http://localhost:3000)
#   GEO_INTERNAL_TOKEN jeton X-Internal-Token (obligatoire côté echango-geo)
#   GEOCODING_COUNTRY  pays transmis (défaut dz)
#
# Prérequis : `npm run build` dans backend/bff (le check charge dist/), et une
# instance echango-geo joignable avec son extrait importé.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BFF="$HERE/../backend/bff"
SVC="$BFF/dist/common/geocoding/geocoding.service.js"

export GEO_SERVICE_URL="${GEO_SERVICE_URL:-http://localhost:3000}"
export GEO_INTERNAL_TOKEN="${GEO_INTERNAL_TOKEN:-}"
export GEOCODING_COUNTRY="${GEOCODING_COUNTRY:-dz}"

[ -f "$SVC" ] || { echo "❌ $SVC absent — lancer 'npm run build' dans backend/bff"; exit 2; }
[ -n "$GEO_INTERNAL_TOKEN" ] || { echo "❌ GEO_INTERNAL_TOKEN requis"; exit 2; }

echo "echango-geo : $GEO_SERVICE_URL"

SVC_PATH="$SVC" node -e '
const { GeocodingService } = require(process.env.SVC_PATH);
let ok = 0, ko = 0;
const t = (c, m) => { c ? (ok++, console.log("  ✅ " + m)) : (ko++, console.log("  ❌ " + m)); };

(async () => {
  const s = new GeocodingService();

  const r = await s.search("Rue Didouche Mourad Alger", 2);
  t(Array.isArray(r) && r.length > 0, "search rend au moins un résultat");
  const p = r[0] || {};
  t(!!p.street,   "  street décomposé : " + p.street);
  t(!!p.city,     "  city : " + p.city);
  t(!!p.province, "  province : " + p.province);
  t(p.country === "DZ", "  country = DZ");

  t((await s.search("zzzzzzzzzzzz introuvable")).length === 0, "recherche absurde => [] (jamais une erreur)");

  t(!!(await s.reverse(36.7538, 3.0588)).label, "reverse terre : label non vide");
  const sea = await s.reverse(30, -40);
  t(sea.label === "" && sea.latitude === 30 && sea.longitude === -40, "reverse mer : coords + champs vides, 200");

  t((await s.ping()).reachable === true, "ping => reachable:true");

  process.env.GEO_SERVICE_URL = "http://127.0.0.1:59998";
  const dead = new GeocodingService();
  try { await dead.search("alger centre"); t(false, "panne search : aurait dû lever"); }
  catch (e) { t(e.getStatus?.() === 503 && e.getResponse().code === "geocoding.unavailable", "panne search => 503 geocoding.unavailable"); }
  try { await dead.reverse(36.75, 3.05); t(false, "panne reverse : aurait dû lever (jamais un 200 vide)"); }
  catch (e) { t(e.getStatus?.() === 503 && e.getResponse().code === "geocoding.unavailable", "panne reverse => 503 geocoding.unavailable"); }
  t((await dead.ping()).reachable === false, "panne ping => reachable:false (ne lève pas)");

  console.log("\n  " + ok + " ok, " + ko + " KO");
  process.exit(ko ? 1 : 0);
})().catch(e => { console.error(e); process.exit(2); });
'
