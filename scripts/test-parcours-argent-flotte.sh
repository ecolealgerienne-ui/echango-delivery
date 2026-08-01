#!/usr/bin/env bash
#
# La chaîne d'argent à TROIS maillons : conducteur → entreprise → commerçant.
#
# ── Pourquoi ce script, en plus de `test-parcours-argent.sh` ───────────────
#
# Celui-là passe à l'identique depuis le 31/07/2026, et c'est précisément ce
# qu'on lui demandait : prouver que la généralisation du registre s'est faite
# **à contrat constant**. Il joue donc commerçant ↔ conducteur, sans
# facilitateur — le chemin d'avant le chantier.
#
# Autrement dit, il ne touche à rien de ce que le chantier facilitateur a
# ajouté. La chaîne à trois maillons, elle, n'a **jamais tourné** : deux dettes
# nées d'un seul encaissement, de montants différents, et une remise en deux
# temps. C'est ce que ce script exécute.
#
# ── Ce qu'il vérifie, et pourquoi ces montants-là ─────────────────────────
#
# Marchandise 1300 + course 650 = **1950 réclamés à la porte**, comme dans le
# scénario à deux acteurs. Ce qui change est la répartition, et elle est dictée
# par `isPlatform` (`cash.service.ts`, § « Qui gagne cette course ») :
#
#   * sur une course du POOL, la rémunération revient au conducteur : il retient
#     650 et ne doit que 1300 ;
#   * sur une course d'une VRAIE entreprise, elle revient à l'entreprise — c'est
#     un salaire interne que nous ne verrons jamais. Le conducteur retient donc
#     **0** et remet **l'intégralité**.
#
# D'où les deux dettes attendues, et le fait qu'elles ne sont **pas égales** :
#
#     conducteur → entreprise   1950   (tout ce qu'il a perçu)
#     entreprise → commerçant   1300   (1950 perçus − 650 de rémunération)
#
# Un script qui vérifierait un seul montant, ou le même des deux côtés, ne
# distinguerait pas ce cas de l'ancien. C'est l'écart entre les deux qui prouve
# que le maillon du milieu existe.
#
# ── Ce qu'il exerce au passage, et qui n'avait jamais tourné ──────────────
#
#   * l'inscription d'une entreprise et sa validation par un admin ;
#   * l'adhésion d'un conducteur : demande par l'entreprise, **acceptation par
#     le conducteur** — sans laquelle le couple (conducteur, facilitateur) qui
#     porte la dette n'existe pas ;
#   * la prise d'une course libre par une entreprise (`compare-and-set`) ;
#   * la désignation d'un conducteur, et son plafond de dette (défaut D8) ;
#   * **D17** — `demarrer` sur une commande PRÉ-ASSIGNÉE, explicitement noté
#     « jamais testé » dans `CLAUDE.md`.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-parcours-argent-flotte.sh                 # un seul conducteur
#   ./scripts/test-parcours-argent-flotte.sh alice@test.dz   # ou email, téléphone,
#   ./scripts/test-parcours-argent-flotte.sh "Alice"         # ou fragment de nom
#
#   BFF_URL=http://localhost:3001  adresse du BFF
#   GOODS=1300 FEE=650             montants joués
#   UNBLOCK=1                      annule les courses qui immobilisent le
#                                  conducteur, au lieu de les nommer et de
#                                  s'arrêter (voir `require_free_driver`)
#
# Commerçant ET entreprise sont créés puis **activés par le script**, avec la
# clé de service Fleetbase. Les deux gardes — pas de connexion tant qu'un admin
# n'a pas passé le `Vendor` à `active` — restent entiers : c'est le rôle d'admin
# qui est tenu ici, pas le garde qui est contourné.

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
GOODS="${GOODS:-1300}"
FEE="${FEE:-650}"
DRIVER_HINT="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   Réponse : $2"; exit 1; }
step() { echo; echo "── $1 ──"; }

# Par `statusCode` et non par `code` : un objet activité porte un `code`
# (`{"code":"enroute"}`), et le tester ferait passer une réponse valide pour un
# échec. Même raisonnement que dans `test-parcours-argent.sh`.
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

mapi() { # method path [body] — commerçant
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

fapi() { # method path [body] — entreprise
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $FLEET_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $FLEET_TOKEN"
  fi
}

dapi() { # method path [body] — conducteur
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $DRIVER_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $DRIVER_TOKEN"
  fi
}

echo "BFF : $BFF_URL"
echo "Marchandise $GOODS + course $FEE = $((GOODS + FEE)) réclamés à la porte."
echo "Attendu : conducteur doit $((GOODS + FEE)) à l'entreprise, qui doit $GOODS au commerçant."

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"
. "$(dirname "$0")/lib/ledger.sh"

# `read_blocking_orders` et `require_free_driver` vivent dans la bibliothèque :
# quatre scénarios créent des courses et se heurtent au même refus, et une copie
# du prédicat « occupé » qui diverge déclare libre un conducteur qui ne l'est
# pas (règle 5). Sourcée ici, après `dapi`, `is_error`, `pass` et `fail`.
. "$(dirname "$0")/lib/free-driver.sh"

# ── Sessions ───────────────────────────────────────────────────────────────
step "Sessions"

SUFFIX="$(date +%s)"

# ── Le conducteur, EN PREMIER ──
#
# Il venait en dernier, et c'était l'ordre le plus coûteux : un conducteur
# occupé — le cas ordinaire dès qu'une exécution précédente s'est arrêtée en
# route — faisait échouer le script APRÈS avoir laissé derrière lui un
# commerçant, une entreprise, un fournisseur activé et une course publiée. Ce
# qui peut refuser passe devant ce qui écrit.
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID} — ${DRIVER_SESSION_NOTE:-}"
require_free_driver

# ── Le commerçant ──
MERCHANT_EMAIL="flotte-m-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Flotte", firstName:"Test",
    lastName:"Flotte", phone:"+213555000000", businessPhone:"+213555000000"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription commerçant doit être mise en attente (HTTP $status)" "$body"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" \
  || fail "Activation du commerçant impossible : ${FLEETBASE_ERROR:-}"
# ⚠️ UNE seule connexion, dont on tire le jeton ET l'identifiant. Il n'existe
# pas de route `/commercant/profil` — l'identifiant ne vient que d'ici. Et
# `THROTTLE_LOGIN` plafonne à cinq connexions par minute : en faire deux par
# acteur ferait échouer le script pour une raison qui n'a rien à voir avec ce
# qu'il teste.
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
MERCHANT_ID="$(echo "$mlogin" | jq -r '.user.id // empty')"
[ -n "$MERCHANT_TOKEN" ] && [ -n "$MERCHANT_ID" ] \
  || fail "Connexion commerçant refusée après activation" "$mlogin"
pass "Commerçant : $MERCHANT_EMAIL ($MERCHANT_ID)"

# ── L'entreprise de transport ──
#
# Même parcours que le commerçant, et c'est le premier fait que ce script
# établit : le `Vendor` d'une entreprise naît `inactive` lui aussi. La revue du
# 31/07 signalait l'inverse (« naît active, n'importe qui s'inscrit et entre »)
# — le contrôle vérifie que le correctif tient.
FLEET_EMAIL="flotte-f-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/flotte/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$FLEET_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Transports Test", firstName:"Test",
    lastName:"Transport", phone:"+213555222222", businessPhone:"+213555222222"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
if [ -n "$(jq -r '.token // empty' <<<"$body" 2>/dev/null)" ]; then
  fail "Un jeton a été délivré à l'inscription entreprise — le garde ne s'applique pas" "$body"
fi
[ "$status" = "403" ] || fail "L'inscription entreprise doit être mise en attente (HTTP $status)" "$body"
pass "Demande d'inscription entreprise enregistrée, sans jeton"

fb_activate_vendor_by_email "$FLEET_EMAIL" \
  || fail "Activation de l'entreprise impossible : ${FLEETBASE_ERROR:-}"
flogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$FLEET_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
FLEET_TOKEN="$(echo "$flogin" | jq -r '.token // empty')"
FLEET_ID="$(echo "$flogin" | jq -r '.user.id // empty')"
[ -n "$FLEET_TOKEN" ] && [ -n "$FLEET_ID" ] \
  || fail "Connexion entreprise refusée après activation" "$flogin"
pass "Entreprise : $FLEET_EMAIL ($FLEET_ID)"

# ── 1. L'adhésion ──────────────────────────────────────────────────────────
step "1. Rattachement du conducteur à l'entreprise"

# ⚠️ La demande naît `pending`, et **le conducteur doit accepter**. Ce n'est
# pas de la politesse : la dette naît du couple (conducteur, facilitateur), donc
# créer ce couple sans son accord lui imposerait une obligation financière
# unilatérale.
asked="$(fapi POST "/flotte/conducteurs/$DRIVER_UUID/adhesion")"
echo "$asked" | is_error \
  && fail "Demande d'adhésion refusée" "$(echo "$asked" | jq -c '.')"
pass "Demande envoyée par l'entreprise"

# ⚠️ Forme exacte, sans repli. `listMemberships` rend `{data:[{id, fleet_id,
# name, status}]}` — vérifié dans le service. Un repli « au cas où » ferait
# passer un changement de contrat pour un succès, et c'est précisément ce qu'un
# script comme celui-ci doit attraper.
#
# La liste peut porter en tête l'entreprise d'ORIGINE du conducteur, qui n'est
# pas une adhésion : son `id` vaut `null`. Filtrer sur l'identifiant de NOTRE
# entreprise et sur `pending` écarte les deux.
mine="$(dapi GET /transporteur/entreprises)"
MEMBERSHIP_ID="$(echo "$mine" | jq -r --arg f "$FLEET_ID" \
  'first(.data[] | select(.fleet_id == $f and .status == "pending")) | .id // empty')"
[ -n "$MEMBERSHIP_ID" ] \
  || fail "Aucune adhésion en attente de cette entreprise côté conducteur" \
     "$(echo "$mine" | jq -c '.data')"

accepted="$(dapi POST "/transporteur/entreprises/$MEMBERSHIP_ID/accepter")"
echo "$accepted" | is_error \
  && fail "Acceptation d'adhésion refusée" "$(echo "$accepted" | jq -c '.')"
pass "Adhésion acceptée par le conducteur"

drivers="$(fapi GET /flotte/drivers)"
echo "$drivers" | jq -e --arg u "$DRIVER_UUID" \
  '[.data[].uuid] | index($u) != null' >/dev/null \
  || fail "Le conducteur n'apparaît pas dans la liste de l'entreprise" \
     "$(echo "$drivers" | jq -c '[.data[].uuid]')"
pass "Le conducteur figure dans la liste de l'entreprise"

# ── 2. La course ───────────────────────────────────────────────────────────
step "2. Le commerçant crée et publie"

order="$(mapi POST /commercant/commandes "$(jq -n \
  --argjson goods "$GOODS" --argjson fee "$FEE" '{
  pickupLocationName: "Commerce Flotte", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
  pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
  dropoffLocationName: "Client Flotte", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
  dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
  price: $fee, codAmount: $goods, codIncludesDelivery: false,
  podMethod: "aucune", preferFavourites: false, draft: true
}')")"
ORDER_ID="$(echo "$order" | jq -r '.id // .uuid // empty')"
[ -n "$ORDER_ID" ] || fail "Création refusée" "$(echo "$order" | jq -c '.')"

EXPECTED=$((GOODS + FEE))
cod="$(mapi GET "/commercant/commandes/$ORDER_ID" | jq -r '.meta.cod_amount // "absent"')"
[ "$cod" = "$EXPECTED" ] || fail "À encaisser attendu $EXPECTED, reçu '$cod'"

published="$(mapi POST "/commercant/commandes/$ORDER_ID/publier")"
echo "$published" | is_error && fail "Publication refusée" "$(echo "$published" | jq -c '.')"
after="$(mapi GET "/commercant/commandes/$ORDER_ID")"
FB_UUID="$(echo "$after" | jq -r '.uuid')"
[ "$(echo "$after" | jq -r '.status')" = "dispatched" ] \
  || fail "Après publication le statut doit être 'dispatched'" "$(echo "$after" | jq -c '.')"
pass "Publiée : $EXPECTED à encaisser, course diffusée"

# ── 3. L'entreprise prend la course ────────────────────────────────────────
step "3. Prise par l'entreprise"

# ⚠️ Les clés sont NOMMÉES, jamais devinées par un `.data // .`. Un tel repli
# transforme un changement de contrat en succès silencieux — et c'est
# exactement ce qu'un script comme celui-ci doit attraper. Les formes ont été
# relevées dans les services : `{data:[…]}` partout, sauf la liste du
# conducteur qui rend `{orders:[…]}`.
opps="$(fapi GET /flotte/opportunites)"
echo "$opps" | jq -e --arg u "$FB_UUID" \
  '[.data[].uuid] | index($u) != null' >/dev/null \
  || fail "La course publiée n'apparaît pas dans les opportunités" \
     "$(echo "$opps" | jq -c '[.data[].uuid]')"
pass "La course figure dans les courses libres"

# ⚠️ L'identité du destinataire est masquée tant que personne ne s'est engagé
# (décision produit du 31/07). L'adresse, elle, est servie — c'est le critère de
# décision. Le contrôle porte sur le NOM, pas sur l'absence de données.
opp="$(fapi GET "/flotte/opportunites/$FB_UUID")"
echo "$opp" | jq -e '(.payload.dropoff.name // "") | length == 0' >/dev/null \
  || fail "Le nom du destinataire ne doit pas être servi avant l'engagement" \
     "$(echo "$opp" | jq -c '.payload.dropoff')"
pass "Identité du destinataire masquée avant engagement"

claimed="$(fapi POST "/flotte/opportunites/$FB_UUID/prendre")"
echo "$claimed" | is_error && fail "Prise refusée" "$(echo "$claimed" | jq -c '.')"
pass "Course prise par l'entreprise"

# Une course prise ne doit plus être réclamable par un indépendant : `adhoc`
# passe à `false` dans le même geste, sans quoi les pings de diffusion
# continuent toutes les ~4 minutes.
# ⚠️ `.orders` et non `.data` : `listOrders` rend `{orders:[…]}` sur un `type`
# précis, et `{active, adhoc, history}` sans. C'est le seul des six accès de ce
# script qui ne s'appelle pas `data` — et mon `.data // .` le masquait au lieu
# de le signaler : le repli tombait sur l'objet entier, dont les valeurs sont
# des TABLEAUX, d'où « Cannot index array with string "uuid" ».
still="$(dapi GET "/transporteur/commandes?type=adhoc")"
echo "$still" | jq -e --arg u "$FB_UUID" \
  '[.orders[].uuid] | index($u) == null' >/dev/null \
  || fail "La course reste offerte au pool après avoir été prise" \
     "$(echo "$still" | jq -c '[.orders[].uuid]')"
pass "Retirée du pool — plus offerte aux indépendants"

# ── 4. Désignation du conducteur ───────────────────────────────────────────
step "4. L'entreprise désigne son conducteur"

assigned="$(fapi POST "/flotte/commandes/$FB_UUID/assigner" \
  "$(jq -n --arg d "$DRIVER_UUID" '{driverId:$d}')")"
echo "$assigned" | is_error && fail "Désignation refusée" "$(echo "$assigned" | jq -c '.')"
pass "Conducteur désigné"

# ── 5. D17 : démarrer une commande PRÉ-ASSIGNÉE ────────────────────────────
step "5. Le conducteur livre (D17 : commande pré-assignée)"

# ⚠️ Le point noté « jamais testé » dans CLAUDE.md. Le conducteur n'a pas
# accepté cette course : elle lui a été confiée. `demarrer` doit donc marcher
# sans acceptation préalable — ou dire clairement pourquoi non.
started="$(dapi POST "/transporteur/commandes/$FB_UUID/demarrer")"
if echo "$started" | is_error; then
  code="$(echo "$started" | jq -r '.code // "sans code"')"
  fail "D17 : démarrer une commande pré-assignée est refusé ($code)" \
       "$(echo "$started" | jq -c '.')"
fi
pass "D17 : démarrage sans acceptation préalable — accepté"

completed="$(dapi POST "/transporteur/commandes/$FB_UUID/terminer" \
  "$(jq -n --argjson c "$EXPECTED" '{collectedAmount:$c}')")"
echo "$completed" | is_error && fail "Clôture refusée" "$(echo "$completed" | jq -c '.')"
pass "Livrée, $EXPECTED DZD déclarés encaissés"

# ── 6. Le cœur : DEUX dettes, de montants différents ───────────────────────
step "6. Deux dettes nées d'un seul encaissement"

DRIVER_OWES=$EXPECTED          # il retient 0 : la rémunération est à l'entreprise
FLEET_OWES=$GOODS              # 1950 perçus − 650 de rémunération

dledger="$(dapi GET /transporteur/caisse)"
d="$(debt_toward "$dledger" "$FLEET_ID")"
[ "$(amount_number "$d")" = "$DRIVER_OWES" ] \
  || fail "Le conducteur doit $DRIVER_OWES à l'entreprise, le registre dit '$d'" \
     "$(echo "$dledger" | jq -c '.balances')"
pass "Conducteur → entreprise : $DRIVER_OWES DZD (il ne retient RIEN)"

fledger="$(fapi GET /flotte/caisse)"
f="$(debt_toward "$fledger" "$MERCHANT_ID")"
[ "$(amount_number "$f")" = "$FLEET_OWES" ] \
  || fail "L'entreprise doit $FLEET_OWES au commerçant, le registre dit '$f'" \
     "$(echo "$fledger" | jq -c '.balances')"
pass "Entreprise → commerçant : $FLEET_OWES DZD (elle garde les $FEE)"

# ⚠️ **Le contrôle qui distingue vraiment ce scénario de l'ancien.** Le
# commerçant doit voir l'ENTREPRISE comme contrepartie, pas le conducteur : la
# perte d'un conducteur ne change rien à ce qu'il lui est dû, elle bascule sur
# la chaîne interne. Si le registre lui montrait le conducteur, tout le maillon
# du milieu serait décoratif.
mledger="$(mapi GET /commercant/encaissements)"
m="$(debt_toward "$mledger" "$FLEET_ID")"
[ "$(amount_number "$m")" = "$FLEET_OWES" ] \
  || fail "Le commerçant doit voir $FLEET_OWES dus par L'ENTREPRISE, il voit '$m'" \
     "$(echo "$mledger" | jq -c '.balances')"
mtype="$(echo "$mledger" | jq -r --arg c "$FLEET_ID" \
  'first(.balances[] | select(.counterparty_id == $c)) | .counterparty_type // "absent"')"
[ "$mtype" = "fleet" ] \
  || fail "La contrepartie du commerçant doit être typée 'fleet', elle est '$mtype'" \
     "$(echo "$mledger" | jq -c '.balances')"
pass "Le commerçant fait face à l'ENTREPRISE (type '$mtype'), jamais au conducteur"

# Et les deux montants diffèrent : c'est l'écart qui prouve le maillon.
[ "$DRIVER_OWES" != "$FLEET_OWES" ] \
  || fail "Les deux dettes sont égales — le scénario ne distingue rien"
pass "Les deux dettes diffèrent de $FEE — la rémunération est bien restée au milieu"

# ── 7. La remise, en deux temps ────────────────────────────────────────────
step "7. Remise conducteur → entreprise"

r1="$(dapi POST /transporteur/caisse/remises \
  "$(jq -n --arg m "$FLEET_ID" --argjson a "$DRIVER_OWES" '{merchantId:$m, amount:$a}')")"
echo "$r1" | is_error && fail "Déclaration de remise refusée" "$(echo "$r1" | jq -c '.')"
pass "Remise de $DRIVER_OWES déclarée par le conducteur"

before="$(debt_toward "$(dapi GET /transporteur/caisse)" "$FLEET_ID")"
[ "$(amount_number "$before")" = "$DRIVER_OWES" ] \
  || fail "La dette a bougé AVANT confirmation — c'est le principe même du registre" "$before"
pass "Dette inchangée avant confirmation"

R1_ID="$(fapi GET /flotte/caisse/remises | jq -r \
  '[.data[] | select(.confirmed_at == null)] | last.id // empty')"
[ -n "$R1_ID" ] || fail "L'entreprise ne voit aucune remise à confirmer"
c1="$(fapi POST "/flotte/caisse/remises/$R1_ID/confirmer")"
echo "$c1" | is_error && fail "Confirmation refusée" "$(echo "$c1" | jq -c '.')"

after1="$(debt_toward "$(dapi GET /transporteur/caisse)" "$FLEET_ID")"
[ "$(amount_number "$after1")" = "0" ] \
  || fail "Après confirmation, le conducteur ne doit plus rien ; le registre dit '$after1'"
pass "Confirmée — le conducteur est à jour ($(amount_number "$after1") DZD)"

# La dette de l'entreprise envers le commerçant n'a PAS bougé : ce sont deux
# maillons distincts, et régler l'un ne règle pas l'autre.
untouched="$(debt_toward "$(fapi GET /flotte/caisse)" "$MERCHANT_ID")"
[ "$(amount_number "$untouched")" = "$FLEET_OWES" ] \
  || fail "Le maillon entreprise → commerçant a bougé alors qu'il ne devait pas" "$untouched"
pass "Le second maillon est intact : $(amount_number "$untouched") DZD toujours dus au commerçant"

step "8. Remise entreprise → commerçant"

r2="$(fapi POST /flotte/caisse/remises \
  "$(jq -n --arg c "$MERCHANT_ID" --argjson a "$FLEET_OWES" '{counterpartyId:$c, amount:$a}')")"
echo "$r2" | is_error && fail "Déclaration de remise refusée" "$(echo "$r2" | jq -c '.')"
pass "Remise de $FLEET_OWES déclarée par l'entreprise"

R2_ID="$(mapi GET /commercant/encaissements/remises | jq -r \
  '[.data[] | select(.confirmed_at == null)] | last.id // empty')"
[ -n "$R2_ID" ] || fail "Le commerçant ne voit aucune remise à confirmer"
c2="$(mapi POST "/commercant/encaissements/remises/$R2_ID/confirmer")"
echo "$c2" | is_error && fail "Confirmation refusée" "$(echo "$c2" | jq -c '.')"

final="$(debt_toward "$(mapi GET /commercant/encaissements)" "$FLEET_ID")"
[ "$(amount_number "$final")" = "0" ] \
  || fail "Après confirmation, l'entreprise ne doit plus rien ; le registre dit '$final'"
pass "Confirmée — la chaîne est soldée de bout en bout"

echo
echo "════════════════════════════════════════════════════════════"
echo " Chaîne à trois maillons validée."
echo
echo " $EXPECTED réclamés à la porte."
echo " Le conducteur retient 0 et remet $DRIVER_OWES à son entreprise."
echo " L'entreprise garde $FEE et remet $FLEET_OWES au commerçant."
echo " Chaque maillon se règle indépendamment, et seule la confirmation solde."
echo
echo " Exercés au passage, et jamais joués jusqu'ici : validation d'une"
echo " entreprise, adhésion consentie d'un conducteur, prise d'une course"
echo " libre, désignation, et D17 (démarrage d'une commande pré-assignée)."
echo "════════════════════════════════════════════════════════════"
