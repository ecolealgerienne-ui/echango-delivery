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

# Reconnaît une réponse d'erreur du BFF, sur stdin.
#
# ⚠️ Par `statusCode` et NON par `code`. Le script testait la présence de
# `code`, ce qui marche tant que les réponses de succès n'en portent pas — or
# **un objet activité en porte un** (`{"code":"enroute",…}`). Sur le chemin de
# clôture par transition, une réponse parfaitement valide aurait donc été lue
# comme un échec, ou pire : le jour où une erreur arrive sans `code`, elle
# passerait pour un succès.
#
# `statusCode` est le seul champ que `HttpExceptionFilter` pose sur **toutes**
# les erreurs, y compris celles qui n'ont pas de `code` métier.
is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

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
. "$(dirname "$0")/lib/ledger.sh"

# ── La forme de la chaîne dépend du provisionnement ───────────────────────
#
# Depuis le 01/08/2026, une course du pool a **Echango pour facilitateur** —
# quand un prestataire plateforme est désigné (`provision-platform.sh`). La
# chaîne passe alors de deux maillons à trois :
#
#     sans plateforme   conducteur ─────────────▶ commerçant
#     avec plateforme   conducteur ──▶ Echango ──▶ commerçant
#
# ⚠️ **Ce script teste la forme réellement configurée, et la nomme.** Écrire en
# dur l'une des deux le ferait échouer sur l'autre pour une raison qui n'est pas
# un défaut — et la configuration est une décision de déploiement légitime, pas
# un état transitoire. Le §5 de `specs_facilitateur.md` annonçait ce changement
# de contrat : le voici, sous condition plutôt qu'en rupture.
PLATFORM_ID=""; PLATFORM_EMAIL=""; OPERATOR_TOKEN=""
_resolve_platform() {
  local row
  row="$(docker exec "${PGC:-echango_bff_postgres}" psql -U "${PGUSER:-bff_user}" \
    -d "${PGDB:-echango_bff}" -tAc \
    'SELECT id || E'"'"'\t'"'"' || email FROM "FleetAccount" WHERE "isPlatform" = true AND active = true;' \
    2>/dev/null)" || return 0
  [ -n "$row" ] || return 0
  # Plusieurs = le BFF refuse (`cash.platform_ambiguous`) ; ne pas en choisir un.
  [ "$(echo "$row" | wc -l)" -eq 1 ] || {
    fail "Plusieurs prestataires plateforme actifs — le BFF refusera toute clôture encaissée" \
         "$(echo "$row" | tr '\n' ' ')"
  }
  PLATFORM_ID="${row%%	*}"; PLATFORM_EMAIL="${row#*	}"
}
_resolve_platform

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
# L'identifiant du commerçant vient de SA connexion, et de nulle part ailleurs.
#
# Le déduire du registre du conducteur ne peut pas marcher : il y figure à côté
# des commerçants des runs précédents, et le distinguer par le montant est
# impossible — chaque run laisse une dette non soldée de la MÊME valeur (la
# seconde course du §6, jamais remise). Le script déclarait donc sa remise à
# l'ancien commerçant, et celui du run en cours n'avait rien à confirmer.
MERCHANT_ID="$(echo "$login" | jq -r '.user.id // empty')"
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
# La contrepartie du conducteur, et sa dette AVANT cette livraison.
#
# Relevée ici — après les sessions, avant toute écriture — parce que c'est le
# seul moment où elle décrit l'état d'entrée. Sur le pool, le compte plateforme
# est partagé entre exécutions : sans ce point de départ, le §4 lirait un cumul.
if [ -n "$PLATFORM_ID" ]; then
  COUNTERPARTY="$PLATFORM_ID"; COUNTERPARTY_LABEL="Echango ($PLATFORM_EMAIL)"
else
  COUNTERPARTY="$MERCHANT_ID"; COUNTERPARTY_LABEL="ce commerçant"
fi
DUE_BEFORE="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$COUNTERPARTY")")"
echo "   dette du conducteur envers $COUNTERPARTY_LABEL avant ce run : $DUE_BEFORE"

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
echo "$published" | is_error \
  && fail "Publication refusée" "$(echo "$published" | jq -c '.')"

after="$(mapi GET "/commercant/commandes/$ORDER_ID")"
[ "$(echo "$after" | jq -r '.status')" = "dispatched" ] \
  || fail "Après publication le statut doit être 'dispatched'" "$(echo "$after" | jq -c '.status, .adhoc, .dispatched')"
pass "Publiée — statut 'dispatched', course diffusée"

# ── 3. Le transporteur prend et livre ──────────────────────────────────────
step "3. Acceptation, démarrage, livraison"

FB_UUID="$(echo "$after" | jq -r '.uuid')"

accepted="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
echo "$accepted" | is_error \
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
echo "$completed" | is_error \
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
mtotal="$(ledger_total "$mledger")"
[ "$(amount_number "$mtotal")" = "$due" ] \
  || fail "Le commerçant doit voir $due dû, il voit $mtotal" "$(echo "$mledger" | jq -c '.')"
pass "Commerçant : $mtotal DZD détenus pour lui"

# ⚠️ On cherche la dette envers LE commerçant de ce run, et non la somme de
# toutes les contreparties du conducteur.
#
# Sommer supposait qu'il démarre à zéro : vrai au premier run, faux ensuite. Un
# conducteur réutilisé porte les dettes des runs précédents — constaté en réel,
# 2600 au lieu de 1300, sur un code parfaitement juste. Le contrôle mesurait le
# résidu de la base, pas ce que ce run venait de créer.
#
# La vérification côté commerçant, elle, est exacte sans précaution : chaque run
# crée un commerçant neuf. C'est bien pour ça qu'elle passait pendant que
# celle-ci échouait.
dledger="$(dapi GET /transporteur/caisse)"
# ⚠️ Même lecture que côté flotte, donc la même fonction — et pas une seconde
# écriture de `first(…)`, dont le piège est justement de ne RIEN rendre sur un
# flux vide. Le repli `.merchant_id` de la version précédente était mort : la
# projection pose `counterparty_id` sur toutes les lignes.
# La contrepartie et la dette de départ ont été résolues avant la livraison :
# les recalculer ici lirait l'état d'APRÈS, donc un delta nul.

# ⚠️ **Le DELTA, jamais le total — et c'est le même piège qu'au §4 d'origine.**
#
# Ce script note déjà que « un conducteur réutilisé porte les dettes des runs
# précédents — constaté en réel, 2600 au lieu de 1300, sur un code parfaitement
# juste ». La parade était de lire côté commerçant, neuf à chaque exécution.
#
# Le facilitateur de pool **rouvre exactement ce piège** : le compte plateforme
# est unique et partagé, donc la dette du conducteur envers Echango s'accumule
# d'un run à l'autre. Constaté au premier essai : 2600. On mesure donc ce que
# CETTE livraison ajoute, pas ce que la base contient.
dmine="$(amount_number "$(debt_toward "$dledger" "$COUNTERPARTY")")"
added=$((dmine - DUE_BEFORE))
[ "$added" = "$due" ] \
  || fail "Cette livraison doit ajouter $due à la dette envers $COUNTERPARTY_LABEL — elle en ajoute $added (avant $DUE_BEFORE, après $dmine)" \
     "$(echo "$dledger" | jq -c '.balances')"
pass "Transporteur : +$due DZD à remettre à $COUNTERPARTY_LABEL (total $dmine)"

# ⚠️ Et le conducteur retient bien sa course — même sur une chaîne à trois
# maillons. C'est ce qui distingue Echango d'une entreprise réelle : sa
# rémunération est un montant que nous connaissons (`isPlatform`), donc elle lui
# revient. Chez une entreprise il retiendrait 0 et devrait la totalité.
[ "$added" = "$((expected - FEE))" ] \
  || fail "Le conducteur devrait retenir sa course ($FEE) — cette livraison ajoute $added sur $expected perçus"
pass "Retenue de $FEE appliquée : Echango n'est pas un employeur"

details="$(mapi GET /commercant/encaissements/details)"
net="$(echo "$details" | jq -r '.data[0].net_amount // "absent"')"
ret="$(echo "$details" | jq -r '.data[0].retained_amount // "absent"')"
[ "$(amount_number "$ret")" = "$FEE" ] \
  || fail "Retenue attendue $FEE, reçue '$ret'" "$(echo "$details" | jq -c '.data[0]')"
pass "Détail : perçu $expected, retenu $ret, revient $net"

# ── 5. Remise et confirmation ──────────────────────────────────────────────
step "5. Remise"

# Vu du transporteur, la contrepartie est le commerçant — c'est `merchant_id`
# que `driverBalances()` projette. Le repli sur `counterparty_id` anticipe la
# généralisation aux entreprises (§4.1) : le jour où la contrepartie devient
# typée, ce script continuera de passer sans retouche.
# `MERCHANT_ID` vient de la connexion du commerçant (§ Sessions), jamais du
# registre du conducteur : c'est la seule source qui ne confond pas ce run avec
# les précédents.
[ -n "$MERCHANT_ID" ] || fail "Identifiant du commerçant introuvable" "$login"

# ⚠️ `merchantId` garde son nom dans le DTO — il est gelé par le contrôle de
# référence — mais désigne **la contrepartie**, que le serveur type lui-même.
declared="$(dapi POST /transporteur/caisse/remises \
  "$(jq -n --arg m "$COUNTERPARTY" --argjson a "$due" '{merchantId:$m, amount:$a}')")"
REMITTANCE_ID="$(echo "$declared" | jq -r '.id // empty')"
[ -n "$REMITTANCE_ID" ] || fail "Déclaration de remise refusée" "$(echo "$declared" | jq -c '.')"
pass "Remise de $due déclarée par le transporteur à $COUNTERPARTY_LABEL"

# ⚠️ Le contrôle qui donne son sens au registre : tant que l'autre partie n'a
# rien confirmé, une remise est une AFFIRMATION, pas un fait. La dette ne doit
# donc pas avoir bougé.
#
# Elle se lit **côté conducteur** : sur la chaîne à trois maillons, ce que le
# commerçant voit ne bouge pas du tout à cette étape — c'est le maillon interne
# qui se règle —, donc l'observer chez lui ne prouverait rien.
still="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$COUNTERPARTY")")"
[ "$still" = "$((DUE_BEFORE + due))" ] \
  || fail "Une remise NON confirmée ne doit pas réduire la dette (attendu $((DUE_BEFORE + due)), reçu $still)"
pass "Dette inchangée avant confirmation — c'est le point du modèle"

if [ -n "$PLATFORM_ID" ]; then
  # ── Chaîne à trois maillons : c'est l'OPÉRATEUR qui confirme ────────────
  #
  # ⚠️ Sans lui, la dette d'un conducteur du pool **ne s'éteindrait jamais** :
  # personne d'autre ne peut confirmer une remise faite à Echango. C'est le
  # coût nommé au §2.3 de `specs_facilitateur.md`, et il est réel.
  olog="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg e "$PLATFORM_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
  OPERATOR_TOKEN="$(echo "$olog" | jq -r '.token // empty')"
  [ -n "$OPERATOR_TOKEN" ] || fail \
    "Connexion de l'opérateur $PLATFORM_EMAIL impossible — sans elle, aucune remise au pool n'est confirmable.
   Fournir son mot de passe :  PASSWORD='<le bon>' $0 ${DRIVER_HINT:-}" "$olog"

  oapi() { # method path [body] — opérateur Echango, persona `fleet`
    local m="$1" p="$2" b="${3:-}"
    if [ -n "$b" ]; then
      curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $OPERATOR_TOKEN" -d "$b"
    else
      curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $OPERATOR_TOKEN"
    fi
  }

  confirmed="$(oapi POST "/flotte/caisse/remises/$REMITTANCE_ID/confirmer")"
  echo "$confirmed" | is_error \
    && fail "L'opérateur ne peut pas confirmer la remise" "$(echo "$confirmed" | jq -c '.')"
  after="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$PLATFORM_ID")")"
  # ⚠️ Retour à l'état d'ENTRÉE, pas à zéro : la remise porte sur cette
  # livraison, pas sur l'encours que le conducteur traîne des exécutions
  # précédentes. Exiger zéro ferait échouer le script au second passage, sur un
  # registre parfaitement juste.
  [ "$after" = "$DUE_BEFORE" ] \
    || fail "Après confirmation la dette doit revenir à $DUE_BEFORE — elle vaut $after"
  pass "Maillon interne soldé : les $due de cette livraison sont remis à Echango"

  # ── Second maillon : Echango remet au commerçant ────────────────────────
  #
  # C'est ici que le commerçant est enfin payé, et **c'est Echango qui le doit**
  # — pas le conducteur. Toute la décision du 31/07 tient dans cette ligne.
  before_m="$(amount_number "$(ledger_total "$(mapi GET /commercant/encaissements)")")"
  [ "$before_m" = "$due" ] \
    || fail "Le commerçant devrait attendre $due d'Echango, il voit $before_m"

  # ⚠️ `counterpartyId` ici, `merchantId` côté transporteur : les deux routes ne
  # nomment PAS le même champ pour la même chose. Celle du transporteur a gardé
  # `merchantId` par compatibilité — il est gelé par le contrôle de référence —,
  # celle de la flotte a été écrite après la généralisation et porte le nom
  # juste. Le deviner par analogie donne un `validation.failed` qui accuse la
  # donnée alors que c'est la clé qui est fausse.
  d2="$(oapi POST /flotte/caisse/remises \
    "$(jq -n --arg m "$MERCHANT_ID" --argjson a "$due" '{counterpartyId:$m, amount:$a}')")"
  R2="$(echo "$d2" | jq -r '.id // empty')"
  [ -n "$R2" ] || fail "Echango ne peut pas déclarer sa remise au commerçant" "$(echo "$d2" | jq -c '.')"

  c2="$(mapi POST "/commercant/encaissements/remises/$R2/confirmer")"
  echo "$c2" | is_error && fail "Le commerçant ne peut pas confirmer" "$(echo "$c2" | jq -c '.')"
  pass "Second maillon soldé : Echango a payé le commerçant"
else
  confirmed="$(mapi POST "/commercant/encaissements/remises/$REMITTANCE_ID/confirmer")"
  echo "$confirmed" | is_error \
    && fail "Confirmation refusée" "$(echo "$confirmed" | jq -c '.')"
fi

# Une dette soldée disparaît de `balances` (`filter(.debt != 0)`), donc la
# somme d'une liste vide vaut 0 — c'est bien ce qu'on veut lire.
final="$(ledger_total "$(mapi GET /commercant/encaissements)")"
[ "$(amount_number "$final")" = "0" ] \
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

# ── Le flux se PARCOURT, il ne se saute pas ────────────────────────────────
#
# Constaté en réel (30/07/2026) : juste après `demarrer`, la seule transition
# proposée est `enroute`, dont le champ `activities: ["completed"]` annonce la
# suivante. La clôture n'est donc jamais offerte d'emblée — il faut avancer
# d'un cran, redemander, et recommencer.
#
# C'est ce que fait l'application, et c'est pourquoi le script le fait aussi :
# poser directement une activité `completed` fabriquée passerait le test sans
# rien prouver. `updateActivity()` de Fleetbase commence par
# `if (!Utils::isActivity($activity)) return $this` — un objet inventé rend un
# 2xx et **n'a aucun effet** (journal, découverte n°3 du lot brouillon/publier).
#
# La borne à 6 sauts protège d'un flux qui boucle sur lui-même : sans elle, une
# configuration mal fermée ferait tourner le script indéfiniment.
next_activities() { echo "$(dapi GET "/transporteur/commandes/$1/activites-suivantes")"; }

# Normalise la réponse en tableau : elle est nue aujourd'hui, un `with` amont
# suffirait à l'envelopper.
as_activities() { jq -c 'if type == "array" then . else (.activities // .next_activity // .data // []) end'; }

terminal=""; hops=0; trail=""
while [ "$hops" -lt 6 ]; do
  acts="$(next_activities "$FB2" | as_activities)"
  terminal="$(echo "$acts" | jq -c '[.[] | select(.code == "completed")] | first // empty')"
  [ -z "$terminal" ] || break

  # Première transition non terminale proposée. On ne choisit pas : le serveur
  # n'en offre qu'une à la fois dans ce flux, et en préférer une autre serait
  # inventer un parcours.
  hop="$(echo "$acts" | jq -c '.[0] // empty')"
  [ -n "$hop" ] || fail "Le flux ne propose plus aucune transition et n'a pas abouti.
   Parcouru :$trail" "$(echo "$acts" | jq -c '.')"

  moved="$(dapi POST "/transporteur/commandes/$FB2/activite" \
    "$(jq -n --argjson a "$hop" '{activity:$a}')")"
  echo "$moved" | is_error \
    && fail "Transition « $(echo "$hop" | jq -r '.code') » refusée" "$(echo "$moved" | jq -c '.')"

  trail="$trail $(echo "$hop" | jq -r '.code') →"
  hops=$((hops + 1))
done

[ -n "$terminal" ] || fail "Clôture jamais proposée après $hops transitions.
   Parcouru :$trail"
pass "Flux parcouru :$trail completed"

# ⚠️ Le contrôle central : la clôture SANS déclaration doit être refusée sur ce
# chemin comme sur l'autre. C'est la garde qui était décorative.
refused="$(dapi POST "/transporteur/commandes/$FB2/activite" \
  "$(jq -n --argjson a "$terminal" '{activity:$a}')")"
echo "$refused" | is_error \
  || fail "Clôture SANS déclaration d'encaissement acceptée — la garde ne couvre pas ce chemin" \
     "$(echo "$refused" | jq -c '.')"
pass "Clôture sans déclaration refusée ($(echo "$refused" | jq -r '.code'))"

closed="$(dapi POST "/transporteur/commandes/$FB2/activite" \
  "$(jq -n --argjson a "$terminal" --argjson c "$expected" '{activity:$a, cash:{collectedAmount:$c}}')")"
echo "$closed" | is_error \
  && fail "Clôture par activité refusée" "$(echo "$closed" | jq -c '.')"

# La dette repart de zéro (soldée au §5), donc elle doit valoir exactement
# celle d'une course : c'est la preuve que l'encaissement a bien été écrit par
# ce chemin-là, et non hérité du précédent.
after2="$(ledger_total "$(mapi GET /commercant/encaissements)")"
[ "$(amount_number "$after2")" = "$due" ] \
  || fail "L'encaissement déclaré par /activite doit créer $due de dette, reçu $after2"
pass "Encaissement enregistré par /activite : $after2 DZD — les deux chemins écrivent bien"

echo
echo "════════════════════════════════════════════════════════════"
echo " Parcours complet validé — publication ET chaîne d'argent."
echo
echo " Marchandise $GOODS + course $FEE = $expected réclamés à la porte"
if [ -n "$PLATFORM_ID" ]; then
  echo " Transporteur retient $FEE, doit $due à ECHANGO, remet ;"
  echo " l'opérateur confirme, puis Echango remet $due au commerçant."
  echo
  echo " Forme à TROIS maillons — prestataire plateforme provisionné :"
  echo " $PLATFORM_EMAIL"
else
  echo " Transporteur retient $FEE, doit $due, remet, le commerçant confirme."
  echo
  echo " Forme à DEUX maillons — aucun prestataire plateforme provisionné."
  echo " ./scripts/provision-platform.sh <email> pour passer à trois."
fi
echo "════════════════════════════════════════════════════════════"
