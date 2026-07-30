#!/usr/bin/env bash
#
# Le parcours complet de l'argent, joué de bout en bout.
#
# ── Pourquoi ce script existe ──────────────────────────────────────────────
#
# Deux chaînes n'ont JAMAIS été jouées en réel, et ce sont les deux qui portent
# de l'argent :
#
#   1. **Publier** un brouillon — `PATCH /int/v1/orders/dispatch`, trouvé après
#      cinq tentatives infructueuses, plus la compensation qui retire la course
#      de la diffusion si le dispatch échoue.
#   2. **Encaissement → dette → remise → confirmation** — le registre de caisse
#      entier, écrit sur trois jours et jamais exécuté une seule fois.
#
# `test-commercant-module.sh` couvre l'inscription, le carnet, la création et
# l'anti-IDOR ; `test-transporteur-module.sh` couvre les transitions d'état.
# Aucun des deux ne touche à ces deux chaînes-là.
#
# ── Pourquoi maintenant, avant le facilitateur ─────────────────────────────
#
# Le lot « entreprise de transport » change **la contrepartie** du registre :
# la dette devient celle de l'entreprise et non plus du conducteur
# (`docs/specs_flux_argent_quatre_acteurs.md` §4.1). Modifier une mécanique qui
# n'a jamais tourné, c'est empiler deux inconnues — et sur des montants.
#
# Ce script fige donc le comportement à trois acteurs. Il devra continuer de
# passer après la généralisation : c'est ce qui prouvera qu'elle est bien « à
# contrat constant ».
#
# ── Usage ──────────────────────────────────────────────────────────────────
#
#   ./scripts/test-parcours-argent.sh                 # s'il n'y a qu'un conducteur
#   ./scripts/test-parcours-argent.sh alice@test.dz   # ou email, téléphone,
#   ./scripts/test-parcours-argent.sh driver_2xk9     # ID public, ID interne,
#   ./scripts/test-parcours-argent.sh "Alice"         # ou un fragment de nom
#
#   BFF_URL=http://localhost:3001  adresse du BFF
#   EMAIL= PASSWORD=               réutilise un commerçant existant
#   GOODS=1300 FEE=650             montants joués
#
# ⚠️ Le commerçant doit être ACTIF côté Fleetbase (Fleet-Ops → Fournisseurs →
# Statut), sinon la connexion est refusée — c'est le garde du Lot 4, et il est
# volontaire.

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
EMAIL="${EMAIL:-}"
GOODS="${GOODS:-1300}"
FEE="${FEE:-650}"
DRIVER_HINT="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   Réponse : $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

mapi() { # method path [body] — appel commerçant
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

dapi() { # method path [body] — appel transporteur
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $DRIVER_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $DRIVER_TOKEN"
  fi
}

echo "BFF : $BFF_URL"
echo "Marchandise $GOODS, course $FEE — livraison NON incluse, donc"
echo "$((GOODS + FEE)) doivent être réclamés à la porte."

# ── Sessions ───────────────────────────────────────────────────────────────
step "Sessions"

if [ -z "$EMAIL" ]; then
  EMAIL="argent-$(date +%s)@test.dz"
  reg="$(curl -sS -X POST "$BFF_URL/auth/commercant/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" \
      '{email:$e, password:$p, businessName:"Test Argent", phone:"+213555000000"}')")"
  echo "$reg" | jq -e '.id // .merchant' >/dev/null 2>&1 \
    || echo "   (inscription : $(echo "$reg" | jq -c '.code // .message // .' 2>/dev/null))"
  echo "   Commerçant créé : $EMAIL"
  echo "   ⚠️ Activez son Vendor dans la console AVANT de continuer, puis"
  echo "      relancez avec EMAIL=$EMAIL"
  exit 0
fi

login="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')")"
MERCHANT_TOKEN="$(echo "$login" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant refusée" "$login"
pass "Commerçant connecté ($EMAIL)"

# L'uuid ne s'affiche nulle part dans la console : on le résout depuis ce que
# l'utilisateur a réellement sous les yeux — nom, email, téléphone, ID public.
. "$(dirname "$0")/lib/resolve-driver.sh"
resolve_driver "$DRIVER_HINT" || fail "$RESOLVE_DRIVER_ERROR"
pass "Conducteur : $DRIVER_LABEL"

. "$(dirname "$0")/lib/driver-session.sh"
obtain_driver_token "$DRIVER_UUID" || fail "Session transporteur impossible" "${DRIVER_SESSION_ERROR:-}"
pass "Transporteur connecté — ${DRIVER_SESSION_NOTE:-}"

# ── 1. Brouillon avec encaissement ─────────────────────────────────────────
step "1. Création d'un brouillon encaissé"

order="$(mapi POST /commercant/commandes "$(jq -n \
  --argjson goods "$GOODS" --argjson fee "$FEE" '{
  pickupLocationName: "Boulangerie Test", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
  pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
  dropoffLocationName: "Client Test", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
  dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
  price: $fee, codAmount: $goods, codIncludesDelivery: false,
  podMethod: "aucune", preferFavourites: false, draft: true
}')")"

ORDER_ID="$(echo "$order" | jq -r '.id // .uuid // empty')"
[ -n "$ORDER_ID" ] || fail "Création refusée" "$(echo "$order" | jq -c '.')"
pass "Brouillon créé : $ORDER_ID"

detail="$(mapi GET "/commercant/commandes/$ORDER_ID")"
status="$(echo "$detail" | jq -r '.status')"
cod="$(echo "$detail" | jq -r '.meta.cod_amount // "absent"')"

[ "$status" = "created" ] || fail "Un brouillon doit être 'created', reçu '$status'"
pass "Statut 'created' — le brouillon n'est pas diffusé"

# ⚠️ Le contrôle qui vaut la décision produit du 30/07 : la livraison n'étant
# PAS incluse, la rémunération s'ajoute à la marchandise.
expected=$((GOODS + FEE))
[ "$cod" = "$expected" ] \
  || fail "À encaisser attendu $expected (marchandise + course), reçu '$cod'"
pass "À encaisser = $cod — la course s'ajoute bien à la marchandise"

# ── 2. Publier ─────────────────────────────────────────────────────────────
step "2. Publication (jamais jouée jusqu'ici)"

published="$(mapi POST "/commercant/commandes/$ORDER_ID/publier")"
echo "$published" | jq -e '.code' >/dev/null 2>&1 \
  && fail "Publication refusée" "$(echo "$published" | jq -c '.')"

after="$(mapi GET "/commercant/commandes/$ORDER_ID")"
[ "$(echo "$after" | jq -r '.status')" = "dispatched" ] \
  || fail "Après publication le statut doit être 'dispatched'" "$(echo "$after" | jq -c '.status, .adhoc, .dispatched')"
pass "Publiée — statut 'dispatched', course diffusée"

# ── 3. Le transporteur prend et livre ──────────────────────────────────────
step "3. Acceptation, démarrage, livraison"

FB_UUID="$(echo "$after" | jq -r '.uuid')"

accepted="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
echo "$accepted" | jq -e '.code' >/dev/null 2>&1 \
  && fail "Acceptation refusée" "$(echo "$accepted" | jq -c '.')"
pass "Course acceptée"

dapi POST "/transporteur/commandes/$FB_UUID/demarrer" >/dev/null
pass "Course démarrée"

# Le montant perçu est volontairement CONFORME ici : l'écart a son propre
# scénario, et mélanger les deux rendrait un échec ambigu.
completed="$(dapi POST "/transporteur/commandes/$FB_UUID/terminer" \
  "$(jq -n --argjson c "$expected" '{cash:{collectedAmount:$c}}')")"
echo "$completed" | jq -e '.code' >/dev/null 2>&1 \
  && fail "Clôture refusée" "$(echo "$completed" | jq -c '.')"
pass "Livrée, $expected DZD déclarés encaissés"

# ── 4. La dette apparaît des deux côtés ────────────────────────────────────
step "4. Le registre"

# `dette = perçu − rémunération` (journal §17) : le transporteur retient sa
# course et ne doit que la différence.
due=$((expected - FEE))

# ⚠️ Le registre ne renvoie PAS de total : il n'expose que `balances[].debt`,
# et la somme se fait côté client. C'est cohérent avec le principe « aucun
# solde n'est stocké » — mais ça se vérifie, ça ne se suppose pas.
mledger="$(mapi GET /commercant/encaissements)"
mtotal="$(echo "$mledger" | jq -r '[.balances[].debt] | add // 0')"
[ "$(printf '%.0f' "$mtotal")" = "$due" ] \
  || fail "Le commerçant doit voir $due dû, il voit $mtotal" "$(echo "$mledger" | jq -c '.')"
pass "Commerçant : $mtotal DZD détenus pour lui"

dledger="$(dapi GET /transporteur/caisse)"
dtotal="$(echo "$dledger" | jq -r '[.balances[].debt] | add // 0')"
[ "$(printf '%.0f' "$dtotal")" = "$due" ] \
  || fail "Le transporteur doit voir $due à remettre, il voit $dtotal"
pass "Transporteur : $dtotal DZD à remettre — les deux vues concordent"

details="$(mapi GET /commercant/encaissements/details)"
net="$(echo "$details" | jq -r '.data[0].net_amount // "absent"')"
ret="$(echo "$details" | jq -r '.data[0].retained_amount // "absent"')"
[ "$(printf '%.0f' "$ret")" = "$FEE" ] \
  || fail "Retenue attendue $FEE, reçue '$ret'" "$(echo "$details" | jq -c '.data[0]')"
pass "Détail : perçu $expected, retenu $ret, revient $net"

# ── 5. Remise et confirmation ──────────────────────────────────────────────
step "5. Remise"

# Vu du transporteur, la contrepartie est le commerçant — c'est `merchant_id`
# que `driverBalances()` projette. Le repli sur `counterparty_id` anticipe la
# généralisation aux entreprises (§4.1) : le jour où la contrepartie devient
# typée, ce script continuera de passer sans retouche.
MERCHANT_ID="$(echo "$dledger" | jq -r '.balances[0].counterparty_id // .balances[0].merchant_id // empty')"
[ -n "$MERCHANT_ID" ] || fail "Contrepartie introuvable côté transporteur" "$(echo "$dledger" | jq -c '.balances')"

declared="$(dapi POST /transporteur/caisse/remises \
  "$(jq -n --arg m "$MERCHANT_ID" --argjson a "$due" '{merchantId:$m, amount:$a}')")"
REMITTANCE_ID="$(echo "$declared" | jq -r '.id // empty')"
[ -n "$REMITTANCE_ID" ] || fail "Déclaration de remise refusée" "$(echo "$declared" | jq -c '.')"
pass "Remise de $due déclarée par le transporteur"

# ⚠️ Le contrôle qui donne son sens au registre : tant que l'autre partie n'a
# rien confirmé, une remise est une AFFIRMATION, pas un fait. La dette ne doit
# donc pas avoir bougé.
still="$(mapi GET /commercant/encaissements | jq -r '[.balances[].debt] | add // 0')"
[ "$(printf '%.0f' "$still")" = "$due" ] \
  || fail "Une remise NON confirmée ne doit pas réduire la dette (reçu $still)"
pass "Dette inchangée avant confirmation — c'est le point du modèle"

confirmed="$(mapi POST "/commercant/encaissements/remises/$REMITTANCE_ID/confirmer")"
echo "$confirmed" | jq -e '.code' >/dev/null 2>&1 \
  && fail "Confirmation refusée" "$(echo "$confirmed" | jq -c '.')"

# Une dette soldée disparaît de `balances` (`filter(.debt != 0)`), donc la
# somme d'une liste vide vaut 0 — c'est bien ce qu'on veut lire.
final="$(mapi GET /commercant/encaissements | jq -r '[.balances[].debt] | add // 0')"
[ "$(printf '%.0f' "$final")" = "0" ] \
  || fail "Après confirmation la dette doit être soldée, reste $final"
pass "Dette soldée : $final DZD"

echo
echo "════════════════════════════════════════════════════════════"
echo " Parcours complet validé — publication ET chaîne d'argent."
echo
echo " Marchandise $GOODS + course $FEE = $expected réclamés à la porte"
echo " Transporteur retient $FEE, doit $due, remet, le commerçant confirme."
echo
echo " ⚠️ À rejouer À L'IDENTIQUE après la généralisation du registre aux"
echo "    entreprises de transport : c'est ce qui prouvera qu'elle est bien"
echo "    à contrat constant."
echo "════════════════════════════════════════════════════════════"
