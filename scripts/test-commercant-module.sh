#!/usr/bin/env bash
# Valide au curl le module commerçant du BFF, et sert d'outil de remplissage :
# chaque exécution crée une vraie commande, dispatchable ensuite vers les
# transporteurs.
#
#   ./scripts/test-commercant-module.sh              # valide + 1 commande
#   ORDERS=5 ./scripts/test-commercant-module.sh     # en crée 5
#   EMAIL=... PASSWORD=... ./scripts/...             # réutilise un commerçant
#
# Contrairement à seed-test-order.sh (qui appelle Fleetbase directement en
# recopiant une commande existante), celui-ci passe par le vrai chemin
# commerçant : compte Echango → Vendor Fleetbase → Places → commande. C'est
# donc aussi un test de bout en bout du parcours réel.
set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
EMAIL="${EMAIL:-}"
PASSWORD="${PASSWORD:-motdepasse123}"
ORDERS="${ORDERS:-1}"

command -v jq >/dev/null 2>&1 || {
  echo "❌ jq requis : sudo apt update && sudo apt install -y jq"; exit 1; }

pass() { echo "✅ $1"; }
warn() { echo "⚠️  $1"; }
fail() { echo "❌ $1"; echo "   Réponse : $2"; exit 1; }

api() { # method path [body]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $TOKEN"
  fi
}

echo "BFF : $BFF_URL"
echo ""

# --- 1. Compte commerçant -------------------------------------------------
# L'inscription commerçant CRÉE un Vendor + un Contact côté Fleetbase
# (contrairement au driver, qui se lie à un enregistrement existant). Chaque
# nouveau compte laisse donc une trace : on en réutilise un si possible.
if [ -z "$EMAIL" ]; then
  EMAIL="commercant-test-$RANDOM@echango.local"
  REG=$(curl -sS -X POST "$BFF_URL/auth/merchant/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
      '{email:$e, password:$p, businessName:"Boulangerie Test",
        firstName:"Test", lastName:"Commerçant", phone:"+213555000000"}')")

  TOKEN=$(echo "$REG" | jq -r '.token // empty')
  [ -n "$TOKEN" ] || fail "inscription commerçant échouée" "$REG"
  pass "register — compte créé (Vendor + Contact Fleetbase) : $EMAIL"
else
  TOKEN=$(curl -sS -X POST "$BFF_URL/auth/merchant/login" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')" \
    | jq -r '.token // empty')
  [ -n "$TOKEN" ] || fail "connexion échouée pour $EMAIL" "-"
  pass "login — compte existant réutilisé : $EMAIL"
fi

# --- 2. Carnet d'adresses -------------------------------------------------
# `owner_uuid` sur /places est un VRAI filtre serveur, vérifié en réel
# (journal §2.7) — contrairement aux filtres de /orders et /drivers, ignorés
# silencieusement. C'est ce qui rend le carnet d'adresses scopable sans
# filtrage BFF supplémentaire.
ADDR=$(api POST /commercant/adresses \
  '{"label":"magasin","name":"Boulangerie Test","latitude":36.7538,
    "longitude":3.0588,"address":"12 rue Didouche Mourad, Alger",
    "contactName":"Test","contactPhone":"+213555000000"}')
echo "$ADDR" | jq -e '.uuid // .id // .public_id' >/dev/null 2>&1 \
  || fail "POST /commercant/adresses" "$ADDR"
pass "POST /commercant/adresses"

LIST=$(api GET /commercant/adresses)
N_ADDR=$(echo "$LIST" | jq '(.places // .addresses // .) | length' 2>/dev/null || echo 0)
pass "GET  /commercant/adresses ($N_ADDR enregistrée·s)"

# --- 3. Création de commandes --------------------------------------------
# Points dans Alger, à quelques centaines de mètres : le dispatch adhoc est
# géospatial, un driver positionné au centre doit pouvoir les recevoir.
CREATED_IDS=()
for i in $(seq 1 "$ORDERS"); do
  BODY=$(jq -n --arg n "$i" \
    '{pickupLocationName:("Boulangerie Test #" + $n),
      pickupLatitude:36.7538, pickupLongitude:3.0588,
      pickupContactName:"Vendeur", pickupContactPhone:"+213555000000",
      dropoffLocationName:("Client #" + $n),
      dropoffLatitude:36.7620, dropoffLongitude:3.0510,
      dropoffContactName:("Client " + $n), dropoffContactPhone:"+213555111111",
      deliveryInstructions:"Commande de test — script commerçant",
      items:[{description:"Colis test", quantity:1}]}')

  RESP=$(api POST /commercant/commandes "$BODY")
  ID=$(echo "$RESP" | jq -r '(.order // .data // .) | (.public_id // .uuid // .id) // empty')
  [ -n "$ID" ] || fail "POST /commercant/commandes (n°$i)" "$RESP"
  CREATED_IDS+=("$ID")
  pass "POST /commercant/commandes → $ID"
done

# --- 4. Lecture -----------------------------------------------------------
LIST=$(api GET /commercant/commandes)
N=$(echo "$LIST" | jq '(.orders // .data // .) | length' 2>/dev/null || echo 0)
[ "$N" -ge 1 ] || fail "GET /commercant/commandes ne renvoie rien" "$LIST"
pass "GET  /commercant/commandes ($N commande·s)"

FIRST="${CREATED_IDS[0]}"
DETAIL=$(api GET "/commercant/commandes/$FIRST")
echo "$DETAIL" | jq -e '.' >/dev/null 2>&1 || fail "GET détail" "$DETAIL"
pass "GET  /commercant/commandes/:id"

TRACK=$(api GET "/commercant/commandes/$FIRST/suivi")
echo "$TRACK" | jq -e '.' >/dev/null 2>&1 \
  && pass "GET  /commercant/commandes/:id/suivi" \
  || warn "suivi indisponible (normal tant que la commande n'est pas dispatchée)"

# --- 5. ⚠️ Anti-IDOR ------------------------------------------------------
# Le contrôle qui compte. §2.8 a montré que Fleetbase ignore silencieusement
# les filtres non supportés sur /orders : sans filtrage côté BFF, un
# commerçant verrait les commandes de TOUS les autres.
OTHER_EMAIL="commercant-intrus-$RANDOM@echango.local"
OTHER=$(curl -sS -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$OTHER_EMAIL" --arg p "$PASSWORD" \
    '{email:$e, password:$p, businessName:"Pharmacie Intruse"}')")
OTHER_TOKEN=$(echo "$OTHER" | jq -r '.token // empty')

if [ -n "$OTHER_TOKEN" ]; then
  CODE=$(curl -sS -o /dev/null -w '%{http_code}' \
    "$BFF_URL/commercant/commandes/$FIRST" -H "Authorization: Bearer $OTHER_TOKEN")
  case "$CODE" in
    403|404) pass "anti-IDOR — commande d'un autre commerçant refusée ($CODE)" ;;
    *) fail "FUITE : un commerçant accède à la commande d'un autre (HTTP $CODE)" "$FIRST" ;;
  esac

  N_OTHER=$(curl -sS "$BFF_URL/commercant/commandes" \
    -H "Authorization: Bearer $OTHER_TOKEN" \
    | jq '(.orders // .data // .) | length' 2>/dev/null || echo 0)
  [ "$N_OTHER" = "0" ] \
    && pass "anti-IDOR — liste vide pour un commerçant sans commande" \
    || fail "FUITE : un commerçant neuf voit $N_OTHER commande·s" "-"
else
  warn "anti-IDOR non testé (création du 2e commerçant impossible)"
fi

echo ""
echo "──────────────────────────────────────────────────────────"
echo "Commerçant : $EMAIL / $PASSWORD"
echo "Commandes créées : ${CREATED_IDS[*]}"
echo ""
echo "Ces commandes ne sont PAS encore dispatchées : elles n'apparaîtront"
echo "donc pas comme opportunités côté transporteur. Pour les diffuser :"
echo ""
echo "  console Fleetbase > Orders > sélection > « Ordres d'envoi »"
echo ""
echo "L'annulation n'est pas exercée ici (elle détruirait la commande qu'on"
echo "vient de créer) :"
echo "  curl -X POST $BFF_URL/commercant/commandes/$FIRST/annuler \\"
echo "    -H \"Authorization: Bearer \$TOKEN\""
echo "──────────────────────────────────────────────────────────"
