#!/usr/bin/env bash
# La wilaya traverse-t-elle la chaîne, et survit-elle à une duplication ?
#
#   ./scripts/test-wilaya.sh
#   EMAIL=x@y.z ./scripts/test-wilaya.sh    # réutilise un commerçant validé
#
# ── Pourquoi ce scénario existe (02/08/2026) ────────────────────────────────
#
# La wilaya porte le filtre du transporteur (décision du 02/08/2026 : « le
# transporteur choisit ce qu'il voit, wilaya d'abord »). Une course qui ne la
# transporte pas est **invisible** à qui filtre — et rien ne le signale : pas
# d'erreur, pas de journal, une liste simplement plus courte.
#
# C'est le mode de défaut le plus coûteux de ce dépôt, celui qu'on ne voit qu'en
# le cherchant.
#
# ── Ce que ce scénario vérifie, et que les autres ne peuvent pas ────────────
#
#   1. **Le champ est HONORÉ** — témoin obligatoire. Fleetbase abandonne un
#      champ inconnu **sans rien dire** : une course créée avec la wilaya et une
#      créée sans doivent différer. Si les deux rendent la même chose, le champ
#      est ignoré, et un `province` accepté sans effet aurait exactement la même
#      apparence qu'un `province` stocké.
#
#   2. **Les DEUX points la portent** — enlèvement et livraison. Le premier
#      était branché et vérifié ; le second ne l'avait jamais été.
#
#   3. **Elle survit à une duplication.** Le modèle de reprise restaurait le
#      point et le nom mais **ni la commune, ni le quartier, ni la wilaya**
#      (corrigé le 02/08/2026). C'est le troisième champ que ce chemin perdait
#      en silence, après `podMethod`/`preferFavourites` et la quantité de colis.
#      Une copie sans wilaya serait invisible au filtre, alors que l'originale
#      ne l'était pas.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/fleetbase.sh"

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
# ⚠️ **Email STABLE, pas aléatoire.** L'inscription est plafonnée à dix par
# heure et la suite en consomme déjà huit. Un email tiré au hasard ferait
# consommer une inscription **à chaque exécution** ; un email stable n'en coûte
# qu'à la première, puisqu'on tente la connexion avant d'inscrire.
EMAIL="${EMAIL:-wilaya-parcours@echango.local}"

WILAYA_PICKUP="${WILAYA_PICKUP:-Alger}"
WILAYA_DROPOFF="${WILAYA_DROPOFF:-Blida}"

command -v jq >/dev/null 2>&1 || { echo "❌ jq requis." >&2; exit 1; }

pass() { echo "✅ $1"; }
info() { echo "   $1"; }
step() { echo; echo "── $1 ──"; }
fail() { echo "❌ $1" >&2; [ -n "${2:-}" ] && echo "   Réponse : $2" >&2; exit 1; }
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

# ── 0. Un commerçant utilisable ─────────────────────────────────────────────

step "0. Le commerçant"

login() {
  curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$1" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
    | jq -r '.token // empty'
}

TOKEN="$(login "$EMAIL")"
if [ -z "$TOKEN" ]; then
  reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
       '{email:$e, password:$p, businessName:("Commerce Wilaya " + $e), phone:"0550000000"}')")"
  status="$(tail -n1 <<<"$reg")"
  [ "$status" = "403" ] || fail "Inscription : refus inattendu (HTTP $status)" "$(sed '$d' <<<"$reg")"
  fb_activate_vendor_by_email "$EMAIL" || fail "Activation impossible : ${FLEETBASE_ERROR:-}"
  TOKEN="$(login "$EMAIL")"
fi
[ -n "$TOKEN" ] || fail "Connexion commerçant refusée (plafond de 5/minute ?)"
pass "Commerçant : $EMAIL"

mapi() { # méthode chemin [corps]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $TOKEN"
  fi
}

# Crée une course, avec ou sans wilaya, et rend son identifiant.
create_order() { # avec_wilaya(0|1) -> id sur stdout
  local body out id
  body="$(jq -n --arg wp "$WILAYA_PICKUP" --arg wd "$WILAYA_DROPOFF" --argjson with "$1" '{
    draft: true,
    pickupLocationName: "Dépôt Wilaya", pickupLatitude: 36.7719, pickupLongitude: 3.0589,
    pickupContactName: "Commerce", pickupContactPhone: "0551020304",
    pickupCity: "Alger",
    dropoffLocationName: "Client Wilaya", dropoffLatitude: 36.4703, dropoffLongitude: 2.8277,
    dropoffContactName: "Destinataire", dropoffContactPhone: "0551020305",
    dropoffCity: "Blida",
    podMethod: "aucune" }
    + (if $with == 1 then {pickupProvince: $wp, dropoffProvince: $wd} else {} end)')"
  out="$(mapi POST /commercant/commandes "$body")"
  is_error <<<"$out" && fail "Création refusée" "$out"
  id="$(jq -r '.id // empty' <<<"$out")"
  [ -n "$id" ] || fail "Course créée sans identifiant" "$out"
  printf '%s' "$id"
}

# Wilaya réellement stockée, relue chez Fleetbase.
read_province() { # id côté(pickup|dropoff) -> valeur ou vide
  mapi GET "/commercant/commandes/$1" | jq -r ".payload.$2.province // empty"
}

# ── 1. Le champ est-il honoré ? ─────────────────────────────────────────────

step "1. Témoin — le champ est-il honoré, ou abandonné en silence ?"

WITH="$(create_order 1)"
WITHOUT="$(create_order 0)"

with_pickup="$(read_province "$WITH" pickup)"
without_pickup="$(read_province "$WITHOUT" pickup)"

info "avec wilaya    → « ${with_pickup:-∅} »"
info "sans wilaya    → « ${without_pickup:-∅} »"

# ⚠️ **Le témoin fait tout le travail.** Une égalité de casse ne suffirait pas :
# Fleetbase renvoie les libellés en MAJUSCULES, donc on compare sans casse.
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }

[ -n "$with_pickup" ] \
  || fail "La wilaya envoyée n'est PAS stockée — le champ est ignoré, et une
   course créée depuis l'application n'aurait rien à offrir au filtre."
[ "$(lower "$with_pickup")" = "$(lower "$WILAYA_PICKUP")" ] \
  || fail "Wilaya stockée « $with_pickup », envoyée « $WILAYA_PICKUP »"
[ -z "$without_pickup" ] \
  || fail "La course SANS wilaya en porte une (« $without_pickup ») — le témoin
   ne distingue donc rien, et le contrôle ci-dessus ne prouve rien."

pass "Le champ est honoré : présent quand on l'envoie, absent sinon"

# ── 2. Les deux points ──────────────────────────────────────────────────────

step "2. Enlèvement ET livraison"

with_dropoff="$(read_province "$WITH" dropoff)"
[ "$(lower "$with_dropoff")" = "$(lower "$WILAYA_DROPOFF")" ] \
  || fail "Wilaya de livraison attendue « $WILAYA_DROPOFF », lue « ${with_dropoff:-∅} »"

# Deux wilayas différentes, délibérément : si le service recopiait celle de
# l'enlèvement sur la livraison, un contrôle à valeur unique passerait au vert.
[ "$(lower "$with_pickup")" != "$(lower "$with_dropoff")" ] \
  || fail "Les deux points portent la même wilaya alors que deux ont été
   envoyées — le contrôle ne distinguerait pas une recopie."

pass "Enlèvement « $with_pickup », livraison « $with_dropoff » — distinctes"

# ── 3. La duplication ───────────────────────────────────────────────────────

step "3. Une copie garde-t-elle la wilaya ?"

template="$(mapi GET "/commercant/commandes/$WITH/modele")"
is_error <<<"$template" && fail "Modèle de reprise refusé" "$template"

tpl_pickup="$(jq -r '.pickupProvince // empty' <<<"$template")"
tpl_dropoff="$(jq -r '.dropoffProvince // empty' <<<"$template")"
[ -n "$tpl_pickup" ] && [ -n "$tpl_dropoff" ] \
  || fail "Le modèle de reprise ne rend pas la wilaya (enlèvement « ${tpl_pickup:-∅} »,
   livraison « ${tpl_dropoff:-∅} ») — une course dupliquée serait invisible au
   filtre, alors que l'originale ne l'était pas." "$(jq -c '.' <<<"$template")"

# La copie est créée **depuis le modèle**, comme le fait l'écran : c'est le seul
# moyen de vérifier que rien ne se perd entre les deux.
copy_body="$(jq -n --argjson t "$template" '$t + {draft: true}
  | with_entries(select(.value != null))')"
copy="$(mapi POST /commercant/commandes "$copy_body")"
is_error <<<"$copy" && fail "Création de la copie refusée" "$copy"
COPY="$(jq -r '.id // empty' <<<"$copy")"
[ -n "$COPY" ] || fail "Copie créée sans identifiant" "$copy"

copy_pickup="$(read_province "$COPY" pickup)"
copy_dropoff="$(read_province "$COPY" dropoff)"
[ "$(lower "$copy_pickup")" = "$(lower "$with_pickup")" ] \
  || fail "La copie a perdu la wilaya d'enlèvement : « ${copy_pickup:-∅} » au lieu de « $with_pickup »"
[ "$(lower "$copy_dropoff")" = "$(lower "$with_dropoff")" ] \
  || fail "La copie a perdu la wilaya de livraison : « ${copy_dropoff:-∅} » au lieu de « $with_dropoff »"

pass "La copie garde les deux wilayas"

# ⚠️ **Le témoin de la duplication, sans lequel le contrôle ci-dessus ne prouve
# rien.** Une copie qui porterait la wilaya **quoi qu'il arrive** — recopiée
# d'ailleurs, ou fabriquée — passerait exactement le même contrôle. On duplique
# donc aussi la course créée SANS wilaya : sa copie ne doit en porter aucune.
#
# C'est la leçon la plus répétée de ce dépôt : un contrôle qui n'a jamais dit
# non n'a montré que sa capacité à dire oui. Ici il la dit dans le même passage,
# sur la même mécanique — il n'y a donc rien à orchestrer pour l'éprouver.
tpl_without="$(mapi GET "/commercant/commandes/$WITHOUT/modele")"
is_error <<<"$tpl_without" && fail "Modèle de la course témoin refusé" "$tpl_without"

copy_without_body="$(jq -n --argjson t "$tpl_without" '$t + {draft: true}
  | with_entries(select(.value != null))')"
copy_without="$(mapi POST /commercant/commandes "$copy_without_body")"
is_error <<<"$copy_without" && fail "Création de la copie témoin refusée" "$copy_without"
COPY_WITHOUT="$(jq -r '.id // empty' <<<"$copy_without")"
[ -n "$COPY_WITHOUT" ] || fail "Copie témoin créée sans identifiant" "$copy_without"

for side in pickup dropoff; do
  v="$(read_province "$COPY_WITHOUT" "$side")"
  [ -z "$v" ] \
    || fail "La copie d'une course SANS wilaya en porte une côté $side (« $v ») —
   la duplication fabrique donc une valeur, et le contrôle précédent ne
   distinguait rien."
done

pass "Témoin : la copie d'une course sans wilaya n'en porte aucune"

echo
echo "════════════════════════════════════════════════════════════════"
pass "La wilaya traverse la chaîne."
echo "   témoin       → présente quand on l'envoie, absente sinon"
echo "   deux points  → enlèvement « $with_pickup », livraison « $with_dropoff »"
echo "   duplication  → conservée, des deux côtés"
