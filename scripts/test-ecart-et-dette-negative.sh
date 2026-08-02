#!/usr/bin/env bash
#
# L'écart à la porte, et la dette NÉGATIVE — les deux cas laissés de côté.
#
# ── Pourquoi ils étaient hors des scripts d'argent ───────────────────────
#
# `test-parcours-argent.sh` dit lui-même les avoir écartés « pour ne pas rendre
# un échec ambigu » : mêlés au parcours nominal, on ne saurait pas si c'est la
# chaîne ou l'écart qui a cédé. Ils méritaient leur propre scénario. Le voici.
#
# ── Ce qu'est une dette négative, et pourquoi il en faut une ─────────────
#
# `dette = perçu − rémunération − remises` (`cash.service.ts`, `debtBetween`).
# La rémunération n'est PAS bornée dans ce calcul — seul son affichage l'est
# (`retainedFromCash`, « on ne se paie pas sur de l'argent qu'on n'a pas »).
#
# Donc dès que le perçu est INFÉRIEUR à la course, la dette passe sous zéro :
# c'est le commerçant qui doit au transporteur. La borner à zéro effacerait ce
# cas — le transporteur aurait travaillé sans que rien ne l'enregistre.
#
#     course prépayée, ou client n'ayant payé qu'une partie
#     perçu 200, course 650  ⇒  dette −450  ⇒  le COMMERÇANT doit 450
#
# ── L'ordre des deux livraisons n'est pas indifférent ────────────────────
#
# La négative vient EN PREMIER. Dans l'autre sens, la dette resterait positive
# tout du long (850 puis 400) et on ne verrait **jamais un nombre négatif** — on
# vérifierait seulement qu'elle a diminué, ce qu'un plancher à zéro produirait
# aussi. C'est le signe lui-même qu'il faut observer.
#
#     1. perçu 200 sur 750 annoncés   → dette −450   (commerçant débiteur)
#     2. perçu 1500 sur 1950 annoncés → dette  +400  (−450 + 850)
#
# La seconde prouve en outre que les deux jambes se **composent** au lieu de se
# remplacer.
#
# ── Les refus, et celui qui n'est pas testé ici ─────────────────────────
#
#   * percevoir PLUS que dû        → `cash.amount_exceeds_expected`
#   * un écart sans motif          → `cash.discrepancy_reason_required`
#
# ⚠️ Le montant négatif (`cash.amount_negative`) n'est **pas** exercé : le DTO
# le refuse avant le service (`@Min(0)`), donc la réponse serait
# `validation.failed` et ce script attendrait un code qui n'arrive jamais. Ce
# n'est pas un trou — c'est une défense en profondeur, et le dire vaut mieux
# que d'écrire un cas qui semble couvrir une garde qu'il n'atteint pas.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-ecart-et-dette-negative.sh [conducteur]
#
#   BFF_URL=http://localhost:3001

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"
DRIVER_HINT="${1:-}"

# Livraison 1 — la dette négative.
N_GOODS=100 ; N_FEE=650 ; N_COLLECTED=200
# Livraison 2 — l'écart à la porte, dette positive.
E_GOODS=1300 ; E_FEE=650 ; E_COLLECTED=1500

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
. "$(dirname "$0")/lib/ledger.sh"

SUFFIX="$(date +%s)"

# Crée, publie, fait accepter. Rend l'uuid Fleetbase sur stdout.
place_order() { # goods fee libellé
  local goods="$1" fee="$2" label="$3" o oid uuid pub st acc
  o="$(mapi POST /commercant/commandes "$(jq -n --argjson g "$goods" --argjson f "$fee" --arg l "$label" '{
    pickupLocationName: $l, pickupLatitude: 36.7538, pickupLongitude: 3.0588,
    pickupContactName: "Commerce", pickupContactPhone: "+213555000000",
    dropoffLocationName: "Client", dropoffLatitude: 36.7500, dropoffLongitude: 3.0600,
    dropoffContactName: "Destinataire", dropoffContactPhone: "+213555111111",
    price: $f, codAmount: $g, codIncludesDelivery: false,
    podMethod: "aucune", preferFavourites: false, draft: true }')")"
  oid="$(echo "$o" | jq -r '.id // .uuid // empty')"
  [ -n "$oid" ] || { echo "CREATE_FAILED $(echo "$o" | jq -c '.')" >&2; return 1; }

  pub="$(mapi POST "/commercant/commandes/$oid/publier")"
  echo "$pub" | is_error && { echo "PUBLISH_FAILED $(echo "$pub" | jq -c '.')" >&2; return 1; }

  uuid="$(mapi GET "/commercant/commandes/$oid" | jq -r '.uuid')"
  acc="$(dapi POST "/transporteur/commandes/$uuid/accepter")"
  if echo "$acc" | is_error; then
    echo "ACCEPT_FAILED $(echo "$acc" | jq -c '.')" >&2; return 1
  fi

  # `accepter` démarre déjà la course sur le pool ; on lit plutôt que de supposer.
  st="$(mapi GET "/commercant/commandes/$oid" | jq -r '.status // empty')"
  case "$st" in
    started|enroute|completed) : ;;
    *) dapi POST "/transporteur/commandes/$uuid/demarrer" >/dev/null ;;
  esac

  printf '%s' "$uuid"
}

echo "BFF : $BFF_URL"
echo "1) perçu $N_COLLECTED sur $((N_GOODS + N_FEE)) annoncés, course $N_FEE → dette attendue $((N_COLLECTED - N_FEE))"
echo "2) perçu $E_COLLECTED sur $((E_GOODS + E_FEE)) annoncés, course $E_FEE → +$((E_COLLECTED - E_FEE))"

# ── 0. Les acteurs ─────────────────────────────────────────────────────────
step "0. Les acteurs"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"
require_free_driver

MERCHANT_EMAIL="ecart-m-$SUFFIX@test.dz"
reg="$(curl -sS -w '\n%{http_code}' -X POST "$BFF_URL/auth/merchant/register" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{
    email:$e, password:$p, businessName:"Commerce Ecart", firstName:"Test",
    lastName:"Ecart", phone:"+213555000000", businessPhone:"+213555000000"}')")"
status="$(tail -n1 <<<"$reg")"; body="$(sed '$d' <<<"$reg")"
[ "$status" = "403" ] || fail "L'inscription doit être mise en attente (HTTP $status)" "$body"
fb_activate_vendor_by_email "$MERCHANT_EMAIL" || fail "Activation impossible : ${FLEETBASE_ERROR:-}"
mlogin="$(curl -sS -X POST "$BFF_URL/auth/login" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$MERCHANT_EMAIL" --arg p "$PASSWORD" '{email:$e,password:$p}')")"
MERCHANT_TOKEN="$(echo "$mlogin" | jq -r '.token // empty')"
MERCHANT_ID="$(echo "$mlogin" | jq -r '.user.id // empty')"
[ -n "$MERCHANT_TOKEN" ] && [ -n "$MERCHANT_ID" ] || fail "Connexion commerçant refusée" "$mlogin"
pass "Commerçant NEUF : $MERCHANT_EMAIL"

# Un commerçant neuf ⇒ dette de couple à zéro. C'est ce qui rend les deux
# montants lisibles sans soustraire un résidu.
# La contrepartie depend du provisionnement : Echango est le facilitateur des
# courses du pool quand un compte plateforme existe, et la dette du conducteur
# va alors a LUI. Lire le commercant rendrait 0 sur un registre juste.
CP="$(fb_pool_counterparty "$MERCHANT_ID")" || fail "${FLEETBASE_ERROR:-}"
D0="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$CP")")"

# ⚠️ **On mesure des DELTAS, jamais des totaux** — troisieme occurrence du meme
# piege dans ce depot. La parade d origine etait « un commercant neuf a chaque
# run, donc sa dette part de zero ». Elle ne tient plus depuis que la
# contrepartie du pool est Echango : ce compte est UNIQUE et partage entre
# toutes les executions, et son encours s accumule.
#
# Toute assertion sur une valeur ABSOLUE du registre est fausse des lors que la
# contrepartie est partagee. Seul l ecart cree par CETTE livraison est stable.
pass "Dette de depart envers $COUNTERPARTY_LABEL : $D0"

# ── 1. Les deux refus ──────────────────────────────────────────────────────
step "1. Les gardes sur le montant perçu"

FB1="$(place_order "$N_GOODS" "$N_FEE" "Commerce Ecart")" \
  || fail "Mise en place de la livraison 1 impossible (voir ci-dessus)"
N_EXPECTED=$((N_GOODS + N_FEE))
pass "Livraison 1 en cours — $N_EXPECTED annoncés à la porte"

over="$(dapi POST "/transporteur/commandes/$FB1/terminer" \
  "$(jq -n --argjson c "$((N_EXPECTED + 50))" '{collectedAmount:$c}')")"
expect_refusal "Percevoir $((N_EXPECTED + 50)) alors que $N_EXPECTED sont dus" \
  "cash.amount_exceeds_expected" "$over"

noreason="$(dapi POST "/transporteur/commandes/$FB1/terminer" \
  "$(jq -n --argjson c "$N_COLLECTED" '{collectedAmount:$c}')")"
expect_refusal "Écart sans motif" "cash.discrepancy_reason_required" "$noreason"

# ── 2. La dette négative ───────────────────────────────────────────────────
step "2. Écart à la porte : perçu $N_COLLECTED sur $N_EXPECTED"

closed="$(dapi POST "/transporteur/commandes/$FB1/terminer" \
  "$(jq -n --argjson c "$N_COLLECTED" '{collectedAmount:$c, discrepancyReason:"somme_incomplete"}')")"
echo "$closed" | is_error && fail "Clôture avec écart refusée" "$(echo "$closed" | jq -c '.')"
pass "Livrée, $N_COLLECTED déclarés perçus, motif « somme_incomplete »"

EXPECT_NEG=$((N_COLLECTED - N_FEE))
D1="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$CP")")"
ADDED1=$((D1 - D0))
[ "$ADDED1" = "$EXPECT_NEG" ] \
  || fail "Cette livraison doit ajouter $EXPECT_NEG (percu $N_COLLECTED - course $N_FEE), elle ajoute $ADDED1 (avant $D0, apres $D1)"

# ⚠️ Le SIGNE, explicitement. Un plancher à zéro rendrait 0 ici, ce qui est un
# nombre parfaitement plausible — et le transporteur aurait travaillé sans que
# rien n'enregistre ce qui lui est dû.
case "$ADDED1" in
  -*) pass "Apport NEGATIF : $ADDED1 — le commercant doit $((0 - ADDED1)) au transporteur" ;;
  *)  fail "L apport devrait etre negatif, il vaut $ADDED1 — un plancher a zero l a ecrase" ;;
esac

# Le détail dit la même chose : la retenue affichée est plafonnée au perçu,
# alors que le calcul de dette, lui, prend la rémunération entière.
row="$(mapi GET /commercant/encaissements/details \
  | jq -c --arg u "$FB1" '.data[]? | select(.order_uuid == $u)')"
[ -n "$row" ] || fail "Aucune ligne au registre pour la livraison 1"
[ "$(amount_number "$(echo "$row" | jq -r '.collected_amount')")" = "$N_COLLECTED" ] \
  || fail "Le registre devrait porter $N_COLLECTED perçus" "$row"
[ "$(echo "$row" | jq -r '.discrepancy_reason')" = "somme_incomplete" ] \
  || fail "Le motif d'écart n'est pas enregistré" "$row"
pass "Registre : $N_COLLECTED perçus, motif conservé"

# ── 3. L'écart positif, et la composition ─────────────────────────────────
step "3. Seconde livraison : perçu $E_COLLECTED sur $((E_GOODS + E_FEE))"

FB2="$(place_order "$E_GOODS" "$E_FEE" "Commerce Ecart")" \
  || fail "Mise en place de la livraison 2 impossible (voir ci-dessus)"
E_EXPECTED=$((E_GOODS + E_FEE))

closed="$(dapi POST "/transporteur/commandes/$FB2/terminer" \
  "$(jq -n --argjson c "$E_COLLECTED" '{collectedAmount:$c, discrepancyReason:"pas_de_monnaie"}')")"
echo "$closed" | is_error && fail "Clôture refusée" "$(echo "$closed" | jq -c '.')"
pass "Livrée, $E_COLLECTED perçus sur $E_EXPECTED, motif « pas_de_monnaie »"

EXPECT_TOTAL=$(( (N_COLLECTED - N_FEE) + (E_COLLECTED - E_FEE) ))
D2="$(amount_number "$(debt_toward "$(dapi GET /transporteur/caisse)" "$CP")")"

# ⚠️ La COMPOSITION, et pas seulement la seconde jambe. Si la négative avait été
# écrasée à zéro, on lirait ici 850 au lieu de 400 — un nombre plausible, et le
# seul écart entre les deux est précisément ce que ce script existe pour voir.
[ "$((D2 - D0))" = "$EXPECT_TOTAL" ] \
  || fail "Les deux livraisons doivent ajouter $EXPECT_TOTAL, elles ajoutent $((D2 - D0))"
pass "Les deux jambes se composent : $EXPECT_NEG puis +$((E_COLLECTED - E_FEE)) = $((D2 - D0))"

echo
echo "════════════════════════════════════════════════════════════════"
pass "Écart à la porte et dette négative vérifiés."
echo "   percevoir plus que dû      → refusé"
echo "   écart sans motif           → refusé"
echo "   perçu $N_COLLECTED / $N_EXPECTED        → dette $EXPECT_NEG, le commerçant est débiteur"
echo "   puis percu $E_COLLECTED / $E_EXPECTED    -> apport total $((D2 - D0))"
