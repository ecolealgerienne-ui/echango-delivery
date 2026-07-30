#!/usr/bin/env bash
# Inscrit un commerçant et déroule le parcours de validation par un admin
# (Lot 4, journal §26).
#
#   ./scripts/register-merchant.sh                       # nouveau compte
#   EMAIL=x@y.z ./scripts/register-merchant.sh           # reprend un compte
#
# ── Ce que le script prouve, et pourquoi il s'arrête au milieu ───────────────
#
# Depuis le Lot 4, une inscription ne délivre plus de jeton : elle enregistre
# une **demande**. Un administrateur doit passer le `Vendor` à `active` dans la
# console avant la première connexion.
#
# Le script fait donc les deux moitiés, séparées par une pause :
#
#   1. inscription      → refus attendu, `merchant_pending`
#   2. connexion        → refus attendu, `merchant_pending`
#   ── pause : activation manuelle dans la console ──
#   3. connexion        → succès attendu, jeton délivré
#
# **Les deux refus sont le résultat recherché, pas un échec.** Un jeton obtenu
# à l'étape 1 signifierait que la validation ne sert à rien — c'est précisément
# le défaut corrigé au Lot 4, où le modèle Fleetbase créait tout Vendor en
# `active` et où l'inscription renvoyait un JWT.
set -uo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
PASSWORD="${PASSWORD:-motdepasse123}"

# Le même suffixe dans l'email ET la raison sociale.
#
# Sans lui, chaque exécution créait une « Boulangerie Test » de plus, et la
# console en affiche déjà une douzaine. « Prendre la plus récente » est une
# mauvaise instruction : la liste n'est pas triée par date, et activer le
# mauvais fournisseur produit un refus qu'on met dix minutes à comprendre.
# Un nom unique supprime la question.
SUFFIX="${SUFFIX:-$RANDOM}"
EMAIL="${EMAIL:-commercant-$SUFFIX@echango.local}"
BUSINESS="${BUSINESS:-Boulangerie Test $SUFFIX}"

command -v jq >/dev/null 2>&1 || {
  echo "❌ jq requis : sudo apt update && sudo apt install -y jq" >&2; exit 1; }

pass() { echo "✅ $1"; }
info() { echo "   $1"; }
fail() { echo "❌ $1"; echo "   Réponse : $2"; exit 1; }

# Corps sur stdout, code HTTP sur la dernière ligne.
post() {
  curl -sS -w '\n%{http_code}' -X POST "$BFF_URL$1" \
    -H 'Content-Type: application/json' -d "$2"
}
code() { tail -n1 <<<"$1"; }
body() { sed '$d' <<<"$1"; }

# Reconnaît le refus « commerçant en attente ».
#
# Par `code` d'abord, c'est le contrat. Par le message ensuite : le filtre
# d'exception du BFF a longtemps **jeté tout champ hors de sa liste**, donc un
# `code` absent signifie « BFF antérieur au correctif », pas « mauvaise
# réponse ». Le dire vaut mieux que d'échouer sans expliquer.
is_pending() { # body
  local c
  c=$(jq -r '.code // empty' <<<"$1" 2>/dev/null)
  if [ "$c" = "merchant_pending" ]; then return 0; fi
  if grep -qi 'valider\|validation' <<<"$1"; then
    echo "   ⚠️  refus reconnu au message : le champ 'code' est absent de la"
    echo "      réponse. Le filtre d'exception du BFF ne le relaie pas encore."
    return 0
  fi
  return 1
}

FLEETBASE_URL="${FLEETBASE_URL:-http://localhost:8000}"
FLEETBASE_API_KEY="${FLEETBASE_API_KEY:-}"

# Statut du Vendor tel que Fleetbase le voit, ou vide si on ne peut pas lire.
#
# Sans ça, l'étape d'activation est un pari : deux listes de la console
# affichent un statut — IAM → Customers et Fleet-Ops → Fournisseurs — et **une
# seule compte**. Activer la mauvaise donne un écran vert et un refus
# inchangé, sans que rien ne relie les deux.
vendor_status() { # nom du fournisseur
  [ -n "$FLEETBASE_API_KEY" ] || return 1
  curl -sS -H "Authorization: Bearer $FLEETBASE_API_KEY" -H 'Accept: application/json' \
    "$FLEETBASE_URL/int/v1/vendors?limit=200" 2>/dev/null \
    | jq -r --arg n "$1" '(.vendors // .data // []) | map(select(.name == $n))
         | if length == 0 then empty else (last.status // "non renseigné") end' 2>/dev/null
}

CREDS=$(jq -n --arg e "$EMAIL" --arg p "$PASSWORD" '{email:$e, password:$p}')

echo "════════════════════════════════════════════════════════════════"
echo "BFF      : $BFF_URL"
echo "Email    : $EMAIL"
echo "Mot de passe : $PASSWORD"
echo "════════════════════════════════════════════════════════════════"
echo

# ── 1. Inscription ──────────────────────────────────────────────────────────
echo "── 1. Inscription ──"

REG=$(post /auth/merchant/register "$(jq -n \
  --arg e "$EMAIL" --arg p "$PASSWORD" --arg b "$BUSINESS" \
  '{email:$e, password:$p, businessName:$b,
    firstName:"Test", lastName:"Commerçant", phone:"+213555000000"}')")

REG_CODE=$(code "$REG")
REG_BODY=$(body "$REG")

if [ "$REG_CODE" = "403" ] && is_pending "$REG_BODY"; then
  pass "demande enregistrée, accès refusé — c'est le comportement attendu"
  info "$(jq -r '.message' <<<"$REG_BODY")"
elif [ -n "$(jq -r '.token // empty' <<<"$REG_BODY" 2>/dev/null)" ]; then
  fail "un jeton a été délivré à l'inscription — la validation ne sert à rien.
   Le BFF tourne-t-il une version antérieure au Lot 4 ? (docker compose restart)" "$REG_BODY"
elif [ "$REG_CODE" = "409" ]; then
  info "compte déjà existant, on passe à la connexion"
else
  fail "inscription en échec inattendu (HTTP $REG_CODE)" "$REG_BODY"
fi
echo

# ── 2. Connexion avant validation ───────────────────────────────────────────
echo "── 2. Connexion AVANT validation ──"

LOGIN1=$(post /auth/login "$CREDS")
L1_CODE=$(code "$LOGIN1")
L1_BODY=$(body "$LOGIN1")

if [ "$L1_CODE" = "403" ] && is_pending "$L1_BODY"; then
  pass "connexion refusée — le garde fonctionne"
  info "$(jq -r '.message' <<<"$L1_BODY")"
elif [ -n "$(jq -r '.token // empty' <<<"$L1_BODY" 2>/dev/null)" ]; then
  fail "connexion ACCEPTÉE alors que le commerçant n'est pas validé.
   Deux causes possibles : le Vendor a été créé en 'active' (BFF antérieur au
   Lot 4), ou Fleetbase était injoignable — le garde laisse alors passer
   délibérément, et le journal du BFF le dit." "$L1_BODY"
else
  fail "réponse inattendue à la connexion (HTTP $L1_CODE)" "$L1_BODY"
fi
echo

# ── 3. Activation manuelle ──────────────────────────────────────────────────
echo "── 3. Activation, dans la console Fleetbase ──"
echo

BEFORE=$(vendor_status "$BUSINESS" || true)
if [ -n "$BEFORE" ]; then
  info "statut actuel du fournisseur « $BUSINESS » : $BEFORE"
  echo
fi

cat <<EOF
   ⚠️  DEUX listes de la console affichent un statut. Une seule compte.

       ✅ Fleet-Ops → Fournisseurs   ← c'est CELLE-CI que le BFF lit
       ❌ IAM → Customers            ← statut du compte utilisateur Fleetbase,
                                       que nos commerçants n'utilisent pas :
                                       l'activer ne change rien au refus.

   Fleet-Ops → Fournisseurs → rechercher « $SUFFIX »
   → « $BUSINESS » → Modifier → Statut → Active → Save Changes

EOF
read -r -p "   Appuyer sur Entrée une fois le FOURNISSEUR activé… " _
echo

AFTER=$(vendor_status "$BUSINESS" || true)
if [ -n "$AFTER" ]; then
  if [ "$AFTER" = "active" ]; then
    pass "fournisseur lu à « active » — la connexion devrait passer"
  else
    echo "❌ le fournisseur est toujours à « $AFTER »."
    echo "   Rien n'a été activé, ou c'est le Customer d'IAM qui l'a été."
    echo "   Inutile de poursuivre : le refus est certain."
    exit 1
  fi
  echo
fi

# ── 4. Connexion après validation ───────────────────────────────────────────
echo "── 4. Connexion APRÈS validation ──"

LOGIN2=$(post /auth/login "$CREDS")
L2_CODE=$(code "$LOGIN2")
L2_BODY=$(body "$LOGIN2")
TOKEN=$(jq -r '.token // empty' <<<"$L2_BODY" 2>/dev/null)

if [ -n "$TOKEN" ]; then
  pass "connexion acceptée — le commerçant est validé"
  info "profil résolu par le serveur : $(jq -r '.user.type // "?"' <<<"$L2_BODY")"
  echo
  echo "   Jeton (exportable pour les autres scripts) :"
  echo "   export TOKEN='$TOKEN'"
  echo "   export EMAIL='$EMAIL'"
else
  fail "toujours refusé après activation (HTTP $L2_CODE).
   À vérifier dans l'ordre :
     • est-ce bien le FOURNISSEUR (Fleet-Ops) qui a été activé, et non le
       Customer d'IAM ? C'est la confusion la plus fréquente : les deux
       affichent un statut, le BFF ne lit que le premier.
     • le statut est-il bien 'Active' et non 'Inactive' ou 'Suspended' ?
     • le journal du BFF indique le statut réellement lu :
         docker logs echango_bff_app | grep 'Connexion refusée'
     • si le journal dit 'statut illisible', c'est Fleetbase qui ne répond pas —
       et dans ce cas la connexion aurait dû passer, pas être refusée." "$L2_BODY"
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "Parcours complet validé : demande → refus → activation → accès."
echo "════════════════════════════════════════════════════════════════"
