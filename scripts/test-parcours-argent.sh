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
# Le commerçant est créé puis **activé par le script**, avec la clé de service
# Fleetbase. Le garde du Lot 4 — pas de connexion tant qu'un admin n'a pas
# passé le `Vendor` à `active` — est volontaire et reste entier ; c'est le rôle
# d'admin qui est ici tenu par le script, pas le garde qui est contourné.
# `register-merchant.sh` reste le script qui joue ce parcours **à la main**,
# console comprise, et c'est lui qui prouve le garde.

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

# La clé de service sert ici à deux choses : résoudre le conducteur, et jouer
# le rôle de l'admin qui valide le commerçant.
. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"

# Active le fournisseur du commerçant, comme le ferait un admin dans la console.
#
# Le nom porte un suffixe unique parce que la recherche se fait par nom : la
# console affiche déjà une douzaine de « Test Argent », et « prendre le plus
# récent » est une mauvaise instruction — la liste n'est pas triée par date, et
# activer le mauvais fournisseur produit un refus qu'on met dix minutes à
# comprendre.
activate_vendor() { # nom du fournisseur
  local vendors uuid
  vendors="$(fb_get '/int/v1/vendors?limit=200')" || return 1
  uuid="$(echo "$vendors" | jq -r --arg n "$1" \
    '(.vendors // .data // []) | map(select(.name == $n)) | last.uuid // empty')"
  [ -n "$uuid" ] || { FLEETBASE_ERROR="fournisseur « $1 » introuvable côté Fleetbase"; return 1; }

  fb_api PUT "/int/v1/vendors/$uuid" '{"status":"active"}' >/dev/null || return 1

  # Relu plutôt que déduit du code HTTP : `status` n'est pas garanti `fillable`,
  # et un `PUT` qui l'ignore renvoie 200 sans rien changer. Le refus de
  # connexion trois lignes plus bas serait alors mis sur le compte du garde.
  vendors="$(fb_get "/int/v1/vendors?limit=200")" || return 1
  local now
  now="$(echo "$vendors" | jq -r --arg u "$uuid" \
    '(.vendors // .data // []) | map(select(.uuid == $u)) | first.status // empty')"
  [ "$now" = "active" ] || {
    FLEETBASE_ERROR="statut du fournisseur resté « ${now:-inconnu} » après le PUT"; return 1; }
}

if [ -z "$EMAIL" ]; then
  SUFFIX="$(date +%s)"
  EMAIL="argent-$SUFFIX@test.dz"
  BUSINESS="Test Argent $SUFFIX"

  reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" --arg b "$BUSINESS" \
      '{email:$e, password:$p, businessName:$b, firstName:"Test", lastName:"Argent",
        phone:"+213555000000", businessPhone:"+213555000000"}')")"
  status="$(tail -n1 <<<"$reg")"
  body="$(sed '$d' <<<"$reg")"

  # ⚠️ Le refus 403 `merchant_pending` EST le succès attendu : depuis le Lot 4,
  # l'inscription enregistre une demande et ne délivre pas de jeton. Tout le
  # reste est un échec — y compris un 2xx, qui signifierait que la validation
  # par un admin ne sert à rien.
  code="$(jq -r '.code // empty' <<<"$body" 2>/dev/null)"
  if [ "$status" = "403" ] && [ "$code" = "merchant_pending" ]; then
    pass "Demande d'inscription enregistrée ($EMAIL)"
  elif [ -n "$(jq -r '.token // empty' <<<"$body" 2>/dev/null)" ]; then
    fail "Un jeton a été délivré à l'inscription — le garde du Lot 4 ne s'applique pas" "$body"
  else
    fail "Inscription en échec (HTTP $status)" "$body"
  fi

  activate_vendor "$BUSINESS" \
    || fail "Activation du fournisseur impossible : ${FLEETBASE_ERROR:-}
   Activez « $BUSINESS » dans la console (Fleet-Ops → Fournisseurs → Statut),
   puis relancez avec EMAIL=$EMAIL"
  pass "Fournisseur « $BUSINESS » activé"
fi

login="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')")"
MERCHANT_TOKEN="$(echo "$login" | jq -r '.token // empty')"
[ -n "$MERCHANT_TOKEN" ] || fail "Connexion commerçant refusée" "$login"
pass "Commerçant connecté ($EMAIL)"

# L'uuid ne s'affiche nulle part dans la console : on le résout depuis ce que
# l'utilisateur a réellement sous les yeux — nom, email, téléphone, ID public.
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
#
# ⚠️ Le corps est PLAT sur cette route (`CashCollectionDto`), alors qu'il est
# imbriqué sous `cash` sur `/activite` (`UpdateActivityDto`). Deux formes pour
# la même déclaration, parce que l'une porte l'encaissement seul et l'autre le
# porte à côté de l'activité. Le §6 ci-dessous exerce la seconde.
completed="$(dapi POST "/transporteur/commandes/$FB_UUID/terminer" \
  "$(jq -n --argjson c "$expected" '{collectedAmount:$c}')")"
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

# ── 6. L'autre chemin de clôture ───────────────────────────────────────────
step "6. Clôture par transition d'activité — le chemin de l'app"

# ── Pourquoi une seconde commande plutôt qu'une assertion de plus ──────────
#
# `POST /terminer` n'est PAS le chemin que l'application emprunte : elle suit
# les transitions que le serveur lui propose (`activites-suivantes`), et la
# transition terminale passe par `POST /activite`. C'est le défaut corrigé au
# journal §16 — la garde « pas de clôture sans déclaration d'encaissement »
# n'existait que sur `/terminer`, donc elle était **décorative**, et une
# livraison encaissée se serait close sans que l'argent figure nulle part.
#
# Ne tester que `/terminer` recréerait exactement l'angle mort qui a produit le
# défaut. Une commande ne se clôturant qu'une fois, il en faut une seconde.

order2="$(mapi POST /commercant/commandes "$(jq -n \
  --argjson goods "$GOODS" --argjson fee "$FEE" '{
  pickupLocationName: "Boulangerie Test", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
  pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
  dropoffLocationName: "Client Test 2", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
  dropoffContactName: "Destinataire 2", dropoffContactPhone: "+213555222222",
  price: $fee, codAmount: $goods, codIncludesDelivery: false,
  podMethod: "aucune", preferFavourites: false, draft: false
}')")"
ORDER2_ID="$(echo "$order2" | jq -r '.id // .uuid // empty')"
[ -n "$ORDER2_ID" ] || fail "Seconde commande refusée" "$(echo "$order2" | jq -c '.')"

live2="$(mapi GET "/commercant/commandes/$ORDER2_ID")"
FB2="$(echo "$live2" | jq -r '.uuid')"
dapi POST "/transporteur/commandes/$FB2/accepter" >/dev/null
dapi POST "/transporteur/commandes/$FB2/demarrer" >/dev/null
pass "Seconde course acceptée et démarrée"

# L'activité terminale est celle que le SERVEUR propose, pas une que le script
# fabrique : `updateActivity()` de Fleetbase commence par `if (!isActivity(...))
# return $this` — un objet inventé produirait un 2xx sans le moindre effet.
acts="$(dapi GET "/transporteur/commandes/$FB2/activites-suivantes")"
terminal="$(echo "$acts" | jq -c '
  [.. | objects | select(.code == "completed" or .status == "completed")] | first // empty')"
[ -n "$terminal" ] || fail "Aucune activité terminale proposée après 'démarrer'.
   Le flux passe peut-être par des étapes intermédiaires (points de passage) —
   les codes proposés ici sont : $(echo "$acts" | jq -c '[.. | objects | .code? // empty] | unique')" \
   "$(echo "$acts" | jq -c '.')"

# ⚠️ Le contrôle central : la clôture SANS déclaration doit être refusée sur ce
# chemin comme sur l'autre. C'est la garde qui était décorative.
refused="$(dapi POST "/transporteur/commandes/$FB2/activite" \
  "$(jq -n --argjson a "$terminal" '{activity:$a}')")"
echo "$refused" | jq -e '.code' >/dev/null 2>&1 \
  || fail "Clôture SANS déclaration d'encaissement acceptée — la garde ne couvre pas ce chemin" \
     "$(echo "$refused" | jq -c '.')"
pass "Clôture sans déclaration refusée ($(echo "$refused" | jq -r '.code'))"

closed="$(dapi POST "/transporteur/commandes/$FB2/activite" \
  "$(jq -n --argjson a "$terminal" --argjson c "$expected" '{activity:$a, cash:{collectedAmount:$c}}')")"
echo "$closed" | jq -e '.code' >/dev/null 2>&1 \
  && fail "Clôture par activité refusée" "$(echo "$closed" | jq -c '.')"

# La dette repart de zéro (soldée au §5), donc elle doit valoir exactement
# celle d'une course : c'est la preuve que l'encaissement a bien été écrit par
# ce chemin-là, et non hérité du précédent.
after2="$(mapi GET /commercant/encaissements | jq -r '[.balances[].debt] | add // 0')"
[ "$(printf '%.0f' "$after2")" = "$due" ] \
  || fail "L'encaissement déclaré par /activite doit créer $due de dette, reçu $after2"
pass "Encaissement enregistré par /activite : $after2 DZD — les deux chemins écrivent bien"

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
