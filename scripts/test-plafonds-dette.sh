#!/usr/bin/env bash
#
# Les deux plafonds de dette — le dernier garde-fou financier jamais éprouvé.
#
# ── Pourquoi ils comptent plus que le reste ───────────────────────────────
#
# Nous n'avons ni agence ni dépôt. Le transporteur garde les espèces, et la
# seule chose qui borne l'exposition d'un commerçant est **logicielle** : cesser
# de proposer des courses encaissées à quelqu'un qui doit déjà trop. Un plafond
# qui ne se déclenche pas ne protège rien — il fait croire qu'il protège.
#
# Aucun des deux n'avait jamais été vu refuser.
#
# ── Pourquoi DEUX plafonds, et comment les distinguer ────────────────────
#
#   * `COD_DEBT_CEILING` borne **une relation** (un couple débiteur/créancier) ;
#   * `COD_DEBT_CEILING_PER_PERSON` borne **une personne**, toutes contreparties
#     confondues. Il est né de la multi-appartenance : un conducteur rattaché à
#     trois entreprises porte trois dettes distinctes, donc trois fois le plafond
#     dans la même poche. Le garde-fou se contournait par le nombre d'adhésions.
#
# ⚠️ **Le second n'est démontrable que si le premier ne peut pas expliquer le
# refus.** Un scénario qui les laisserait à la même valeur verrait bien un refus,
# sans jamais savoir lequel a parlé — et le plafond par personne pourrait être
# mort sans que rien ne le dise. D'où trois phases, avec des valeurs **toutes
# différentes** : le message de refus nomme le plafond atteint, donc le chiffre
# qu'il cite désigne le coupable.
#
#       phase A    couple = 1000        personne = 9000000   → doit citer 1000
#       phase B    couple = 9000000     personne = 1500      → doit citer 1500
#       phase C    couple = 9000000     personne = 9000000   → doit ACCEPTER
#
# La phase C est le témoin, et elle n'est pas décorative : sans elle, « refusé »
# en A et B pourrait venir d'autre chose (course déjà prise, conducteur occupé,
# véhicule inadapté). C'est elle qui prouve que la MÊME course, par le MÊME
# conducteur, ne passait que par la faute des plafonds.
#
# ── Ce que ce script ne tranche pas ──────────────────────────────────────
#
# **Le montant réel.** 20000 est un repli, pas un arbitrage (`cash.service.ts`,
# « la valeur par défaut est un repli, pas une décision »). Ce script éprouve le
# MÉCANISME ; le chiffre se fixe au pilote, avec de vrais paniers. C'est
# précisément pour ça qu'il n'attend aucune décision produit.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-plafonds-dette.sh [conducteur]
#
#   BFF_URL=http://localhost:3001   adresse du BFF
#   GOODS=1300 FEE=650              montants joués
#
# ⚠️ Le script MODIFIE `backend/bff/.env` et redémarre le conteneur du BFF entre
# les phases — c'est la seule façon d'éprouver un seuil sans accumuler onze
# courses réelles. Le fichier est **restauré à la sortie**, y compris sur échec
# ou interruption (`trap`). Un `.env` laissé avec un plafond de 1000 rendrait
# toute course encaissée impossible et le ferait chercher longtemps.

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
GOODS="${GOODS:-1300}"
FEE="${FEE:-650}"
DRIVER_HINT="${1:-}"

COUPLE_CAP=1000
PERSON_CAP=1500
HIGH=9000000

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker requis (redémarrage du BFF)."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   Réponse : $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_PATH="$ROOT/backend/bff/.env"
BFF_CONTAINER="${BFF_CONTAINER:-echango_bff_app}"
BACKUP=""

[ -f "$ENV_PATH" ] || fail "Introuvable : $ENV_PATH (ce script doit tourner depuis le clone où vit le BFF)"

# ⚠️ Restauration par `trap`, et non en fin de script. Un `set -e` qui sort sur
# une assertion sauterait la remise en état, et laisserait un `.env` avec un
# plafond de 1000 — donc un BFF qui refuse toute course encaissée, pour une
# raison invisible à qui n'a pas lu ce fichier.
restore_env() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || return 0
  cp "$BACKUP" "$ENV_PATH"
  rm -f "$BACKUP"
  echo "   .env restauré ; redémarrage du BFF…"
  docker restart "$BFF_CONTAINER" >/dev/null 2>&1 || true
  wait_healthy || echo "   ⚠️  BFF non revenu — vérifier « docker logs $BFF_CONTAINER »"
}
trap restore_env EXIT

wait_healthy() {
  local i
  for i in $(seq 1 60); do
    if curl -sS -m 2 "$BFF_URL/health" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# Pose les deux plafonds et redémarre. `sed` sur la ligne entière, ancré en début
# de ligne : une clé commentée ne doit pas être réécrite, et une clé absente doit
# être AJOUTÉE plutôt qu'ignorée en silence.
set_ceilings() { # couple personne
  local couple="$1" person="$2" k v
  for pair in "COD_DEBT_CEILING=$couple" "COD_DEBT_CEILING_PER_PERSON=$person"; do
    k="${pair%%=*}"; v="${pair#*=}"
    if grep -qE "^[[:space:]]*$k=" "$ENV_PATH"; then
      sed -i -E "s|^[[:space:]]*$k=.*|$k=$v|" "$ENV_PATH"
    else
      printf '\n%s=%s\n' "$k" "$v" >> "$ENV_PATH"
    fi
  done

  docker restart "$BFF_CONTAINER" >/dev/null \
    || fail "Redémarrage de $BFF_CONTAINER impossible"
  wait_healthy || fail "Le BFF n'est pas revenu après redémarrage"

  # ⚠️ On vérifie le FICHIER que le conteneur lit, pas ses variables d'shell.
  #
  # Première version : `docker exec … printenv COD_DEBT_CEILING`, qui rendait
  # vide et faisait échouer le script. La valeur n'a jamais transité par
  # l'environnement Docker — le BFF lit son `.env` par `ConfigModule` de NestJS,
  # au démarrage. Le contrôle interrogeait donc une source qui n'a rien à voir
  # avec le mécanisme, et son échec n'accusait rien de réel.
  #
  # Ce contrôle-ci est une **sanité** : il dit que le fichier vu depuis le
  # conteneur porte la bonne valeur. La preuve que le BFF l'a effectivement
  # prise, elle, est ailleurs et vaut mieux — c'est le refus lui-même, qui cite
  # le plafond atteint (`expect_ceiling_refusal`). Un chiffre attendu dans un
  # message est un comportement observé, pas une configuration espérée.
  local seen
  seen="$(docker exec "$BFF_CONTAINER" sh -c "grep -E '^COD_DEBT_CEILING=' /app/.env | cut -d= -f2" 2>/dev/null | tr -d '\r\n ')"
  [ "$seen" = "$couple" ] \
    || fail "Le .env vu du conteneur porte COD_DEBT_CEILING='$seen', attendu '$couple'"

  echo "   plafonds appliqués : couple=$couple, personne=$person"
}

mapi() {
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

dapi() {
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $DRIVER_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $DRIVER_TOKEN"
  fi
}

# Un refus de plafond, ET le chiffre qu'il cite — c'est le chiffre qui désigne
# lequel des deux a parlé.
expect_ceiling_refusal() { # libellé plafond_attendu réponse
  local label="$1" cap="$2" body="$3" code msg
  echo "$body" | is_error \
    || fail "$label : la course a été ACCEPTÉE, or le plafond doit la refuser" "$(echo "$body" | jq -c '.')"
  code="$(echo "$body" | jq -r '.code // empty')"
  [ "$code" = "cash.ceiling_exceeded" ] \
    || fail "$label : refusé pour '$code', attendu 'cash.ceiling_exceeded'" "$(echo "$body" | jq -c '.')"
  msg="$(echo "$body" | jq -r '.message // empty')"
  case "$msg" in
    *"$cap"*) pass "$label — refusé, plafond $cap cité" ;;
    *) fail "$label : refusé, mais le message ne cite pas le plafond $cap — lequel a parlé ?" "$msg" ;;
  esac
}

echo "BFF : $BFF_URL   conteneur : $BFF_CONTAINER"
echo "Course encaissée : $GOODS + $FEE = $((GOODS + FEE)) à la porte."
echo "Plafonds joués : couple=$COUPLE_CAP, personne=$PERSON_CAP, large=$HIGH"

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"
. "$(dirname "$0")/lib/free-driver.sh"

SUFFIX="$(date +%s)"
EXPECTED=$((GOODS + FEE))

BACKUP="$(mktemp)"
cp "$ENV_PATH" "$BACKUP"
echo "   .env sauvegardé ($BACKUP) — restauré automatiquement à la sortie"

# ── 0. Les acteurs ─────────────────────────────────────────────────────────
step "0. Les acteurs"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"
require_free_driver

MERCHANT_EMAIL="cap-m-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Plafond", firstName:"Test",
    lastName:"Plafond", phone:"+213555000000", businessPhone:"+213555000000"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription commerçant doit être mise en attente (HTTP $status)" "$body"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" \
  || fail "Activation impossible : ${FLEETBASE_ERROR:-}"
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
MERCHANT_ID="$(echo "$mlogin" | jq -r '.user.id // empty')"
[ -n "$MERCHANT_TOKEN" ] && [ -n "$MERCHANT_ID" ] || fail "Connexion commerçant refusée" "$mlogin"
pass "Commerçant NEUF : $MERCHANT_EMAIL"

# ⚠️ Un commerçant neuf, donc une dette de couple qui part de ZÉRO. C'est ce qui
# rend la phase A lisible sans accumuler : il suffit d'un plafond inférieur au
# montant de la course. Le conducteur, lui, est réutilisé et porte les dettes
# des exécutions précédentes — la phase B en tient compte, puisqu'elle borne le
# TOTAL et que le refus ne fait que devenir plus certain.

# ── 1. Une course encaissée, publiée ───────────────────────────────────────
step "1. Une course encaissée, publiée"
order="$(mapi POST /commercant/commandes "$(jq -n \
  --argjson goods "$GOODS" --argjson fee "$FEE" '{
  pickupLocationName: "Commerce Plafond", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
  pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
  dropoffLocationName: "Client Plafond", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
  dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
  price: $fee, codAmount: $goods, codIncludesDelivery: false,
  podMethod: "aucune", preferFavourites: false, draft: true
}')")"
ORDER_ID="$(echo "$order" | jq -r '.id // .uuid // empty')"
[ -n "$ORDER_ID" ] || fail "Création refusée" "$(echo "$order" | jq -c '.')"
published="$(mapi POST "/commercant/commandes/$ORDER_ID/publier")"
echo "$published" | is_error && fail "Publication refusée" "$(echo "$published" | jq -c '.')"
FB_UUID="$(mapi GET "/commercant/commandes/$ORDER_ID" | jq -r '.uuid')"
pass "Publiée : $EXPECTED à encaisser"

# ── 2. Phase A — le plafond par COUPLE ────────────────────────────────────
step "2. Phase A : plafond par couple ($COUPLE_CAP), personne large"
set_ceilings "$COUPLE_CAP" "$HIGH"

got="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
# Un conducteur occupé refuserait pour un autre motif : le dire plutôt que de
# laisser croire que le plafond a parlé.
if [ "$(echo "$got" | jq -r '.code // empty')" = "driver.unavailable" ]; then
  fail "Le conducteur a déjà une course en cours — libérez-le d'abord :
     UNBLOCK=1 ./scripts/test-parcours-argent-flotte.sh ${DRIVER_HINT:-}"
fi
expect_ceiling_refusal "Course de $EXPECTED, dette de couple nulle, plafond $COUPLE_CAP" \
  "$COUPLE_CAP" "$got"

# ── 3. Phase B — le plafond par PERSONNE ──────────────────────────────────
step "3. Phase B : couple large, personne ($PERSON_CAP)"

# ⚠️ **C'est ici que se joue la non-redondance du second plafond.** Le plafond
# par couple est à $HIGH : il ne PEUT pas expliquer un refus. Si la course est
# tout de même refusée, c'est le plafond par personne qui a parlé — et le
# chiffre cité dans le message le confirme.
set_ceilings "$HIGH" "$PERSON_CAP"

got="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
expect_ceiling_refusal "Même course, plafond de couple hors d'atteinte, personne $PERSON_CAP" \
  "$PERSON_CAP" "$got"
pass "Le plafond par personne n'est pas redondant : il refuse ce que le couple laisse passer"

# ── 4. Phase C — le témoin ─────────────────────────────────────────────────
step "4. Phase C : les deux plafonds larges — la course DOIT passer"

# Sans ce contrôle, les deux refus ci-dessus pourraient venir d'autre chose.
# C'est lui qui prouve que la même course, par le même conducteur, ne passait
# que par la faute des plafonds.
set_ceilings "$HIGH" "$HIGH"

got="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
echo "$got" | is_error \
  && fail "Plafonds larges et la course est TOUJOURS refusée — le refus ne venait donc pas d'eux" \
          "$(echo "$got" | jq -c '.')"
pass "Acceptée — les deux refus précédents venaient bien des plafonds"

# ── Ménage ─────────────────────────────────────────────────────────────────
#
# ⚠️ **La dernière étape LAISSE une course acceptée, et c'est structurel** : la
# preuve recherchée est justement qu'elle passe, donc le scénario ne peut pas se
# terminer sans elle. Il faut donc la clore après coup.
#
# Sans ce bloc (constaté le 02/08/2026), `run-all-scenarios.sh` ne rendait 7/7
# qu'**une fois** : ce scénario tourne juste avant `test-sorties-de-course`, qui
# exige un conducteur libre, et celui-ci refusait de commencer au passage
# suivant. Le refus était juste — l'état fautif venait de la suite elle-même.
step "Ménage"
release_driver

echo
echo "════════════════════════════════════════════════════════════════"
pass "Les deux plafonds de dette sont vérifiés."
echo "   couple $COUPLE_CAP    → refus, plafond cité $COUPLE_CAP"
echo "   personne $PERSON_CAP  → refus alors que le couple était hors d'atteinte"
echo "   les deux larges       → acceptée"
echo
echo "   ⚠️ Le MÉCANISME est prouvé, pas le montant : 20000 reste un repli,"
echo "      à fixer au pilote avec de vrais paniers."
