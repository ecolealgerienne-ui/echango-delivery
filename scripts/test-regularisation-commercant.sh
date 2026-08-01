#!/usr/bin/env bash
#
# La régularisation par le commerçant — et l'inversion de règle qu'elle porte.
#
# ── Le trou que cette fonctionnalité bouche ───────────────────────────────
#
# `CashCollection` n'a **qu'un seul chemin d'écriture** : la clôture par l'app
# du transporteur. Une course close depuis la console Fleetbase — ce que fait un
# opérateur, et ce qui arrive — n'y laisse donc rien. Le commerçant voit une
# livraison terminée, de l'argent réclamé à la porte, et **0 DZD au registre**.
#
# On ne peut pas inventer l'encaissement : un montant supposé serait pire que
# rien. La réponse retenue le 30/07/2026 est donc de laisser le commerçant
# **déclarer**, et le transporteur **confirmer**.
#
# ── L'inversion, qui est tout l'objet de ce script ────────────────────────
#
# Le registre repose sur un principe : une déclaration unilatérale ne vaut rien,
# la dette naît de la confirmation. Sauf que la règle **s'inverse selon qui
# déclare**, et c'est contre-intuitif :
#
#   * le TRANSPORTEUR qui déclare s'attribue **sa propre** dette. Nul ne ment
#     pour se rendre débiteur : la ligne compte immédiatement, sans confirmation.
#   * le COMMERÇANT qui déclare engage **quelqu'un d'autre**. La ligne ne compte
#     donc qu'une fois confirmée.
#
# D'où la clause de `debtBetween()` :
#
#     OR: [ { declaredBy: 'driver' }, { confirmedAt: { not: null } } ]
#
# ⚠️ **Le piège de migration qu'elle évite**, et c'est le vrai motif de sa
# forme : filtrer sur le seul `confirmedAt: { not: null }` aurait fait
# disparaître **toutes les dettes existantes** — les lignes écrites avant ce
# lot naissent avec ce champ vide. La clause porte sur le DÉCLARANT, pas sur la
# confirmation seule.
#
# ── Ce que le script prouve, dans l'ordre ────────────────────────────────
#
#   1. une course close HORS de l'app ne laisse rien au registre ;
#   2. le commerçant peut la déclarer ;
#   3. **la dette ne bouge pas** — c'est le contrôle qui compte, et le seul qui
#      distingue cette règle de celle du transporteur ;
#   4. le transporteur confirme, et **alors seulement** la dette apparaît ;
#   5. la rémunération naît **à la confirmation**, jamais à la déclaration :
#      l'écrire avant produirait une dette NÉGATIVE, c'est-à-dire un commerçant
#      débiteur pour avoir signalé un oubli.
#
# ── Comment la course est close hors de l'app ─────────────────────────────
#
# Par l'API publique `v1` de Fleetbase, avec la clé de service — le même chemin
# que la console. Le BFF n'est jamais appelé, donc `settleCashIfDue()` ne tourne
# pas, et aucun `CashCollection` n'est écrit. C'est la seule façon de reproduire
# fidèlement le cas réel plutôt que de le simuler en supprimant une ligne.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-regularisation-commercant.sh                 # un conducteur
#   ./scripts/test-regularisation-commercant.sh alice@test.dz   # ou email, tél, nom
#
#   BFF_URL=http://localhost:3001   adresse du BFF
#   GOODS=1300 FEE=650              montants joués

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

is_error() { jq -e 'type == "object" and ((.statusCode | type) == "number")' >/dev/null 2>&1; }

expect_refusal() { # libellé code_attendu réponse
  local label="$1" want="$2" body="$3" got
  echo "$body" | is_error || fail "$label : la requête a RÉUSSI, or elle doit être refusée" "$(echo "$body" | jq -c '.')"
  got="$(echo "$body" | jq -r '.code // empty')"
  [ "$got" = "$want" ] || fail "$label : refusé pour '$got', attendu '$want'" "$(echo "$body" | jq -c '.')"
  pass "$label — refusé ($want)"
}

mapi() { # commerçant
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BFF_URL$p" -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $MERCHANT_TOKEN" -d "$b"
  else
    curl -sS -X "$m" "$BFF_URL$p" -H "Authorization: Bearer $MERCHANT_TOKEN"
  fi
}

dapi() { # conducteur
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
echo "La course sera close HORS de l'app, pour qu'aucun encaissement ne soit enregistré."

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"
. "$(dirname "$0")/lib/free-driver.sh"
. "$(dirname "$0")/lib/ledger.sh"

SUFFIX="$(date +%s)"
EXPECTED=$((GOODS + FEE))

# ── 0. Les acteurs ─────────────────────────────────────────────────────────
#
# Le conducteur d'abord : ce qui peut refuser passe devant ce qui écrit.
step "0. Les acteurs"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"
require_free_driver

MERCHANT_EMAIL="reg-m-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Regul", firstName:"Test",
    lastName:"Regul", phone:"+213555000000", businessPhone:"+213555000000"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription commerçant doit être mise en attente (HTTP $status)" "$body"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" \
  || fail "Activation du commerçant impossible : ${FLEETBASE_ERROR:-}"
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
MERCHANT_ID="$(echo "$mlogin" | jq -r '.user.id // empty')"
[ -n "$MERCHANT_TOKEN" ] && [ -n "$MERCHANT_ID" ] \
  || fail "Connexion commerçant refusée après activation" "$mlogin"
pass "Commerçant : $MERCHANT_EMAIL ($MERCHANT_ID)"

# ── 1. Une course encaissée, publiée, prise ────────────────────────────────
step "1. Course encaissée, publiée, prise par le conducteur"

order="$(mapi POST /commercant/commandes "$(jq -n \
  --argjson goods "$GOODS" --argjson fee "$FEE" '{
  pickupLocationName: "Commerce Regul", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
  pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
  dropoffLocationName: "Client Regul", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
  dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
  price: $fee, codAmount: $goods, codIncludesDelivery: false,
  podMethod: "aucune", preferFavourites: false, draft: true
}')")"
ORDER_ID="$(echo "$order" | jq -r '.id // .uuid // empty')"
[ -n "$ORDER_ID" ] || fail "Création refusée" "$(echo "$order" | jq -c '.')"

cod="$(mapi GET "/commercant/commandes/$ORDER_ID" | jq -r '.meta.cod_amount // "absent"')"
[ "$cod" = "$EXPECTED" ] || fail "À encaisser attendu $EXPECTED, reçu '$cod'"

published="$(mapi POST "/commercant/commandes/$ORDER_ID/publier")"
echo "$published" | is_error && fail "Publication refusée" "$(echo "$published" | jq -c '.')"
FB_UUID="$(mapi GET "/commercant/commandes/$ORDER_ID" | jq -r '.uuid')"
pass "Publiée : $EXPECTED à encaisser"

accepted="$(dapi POST "/transporteur/commandes/$FB_UUID/accepter")"
echo "$accepted" | is_error && fail "Acceptation refusée" "$(echo "$accepted" | jq -c '.')"

# ⚠️ **`demarrer` n'est pas toujours à appeler**, et l'appeler à l'aveugle
# échoue. Sur une course du pool, `accepter` a déjà déclenché le démarrage côté
# Fleetbase — qui répond alors « Order has already started. », relayé en
# `order.start_failed`. On lit donc l'état plutôt que de le supposer.
#
# Ne PAS traiter ce refus comme bénin : le distinguer d'un vrai échec de
# démarrage demande de savoir où en est la course, pas d'ignorer une erreur.
# ⚠️ L'état se lit par la vue COMMERÇANT du BFF, pas par `fb_get` : la route
# `int/v1/orders/{uuid}` n'expose pas `status` à sa racine, et un `// empty`
# rendait une chaîne vide qu'aucun `case` ne reconnaissait — donc le contrôle
# retombait dans la branche « démarrer », qui est exactement ce qu'il devait
# éviter. Lire ne déclenche aucune écriture de caisse ; seule la CLÔTURE, plus
# bas, doit contourner le BFF.
order_status() { mapi GET "/commercant/commandes/$ORDER_ID" | jq -r '.status // empty'; }

st="$(order_status)"
[ -n "$st" ] || fail "Statut illisible après acceptation"
case "$st" in
  started|enroute|completed)
    pass "Course acceptée — déjà démarrée par l'acceptation (statut '$st')" ;;
  *)
    started="$(dapi POST "/transporteur/commandes/$FB_UUID/demarrer")"
    echo "$started" | is_error && fail "Démarrage refusé (statut '$st')" "$(echo "$started" | jq -c '.')"
    pass "Course acceptée et démarrée" ;;
esac

# ── 2. Clôture HORS de l'app ───────────────────────────────────────────────
step "2. La course est close hors de l'app — comme depuis la console"

# ⚠️ Le flux **se parcourt, il ne se saute pas** : `updateActivity()` commence
# par `if (!Utils::isActivity($activity)) return $this` et répond 2xx **sans
# effet** si on lui passe un objet fabriqué. Poser directement un `completed`
# rendrait donc le script vert sans rien avoir clos — et l'étape suivante
# constaterait « pas d'encaissement », ce qui est justement ce qu'on veut
# observer. Le faux succès serait indiscernable du vrai.
# ⚠️ Enveloppe TOLÉRÉE, mais nommée : Fleetbase rend tantôt l'objet à la racine,
# tantôt sous `order` ou `data` selon la route. Un `.public_id` seul rendait
# vide, et le script accusait ensuite l'absence d'identifiant au lieu de la
# forme de la réponse.
FB_ORDER="$(fb_get "/int/v1/orders/$FB_UUID")" \
  || fail "Lecture de la commande impossible" "${FLEETBASE_ERROR:-}"
PUBLIC_ID="$(echo "$FB_ORDER" | jq -r '(.public_id // .order.public_id // .data.public_id) // empty')"
[ -n "$PUBLIC_ID" ] \
  || fail "public_id introuvable — update-activity en a besoin" "$(echo "$FB_ORDER" | jq -c 'keys')"

hops=0
while :; do
  hops=$((hops + 1))
  [ "$hops" -le 6 ] || fail "Le flux ne converge pas vers 'completed' en 6 étapes"

  st="$(order_status)"
  [ -n "$st" ] || fail "Statut illisible pendant la clôture"
  [ "$st" = "completed" ] && break

  nexts="$(fb_get "/v1/orders/$PUBLIC_ID/next-activity")" \
    || fail "next-activity injouable" "${FLEETBASE_ERROR:-}"
  act="$(echo "$nexts" | jq -c 'if type=="array" then .[0] else (.activities[0]? // .next_activity? // .data[0]? // empty) end')"
  [ -n "$act" ] && [ "$act" != "null" ] \
    || fail "Aucune activité proposée depuis '$st'" "$(echo "$nexts" | jq -c '.')"

  # L'objet activité ENTIER, tel que Fleetbase le rend — jamais reconstruit.
  fb_api POST "/v1/orders/$PUBLIC_ID/update-activity" "$(jq -n --argjson a "$act" '{activity:$a}')" >/dev/null \
    || fail "update-activity refusée" "${FLEETBASE_ERROR:-}"
done
pass "Course close côté Fleetbase en $hops étape(s), sans passer par le BFF"

# ── 3. Le trou ─────────────────────────────────────────────────────────────
step "3. Livrée, et rien au registre"

# C'est l'état que la fonctionnalité existe pour traiter, et il n'avait jamais
# été produit par un contrôle.
coll="$(mapi GET /commercant/encaissements/details)"
echo "$coll" | is_error && fail "Lecture des encaissements impossible" "$(echo "$coll" | jq -c '.')"
found="$(echo "$coll" | jq -r --arg u "$FB_UUID" '[.data[]? | select(.order_uuid == $u)] | length')"
[ "$found" = "0" ] \
  || fail "Un encaissement existe déjà : la course n'a pas été close hors de l'app" \
          "$(echo "$coll" | jq -c '.data')"
pass "Aucun encaissement enregistré, comme attendu"

# ⚠️ La dette se lit du côté du CONDUCTEUR, et la contrepartie est celle du POOL.
#
# Côté commerçant, la contrepartie est l'identifiant du **compte Echango** du
# conducteur, que ce script n'a pas : il ne connaît que l'uuid Fleetbase. Le lui
# passer quand même rendait « aucune » à tous les coups — donc « la dette n'a
# pas bougé » était vrai avant ET après la confirmation, et le contrôle central
# de ce scénario passait **à vide**. Un identifiant qui ne correspond à rien ne
# produit pas d'erreur, il produit un zéro rassurant (règle 10).
#
# ⚠️ **Et ce n'est pas `MERCHANT_ID`** — c'était le miroir, dans l'outillage, du
# défaut C2 de la revue du 01/08/2026. Le module commerçant rendait `null` sur
# une course du pool là où le module transporteur rendait Echango : une même
# livraison créait donc deux contreparties selon qu'elle était close par l'app
# ou régularisée ici. Ce script, écrit contre le chemin fautif, lisait la jambe
# conducteur ↔ commerçant. Depuis que la résolution est unique, cette jambe est
# vide et le contrôle rendait 0 sur un registre parfaitement juste.
#
# `fb_pool_counterparty` est ce que `test-parcours-argent.sh` interroge déjà :
# une seule façon de savoir à qui le conducteur doit, dans les deux scripts
# (règle 5).
#
# ⚠️ **Résolue hors de toute substitution de commande.** `fb_pool_counterparty`
# renseigne `COUNTERPARTY_LABEL` dans le shell où elle s'exécute : appelée en
# `$(...)`, l'étiquette meurt avec le sous-shell — et un `fail()` déclenché là
# n'arrêterait que lui, laissant `set -e` tuer le script sans un mot. C'est le
# défaut déjà payé deux fois dans ce dépôt (`RESOLVE_DRIVER_ERROR`, la lecture
# des courses bloquantes). `fb_resolve_platform` puis une affectation simple,
# exactement comme le fait `test-parcours-argent.sh`.
fb_resolve_platform || fail "Contrepartie du pool indéterminable" "${FLEETBASE_ERROR:-}"
if [ -n "$PLATFORM_ID" ]; then
  COUNTERPARTY="$PLATFORM_ID"; COUNTERPARTY_LABEL="Echango ($PLATFORM_EMAIL)"
else
  COUNTERPARTY="$MERCHANT_ID"; COUNTERPARTY_LABEL="ce commerçant"
fi
echo "   contrepartie du conducteur sur une course du pool : $COUNTERPARTY_LABEL"

# Un commerçant NEUF est créé à chaque exécution — mais sur le pool, le compte
# plateforme est PARTAGÉ entre exécutions : d'où ce point de départ, sans lequel
# le §7 lirait un cumul au lieu de la dette de cette livraison.
DEBT_BEFORE="$(debt_toward "$(dapi GET /transporteur/caisse)" "$COUNTERPARTY")"
echo "   dette du conducteur envers CE commerçant, avant régularisation : $DEBT_BEFORE"

# ── 4. Le commerçant déclare ───────────────────────────────────────────────
step "4. Le commerçant déclare l'encaissement"

decl="$(mapi POST "/commercant/commandes/$FB_UUID/encaissement" \
  "$(jq -n --argjson c "$EXPECTED" '{collectedAmount:$c}')")"
echo "$decl" | is_error && fail "Déclaration refusée" "$(echo "$decl" | jq -c '.')"
[ "$(echo "$decl" | jq -r '.pending')" = "true" ] \
  || fail "Une déclaration du commerçant doit naître EN ATTENTE" "$decl"
pass "Déclaré $EXPECTED — en attente de confirmation"

# Déclarer deux fois se dit, plutôt que d'être absorbé en silence.
twice="$(mapi POST "/commercant/commandes/$FB_UUID/encaissement" \
  "$(jq -n --argjson c "$EXPECTED" '{collectedAmount:$c}')")"
expect_refusal "Déclarer une seconde fois" "cash.collection_already_declared" "$twice"

# ── 5. LE contrôle qui distingue cette règle de l'autre ───────────────────
step "5. La dette ne bouge pas tant que le transporteur n'a pas confirmé"

# ⚠️ **C'est le seul contrôle qui prouve l'inversion.** Une déclaration du
# TRANSPORTEUR compterait immédiatement ; celle du commerçant engage quelqu'un
# d'autre, donc elle ne compte pas encore. Un script qui vérifierait seulement
# « la dette apparaît après confirmation » passerait au vert même si elle était
# déjà comptée avant.
DEBT_DECLARED="$(debt_toward "$(dapi GET /transporteur/caisse)" "$COUNTERPARTY")"
[ "$DEBT_DECLARED" = "$DEBT_BEFORE" ] \
  || fail "La dette a bougé sur une simple déclaration du commerçant : $DEBT_BEFORE → $DEBT_DECLARED"
pass "Dette inchangée ($DEBT_DECLARED) — une déclaration unilatérale n'engage personne"

# ⚠️ Et la ligne EXISTE bel et bien, en attente. Sans ce second contrôle,
# « la dette n'a pas bougé » serait aussi vrai si la déclaration n'avait rien
# écrit du tout — on vérifierait alors l'échec de l'étape précédente, pas la
# règle qu'on croit tester.
row="$(mapi GET /commercant/encaissements/details \
  | jq -c --arg u "$FB_UUID" '.data[]? | select(.order_uuid == $u)')"
[ -n "$row" ] || fail "La déclaration n'a laissé aucune ligne au registre"
[ "$(echo "$row" | jq -r '.declared_by')" = "merchant" ] \
  || fail "La ligne devrait être déclarée par 'merchant'" "$row"
[ "$(echo "$row" | jq -r '.confirmed_at')" = "null" ] \
  || fail "La ligne ne doit pas encore être confirmée" "$row"
pass "La ligne existe, déclarée par le commerçant, non confirmée"

# ── 6. La confirmation ─────────────────────────────────────────────────────
step "6. Le transporteur confirme"

# L'identifiant de la ligne vient de SA liste : c'est lui qui doit la retrouver.
CID="$(dapi GET /transporteur/caisse/encaissements \
  | jq -r --arg u "$FB_UUID" '.data[]? | select(.order_uuid == $u) | .id' | head -1)"
[ -n "$CID" ] \
  || fail "Le transporteur ne voit pas l'encaissement déclaré par le commerçant" \
          "$(dapi GET /transporteur/caisse/encaissements | jq -c '.data')"
pass "Le transporteur voit la déclaration ($CID)"

conf="$(dapi POST "/transporteur/caisse/encaissements/$CID/confirmer")"
echo "$conf" | is_error && fail "Confirmation refusée" "$(echo "$conf" | jq -c '.')"
pass "Confirmé"

# Confirmer deux fois se refuse.
again="$(dapi POST "/transporteur/caisse/encaissements/$CID/confirmer")"
expect_refusal "Confirmer une seconde fois" "cash.collection_already_confirmed" "$again"

# ── 7. La dette naît, et la rémunération avec elle ────────────────────────
step "7. La dette apparaît — et la rémunération naît au même instant"

DEBT_AFTER="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$COUNTERPARTY")")"

# ⚠️ **Le montant, et pas seulement le mouvement.** Sur une course du pool la
# rémunération revient au conducteur : il retient FEE et ne doit que GOODS.
# Une dette égale au total perçu signifierait que la rémunération n'a PAS été
# écrite — exactement le défaut que « la rémunération naît à la confirmation »
# corrige, et qui produirait sinon une dette négative une fois la retenue
# appliquée. C'est l'ÉCART entre le perçu et la dette qui prouve la retenue.
# ⚠️ En **delta**, pas en absolu : sur le pool la contrepartie est le compte
# plateforme, partagé entre exécutions, donc une valeur absolue ne tiendrait
# qu'au premier passage. C'est la leçon déjà payée trois fois sur les autres
# scénarios d'argent.
DEBT_DELTA="$(awk -v a="$DEBT_AFTER" -v b="$(amount_number "$DEBT_BEFORE")" 'BEGIN{printf "%.0f", a-b}')"
[ "$DEBT_DELTA" = "$GOODS" ] \
  || fail "Dette attendue $GOODS (soit $EXPECTED perçus − $FEE de rémunération), obtenue $DEBT_DELTA" \
          "avant $DEBT_BEFORE, après $DEBT_AFTER, contrepartie $COUNTERPARTY_LABEL"
pass "Le conducteur doit $DEBT_AFTER — la retenue de $FEE est appliquée"

# Vue du commerçant, la même course, ligne par ligne. `retained_amount` vient de
# `DriverEarning` : s'il vaut 0, la rémunération n'a pas été enregistrée, et la
# dette ci-dessus serait fausse pour la même raison.
row="$(mapi GET /commercant/encaissements/details \
  | jq -c --arg u "$FB_UUID" '.data[]? | select(.order_uuid == $u)')"
[ -n "$row" ] || fail "La ligne a disparu du registre après confirmation"
[ "$(echo "$row" | jq -r '.confirmed_at')" != "null" ] \
  || fail "La ligne n'est pas marquée confirmée" "$row"
[ "$(amount_number "$(echo "$row" | jq -r '.retained_amount')")" = "$FEE" ] \
  || fail "Retenue attendue $FEE" "$row"
[ "$(amount_number "$(echo "$row" | jq -r '.net_amount')")" = "$GOODS" ] \
  || fail "Ce qui revient au commerçant devrait être $GOODS" "$row"
pass "Détail commerçant : perçu $EXPECTED, retenu $FEE, revient $GOODS"

echo
echo "════════════════════════════════════════════════════════════════"
pass "Régularisation par le commerçant vérifiée de bout en bout."
echo "   Course close hors de l'app  → aucun encaissement"
echo "   Déclarée par le commerçant  → dette INCHANGÉE ($DEBT_BEFORE)"
echo "   Confirmée par le conducteur → dette $DEBT_AFTER, retenue $FEE appliquée"
echo "   La règle s'inverse selon qui déclare, et c'est vérifié."
