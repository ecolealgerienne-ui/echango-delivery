#!/usr/bin/env bash
#
# Fiche client géolocalisée — lien de localisation, portée plateforme,
# confirmation avant écrasement (`docs/specs_localisation_client_et_optimisation_parcours.md` §1).
#
# ── Ce que ce banc éprouve ─────────────────────────────────────────────────
#
#   • un lien généré est utilisable UNE fois — la seconde tentative est
#     refusée (`client.link_already_used`) ;
#   • un lien EXPIRÉ (au-delà des 10 minutes) est refusé
#     (`client.link_expired`) — backdaté directement en base, pas attendu ;
#   • un second commerçant (B) qui interroge le même numéro voit la fiche
#     posée par le premier (A) — preuve de la portée PLATEFORME (§1.3) ;
#   • une position soumise sur une fiche déjà pourvue n'écrase RIEN tant
#     qu'aucune confirmation explicite n'a eu lieu (témoin négatif, §1.4),
#     puis la confirmation l'applique réellement ;
#   • la page publique ne renvoie aucune donnée commerçant/commande — même
#     discipline que `test-frontiere-projection.sh`.
#
# ── Usage ───────────────────────────────────────────────────────────────────
#
#   ./scripts/test-fiche-client.sh
#
#   MERCHANT_A / MERCHANT_B  commerçants validés (défauts ci-dessous)
#   PGC / PGUSER / PGDB      conteneur et identifiants Postgres (backdatage
#                            de l'expiration — mêmes défauts que
#                            suspend-account.sh)

set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
MERCHANT_A="${MERCHANT_A:-app-parcours-commercant@echango.local}"
MERCHANT_B="${MERCHANT_B:-appartenance-commercant-b@echango.local}"

PGC="${PGC:-echango_bff_postgres}"
PGUSER_="${PGUSER:-bff_user}"
PGDB_="${PGDB:-echango_bff}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

. "$(dirname "$0")/lib/fleetbase.sh"

login_merchant() { # email -> token sur stdout
  fb_activate_vendor_by_email "$1" >/dev/null 2>&1 || true
  curl -sS -X POST "$BFF_URL/auth/merchant/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e, password:$p}')" | jq -r '.token // empty'
}

psql_() { docker exec "$PGC" psql -U "$PGUSER_" -d "$PGDB_" -tAc "$1"; }

capi() { # method path token [body]
  local m="$1" p="$2" tok="$3" b="${4:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' -H "Authorization: Bearer $tok" -d "$b"
  else
    curl -sS -X "$m" -H "Authorization: Bearer $tok" "$BFF_URL$p"
  fi
}

# Extrait le token depuis l'URL du lien (dernier segment du chemin).
token_of() { echo "${1##*/}"; }

echo "════════════════════════════════════════════════════════════════"
echo "  Fiche client géolocalisée — lien à usage unique, portée plateforme"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
TA="$(login_merchant "$MERCHANT_A")"; [ -n "$TA" ] || fail "Commerçant A ($MERCHANT_A)"
TB="$(login_merchant "$MERCHANT_B")"; [ -n "$TB" ] || fail "Commerçant B ($MERCHANT_B)"
pass "Deux commerçants connectés (A, B)"

# Numéros distinctifs à cette exécution, pour ne pas hériter d'une fiche
# laissée par un run précédent — l'horodatage évite toute collision.
SUFFIX="$(date +%s | tail -c 6)"
PHONE1="0555${SUFFIX}1"
PHONE2="0555${SUFFIX}2"
[ "${#PHONE1}" -eq 10 ] || fail "Numéro de test mal formé" "$PHONE1"

step "Lien généré, utilisé UNE fois, refusé à la seconde tentative"
LINK1="$(capi POST "/commercant/clients/$PHONE1/lien-position" "$TA")"
URL1="$(echo "$LINK1" | jq -r '.url // empty')"
[ -n "$URL1" ] || fail "Génération du lien impossible" "$LINK1"
TOKEN1="$(token_of "$URL1")"
pass "Lien généré pour $PHONE1 (token ${TOKEN1:0:8}…)"

PAGE1="$(curl -sS "$BFF_URL/public/localisation/$TOKEN1")"
echo "$PAGE1" | grep -qi "Partager ma position" || fail "La page publique ne montre pas le formulaire attendu"
pass "Page publique : formulaire affiché"

SUBMIT1="$(curl -sS -X POST "$BFF_URL/public/localisation/$TOKEN1" \
  -H 'Content-Type: application/json' -d '{"lat":36.7538,"lng":3.0588}')"
[ "$(echo "$SUBMIT1" | jq -r '.applied // empty')" = "true" ] || fail "Première soumission refusée alors qu'aucune position n'existait" "$SUBMIT1"
pass "Première soumission appliquée directement (aucune position préexistante)"

SUBMIT1_AGAIN="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BFF_URL/public/localisation/$TOKEN1" \
  -H 'Content-Type: application/json' -d '{"lat":36.76,"lng":3.06}')"
[ "$SUBMIT1_AGAIN" = "409" ] || fail "La seconde soumission sur le même lien aurait dû être refusée (409 attendu)" "HTTP $SUBMIT1_AGAIN"
pass "Lien à usage unique : la seconde soumission est refusée"

step "Portée PLATEFORME : le commerçant B voit la fiche posée via A"
LOOKUP_B="$(capi GET "/commercant/clients/$PHONE1" "$TB")"
[ "$(echo "$LOOKUP_B" | jq -r '.found')" = "true" ] || fail "Le commerçant B ne voit pas la fiche créée via A" "$LOOKUP_B"
LAT_B="$(echo "$LOOKUP_B" | jq -r '.latitude')"
[ "$LAT_B" = "36.7538" ] || fail "Latitude inattendue côté B" "$LOOKUP_B"
pass "B voit la fiche de A (latitude=$LAT_B) — portée plateforme confirmée"

step "Lien EXPIRÉ (backdaté) → refusé"
LINK2="$(capi POST "/commercant/clients/$PHONE2/lien-position" "$TA")"
URL2="$(echo "$LINK2" | jq -r '.url // empty')"
[ -n "$URL2" ] || fail "Génération du second lien impossible" "$LINK2"
TOKEN2="$(token_of "$URL2")"

if ! docker exec "$PGC" true >/dev/null 2>&1; then
  echo "   ⚠️  Conteneur Postgres ($PGC) injoignable — étape d'expiration ignorée."
else
  UPDATED="$(psql_ "UPDATE \"ClientLocationLink\" SET \"expiresAt\" = now() - interval '1 minute' WHERE token = '$TOKEN2';" 2>&1)"
  ROWS="$(psql_ "SELECT count(*) FROM \"ClientLocationLink\" WHERE token = '$TOKEN2' AND \"expiresAt\" < now();" 2>&1)"
  [ "$ROWS" = "1" ] || fail "Le backdatage n'a pas pris effet — l'essai ne prouve RIEN" "$UPDATED"

  PAGE2="$(curl -sS "$BFF_URL/public/localisation/$TOKEN2")"
  echo "$PAGE2" | grep -qi "expir" || fail "La page publique ne montre pas l'état « expiré » attendu"

  CODE2="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$BFF_URL/public/localisation/$TOKEN2" \
    -H 'Content-Type: application/json' -d '{"lat":36.75,"lng":3.05}')"
  [ "$CODE2" = "409" ] || fail "Soumission sur un lien expiré aurait dû être refusée (409 attendu)" "HTTP $CODE2"
  pass "Lien expiré : page et soumission refusées"
fi

step "Nouvelle position sur une fiche déjà pourvue : PAS d'écrasement silencieux"
LINK1B="$(capi POST "/commercant/clients/$PHONE1/lien-position" "$TA")"
URL1B="$(echo "$LINK1B" | jq -r '.url // empty')"
[ -n "$URL1B" ] || fail "Génération du lien de mise à jour impossible" "$LINK1B"
TOKEN1B="$(token_of "$URL1B")"

# Pas de zéros de fin : Postgres/Prisma renvoie le nombre JSON normalisé
# (36.8, pas 36.8000) — comparer à "36.8000" échouerait sur une valeur pourtant
# correcte, même défaut que le piège `// empty` ci-dessus (une conclusion
# fausse tirée d'un test mal écrit, pas du code testé).
NEWLAT="36.8"; NEWLNG="3.08"
SUBMIT1B="$(curl -sS -X POST "$BFF_URL/public/localisation/$TOKEN1B" \
  -H 'Content-Type: application/json' -d "{\"lat\":$NEWLAT,\"lng\":$NEWLNG}")"

# ⚠️ Pas de `// empty` ici : en jq, `false // empty` rend `empty` (false est
# « faux » pour l'opérateur `//`, au même titre que `null`) — cette copie a
# fait échouer le témoin sur une réponse pourtant correcte (piège déjà
# documenté ailleurs dans ce dépôt pour `null`).
[ "$(echo "$SUBMIT1B" | jq -r '.applied')" = "false" ] || fail "La nouvelle position aurait dû être mise EN ATTENTE, pas appliquée" "$SUBMIT1B"
pass "Nouvelle position posée en attente (applied:false)"

LOOKUP_PENDING="$(capi GET "/commercant/clients/$PHONE1" "$TA")"
LAT_STILL_OLD="$(echo "$LOOKUP_PENDING" | jq -r '.latitude')"
[ "$LAT_STILL_OLD" = "36.7538" ] || fail "TÉMOIN NÉGATIF ÉCHOUÉ — la fiche a été écrasée sans confirmation" "$LOOKUP_PENDING"
PENDING_LAT="$(echo "$LOOKUP_PENDING" | jq -r '.pending.latitude // empty')"
[ "$PENDING_LAT" = "$NEWLAT" ] || fail "La proposition en attente n'est pas visible dans la fiche" "$LOOKUP_PENDING"
pass "Témoin négatif : l'ancienne position tient, la nouvelle est visible en attente"

step "Confirmation : la nouvelle position s'applique réellement"
CONFIRM="$(capi POST "/commercant/clients/$PHONE1/confirmer" "$TB")"
echo "$CONFIRM" | jq -e '.confirmed == true' >/dev/null || fail "La confirmation a échoué" "$CONFIRM"
LOOKUP_AFTER="$(capi GET "/commercant/clients/$PHONE1" "$TA")"
LAT_AFTER="$(echo "$LOOKUP_AFTER" | jq -r '.latitude')"
[ "$LAT_AFTER" = "$NEWLAT" ] || fail "La position n'a pas été appliquée après confirmation" "$LOOKUP_AFTER"

# Même piège que ci-dessus : `null // empty` rend aussi `empty` en jq.
[ "$(echo "$LOOKUP_AFTER" | jq -r '.pending')" = "null" ] || fail "La proposition en attente n'a pas été vidée après confirmation" "$LOOKUP_AFTER"
pass "Confirmée par B (portée plateforme), appliquée pour tous — latitude=$LAT_AFTER"

step "Frontière de projection : la page publique ne renvoie aucune donnée métier"
echo "$PAGE1" | grep -qi "$MERCHANT_A" && fail "La page publique mentionne l'identité du commerçant"

# ⚠️ Pas le mot « commande » nu : la page dit légitimement, en clair et pour
# tout le monde, « un commerçant a besoin de votre position pour livrer votre
# commande » (§1.2) — c'est une explication générique, pas « le contenu de la
# commande » que §1.8 interdit (identifiant, prix, adresse). Ne chercher que
# des formes qui identifieraient VRAIMENT une commande ou une donnée métier.
echo "$PAGE1" | grep -qi "fleetbaseOrderId\|order_[a-z0-9]" && fail "La page publique porte une trace de commande"
pass "Aucune donnée commerçant/commande sur la page publique"

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ Fiche client : lien à usage unique, portée plateforme, et"
echo "   confirmation avant écrasement — tous vérifiés avec témoin négatif."
echo "════════════════════════════════════════════════════════════════"
