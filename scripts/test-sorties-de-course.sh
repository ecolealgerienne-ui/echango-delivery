#!/usr/bin/env bash
#
# Les SORTIES d'une course : refus, échec de livraison, annulation.
#
# ── Ce que ces trois ont en commun ────────────────────────────────────────
#
# Ce sont les trois façons dont une course **finit sans être livrée**. Tous les
# autres scénarios du dépôt jouent le chemin heureux jusqu'au bout ; ceux-ci
# n'avaient jamais tourné, alors qu'ils portent chacun un défaut déjà corrigé
# une fois — donc chacun peut se re-casser sans que rien ne le dise.
#
# ── Pourquoi un seul script pour trois sorties ───────────────────────────
#
# Le principe du dépôt est de séparer ce qui rendrait un échec ambigu. Ici la
# séparation est déjà faite **par la course** : chaque partie a la sienne, créée
# et menée à son propre état. Un échec dans la partie 2 ne dit rien de la 1, et
# le libellé le montre.
#
# La raison de ne pas en faire trois fichiers est concrète : le BFF plafonne les
# inscriptions à **10 par heure**. Trois scripts, c'est trois commerçants — donc
# une suite complète qui ne peut plus se rejouer deux fois d'affilée.
#
# ── Partie 1 — le refus motivé ───────────────────────────────────────────
#
# Deux effets selon l'origine, et c'est la distinction qui compte :
#
#   * une course **assignée** et refusée est **détachée et remise en diffusion**
#     — sinon une course confiée à un favori indisponible resterait bloquée ;
#   * une course **déjà démarrée** ne se refuse pas : la sortie est le
#     signalement d'échec, qui laisse une trace (`order.already_started`).
#
# Le motif est enregistré **avec une copie des entrées tarifaires** : c'est
# l'appariement « ce qui était offert / refusé pour tel motif » qui construira le
# barème, et il disparaîtrait avec la commande si on se contentait d'y référer.
#
# ── Partie 2 — l'échec de livraison ──────────────────────────────────────
#
# ⚠️ **Fleetbase n'a pas de statut « échec ».** Une course dont l'échec est
# signalé reste **assignée et non terminale**. Sans lire le signalement dans
# notre propre table, `driverIsBusy` répondrait `true` pour toujours : un client
# absent immobiliserait le conducteur **à vie**, pour toutes les entreprises, et
# le déblocage demanderait un passage en console.
#
# C'est le défaut corrigé le 31/07/2026, et **c'est la vraie assertion de cette
# partie** : après un signalement, le conducteur doit pouvoir prendre une autre
# course. Vérifier seulement que le signalement s'enregistre laisserait le défaut
# revenir sans bruit.
#
# ── Partie 3 — l'annulation par le commerçant ────────────────────────────
#
# Autorisée tant que personne n'est en route, refusée après (`order.cancel_not_allowed`).
# La garde porte sur l'état **réel** lu chez Fleetbase, pas sur le cache — celui-ci
# était figé à `pending` depuis la création, donc une garde branchée dessus
# aurait laissé annuler une course déjà démarrée.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-sorties-de-course.sh [conducteur]
#
#   BFF_URL=http://localhost:3001
#   UNBLOCK=1   libère le conducteur avant de commencer

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

expect_refusal() { # libellé code réponse
  local label="$1" want="$2" body="$3" got
  echo "$body" | is_error || fail "$label : la requête a RÉUSSI, or elle doit être refusée" "$(echo "$body" | jq -c '.')"
  got="$(echo "$body" | jq -r '.code // empty')"
  [ "$got" = "$want" ] || fail "$label : refusé pour '$got', attendu '$want'" "$(echo "$body" | jq -c '.')"
  pass "$label — refusé ($want)"
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

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"
. "$(dirname "$0")/lib/free-driver.sh"

SUFFIX="$(date +%s)"

# Crée une commande et rend "ORDER_ID FB_UUID" sur stdout. `publish` vaut 1 pour
# publier dans la foulée.
create_order() { # publish
  local publish="$1" o oid uuid pub
  o="$(mapi POST /commercant/commandes "$(jq -n --argjson g "$GOODS" --argjson f "$FEE" '{
    pickupLocationName: "Commerce Sorties", pickupLatitude: 36.7538, pickupLongitude: 3.0588,
    pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
    dropoffLocationName: "Client Sorties", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
    dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
    price: $f, codAmount: $g, codIncludesDelivery: false,
    podMethod: "aucune", preferFavourites: false, draft: true }')")"
  oid="$(echo "$o" | jq -r '.id // .uuid // empty')"
  [ -n "$oid" ] || { echo "CREATE_FAILED $(echo "$o" | jq -c '.')" >&2; return 1; }

  if [ "$publish" = "1" ]; then
    pub="$(mapi POST "/commercant/commandes/$oid/publier")"
    echo "$pub" | is_error && { echo "PUBLISH_FAILED $(echo "$pub" | jq -c '.')" >&2; return 1; }
  fi

  uuid="$(mapi GET "/commercant/commandes/$oid" | jq -r '.uuid')"
  printf '%s %s' "$oid" "$uuid"
}

order_status() { mapi GET "/commercant/commandes/$1" | jq -r '.status // empty'; }

echo "BFF : $BFF_URL"
echo "Trois sorties : refus motivé, échec de livraison, annulation."

# ── 0. Les acteurs ─────────────────────────────────────────────────────────
step "0. Les acteurs"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"
require_free_driver

MERCHANT_EMAIL="sorties-m-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Sorties", firstName:"Test",
    lastName:"Sorties", phone:"+213555000000", businessPhone:"+213555000000"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription doit être mise en attente (HTTP $status)" "$body"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" || fail "Activation impossible : ${FLEETBASE_ERROR:-}"
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
MERCHANT_ID="$(echo "$mlogin" | jq -r '.user.id // empty')"
[ -n "$MERCHANT_TOKEN" ] && [ -n "$MERCHANT_ID" ] || fail "Connexion commerçant refusée" "$mlogin"
pass "Commerçant NEUF : $MERCHANT_EMAIL"

# ══════════════════════════════════════════════════════════════════════════
# PARTIE 1 — LE REFUS MOTIVÉ
# ══════════════════════════════════════════════════════════════════════════
step "1. Refus motivé d'une course acceptée"

read -r O1 FB1 <<<"$(create_order 1)" || fail "Création de la course 1 impossible"
acc="$(dapi POST "/transporteur/commandes/$FB1/accepter")"
echo "$acc" | is_error && fail "Acceptation refusée" "$(echo "$acc" | jq -c '.')"
pass "Course 1 acceptée"

# ⚠️ **Une course DÉMARRÉE ne se refuse pas.** Sur le pool, `accepter` démarre
# déjà la course — c'est donc le cas par défaut ici, et le refus doit être
# repoussé vers le signalement d'échec.
st="$(order_status "$O1")"
if [ "$st" = "started" ] || [ "$st" = "enroute" ]; then
  refused="$(dapi POST "/transporteur/commandes/$FB1/refuser" \
    "$(jq -n '{reason:"prix_insuffisant"}')")"
  expect_refusal "Refuser une course déjà démarrée (statut '$st')" "order.already_started" "$refused"
  pass "La sortie d'une course démarrée est l'échec de livraison, pas le refus"
else
  refused="$(dapi POST "/transporteur/commandes/$FB1/refuser" \
    "$(jq -n '{reason:"prix_insuffisant", notes:"trop bas pour la distance"}')")"
  echo "$refused" | is_error && fail "Refus impossible" "$(echo "$refused" | jq -c '.')"
  pass "Course refusée avec motif"

  # Détachée ET remise en diffusion : sans quoi une course confiée à un favori
  # indisponible resterait bloquée pour tout le monde.
  after="$(fb_get "/int/v1/orders/$FB1")" || fail "Relecture impossible" "${FLEETBASE_ERROR:-}"
  drv="$(echo "$after" | jq -r '(.driver_assigned_uuid // .order.driver_assigned_uuid) // "null"')"
  [ "$drv" = "null" ] \
    || fail "La course refusée porte encore un conducteur ($drv) — elle n'a pas été détachée"
  pass "Détachée et remise au pool"
fi

# Un motif hors liste est refusé par le DTO : la liste est FERMÉE, et c'est ce
# qui rend les motifs comptables pour le futur barème.
bogus="$(dapi POST "/transporteur/commandes/$FB1/refuser" "$(jq -n '{reason:"parce_que"}')")"
expect_refusal "Motif de refus hors liste" "validation.failed" "$bogus"

# ══════════════════════════════════════════════════════════════════════════
# PARTIE 2 — L'ÉCHEC DE LIVRAISON
# ══════════════════════════════════════════════════════════════════════════
step "2. Échec de livraison — et le conducteur doit rester utilisable"

read -r O2 FB2 <<<"$(create_order 1)" || fail "Création de la course 2 impossible"
acc="$(dapi POST "/transporteur/commandes/$FB2/accepter")"
echo "$acc" | is_error && fail "Acceptation refusée" "$(echo "$acc" | jq -c '.')"
pass "Course 2 acceptée"

bogus="$(dapi POST "/transporteur/commandes/$FB2/echec" "$(jq -n '{reason:"la_flemme"}')")"
expect_refusal "Motif d'échec hors liste" "validation.failed" "$bogus"

failed="$(dapi POST "/transporteur/commandes/$FB2/echec" \
  "$(jq -n '{reason:"client_absent", notes:"personne à la porte, deux appels sans réponse"}')")"
echo "$failed" | is_error && fail "Signalement d'échec refusé" "$(echo "$failed" | jq -c '.')"
pass "Échec signalé : client_absent"

# Le signalement est relu là où l'app le lit, et le motif conservé.
detail="$(dapi GET "/transporteur/commandes/$FB2")"
seen="$(echo "$detail" | jq -r '(.delivery_failure.reason // .delivery_failure[0].reason) // empty')"
[ "$seen" = "client_absent" ] \
  || fail "Le signalement n'est pas relu sur la fiche" "$(echo "$detail" | jq -c '.delivery_failure')"
pass "Motif conservé et relu sur la fiche"

# ⚠️ **L'assertion qui compte.** Fleetbase n'a pas de statut « échec » : la
# course reste assignée et non terminale. Si `driverIsBusy` ne lisait pas notre
# signalement, le conducteur serait immobilisé À VIE par un simple client absent.
read_blocking_orders
if echo "$BLOCKING" | grep -q "$FB2"; then
  fail "La course en échec bloque encore le conducteur — un client absent l'immobiliserait à vie" \
       "$(echo "$BLOCKING" | tr '\n' ' ')"
fi
pass "La course en échec ne bloque plus le conducteur"

# Preuve par l'usage, et non par la seule lecture du prédicat : il doit pouvoir
# en prendre une autre.
read -r O3 FB3 <<<"$(create_order 1)" || fail "Création de la course 3 impossible"
acc="$(dapi POST "/transporteur/commandes/$FB3/accepter")"
echo "$acc" | is_error \
  && fail "Le conducteur ne peut pas prendre une nouvelle course après un échec" \
          "$(echo "$acc" | jq -c '.')"
pass "Il peut prendre une autre course — le déblocage est réel, pas seulement lisible"

# ══════════════════════════════════════════════════════════════════════════
# PARTIE 3 — L'ANNULATION PAR LE COMMERÇANT
# ══════════════════════════════════════════════════════════════════════════
step "3. Annulation — permise avant le départ, refusée après"

# La course 3 vient d'être acceptée, donc démarrée : l'annulation doit être
# refusée. La garde porte sur l'état RÉEL lu chez Fleetbase — branchée sur le
# cache, figé à `pending` depuis la création, elle aurait laissé passer.
st3="$(order_status "$O3")"
late="$(mapi POST "/commercant/commandes/$O3/annuler")"
expect_refusal "Annuler une course en cours (statut '$st3')" "order.cancel_not_allowed" "$late"

# Une course publiée que personne n'a prise s'annule.
read -r O4 FB4 <<<"$(create_order 1)" || fail "Création de la course 4 impossible"
early="$(mapi POST "/commercant/commandes/$O4/annuler")"
echo "$early" | is_error && fail "Annulation d'une course libre refusée" "$(echo "$early" | jq -c '.')"
[ "$(order_status "$O4")" = "canceled" ] \
  || fail "Après annulation le statut devrait être 'canceled', il vaut '$(order_status "$O4")'"
pass "Course libre annulée"

# Annuler deux fois se dit.
twice="$(mapi POST "/commercant/commandes/$O4/annuler")"
expect_refusal "Annuler une seconde fois" "order.already_terminal" "$twice"

# Un brouillon aussi s'annule — c'est le cas le plus banal, et il n'était couvert
# nulle part.
read -r O5 FB5 <<<"$(create_order 0)" || fail "Création du brouillon impossible"
draft="$(mapi POST "/commercant/commandes/$O5/annuler")"
echo "$draft" | is_error && fail "Annulation d'un brouillon refusée" "$(echo "$draft" | jq -c '.')"
pass "Brouillon annulé"

# ── Ménage ─────────────────────────────────────────────────────────────────
#
# ⚠️ **Toutes les courses restées en cours, pas seulement la dernière.**
#
# Première version : seule la course 3 était annulée, et le contrôle final
# affichait « Reste : … started » — la course 1, acceptée puis seulement refusée
# (le refus étant repoussé sur une course démarrée), n'était jamais close. Le
# script laissait donc le conducteur bloqué, exactement le défaut qui a fait
# extraire `require_free_driver` en bibliothèque quelques heures plus tôt.
#
# On ne nomme donc pas les courses à annuler — on **relit celles qui bloquent**
# et on les annule toutes. Une liste écrite à la main vieillit à chaque partie
# ajoutée ; la relecture, non.
step "Ménage"
read_blocking_orders
if [ -n "$BLOCKING" ]; then
  while read -r uuid _; do
    [ -n "$uuid" ] || continue
    fb_api PATCH /int/v1/orders/cancel "$(jq -n --arg o "$uuid" '{order:$o}')" >/dev/null \
      && echo "   annulée : $uuid" \
      || echo "   ⚠️  $uuid non annulée — la libérer avec UNBLOCK=1 au prochain passage"
  done <<<"$BLOCKING"
fi

# Relu, jamais déduit des annulations : c'est le même principe que partout
# ailleurs dans ces scripts, et c'est ce qui a révélé le trou ci-dessus.
read_blocking_orders
if [ -z "$BLOCKING" ]; then
  pass "Conducteur laissé libre — la suite peut se rejouer"
else
  fail "Le conducteur reste bloqué après le ménage" "$(echo "$BLOCKING" | tr '\n' ' ')"
fi

echo
echo "════════════════════════════════════════════════════════════════"
pass "Les trois sorties d'une course sont vérifiées."
echo "   refus      → motif obligatoire et fermé ; une course démarrée n'est pas refusable"
echo "   échec      → enregistré, relu, et le conducteur reste UTILISABLE"
echo "   annulation → permise avant le départ, refusée après, idempotence dite"
