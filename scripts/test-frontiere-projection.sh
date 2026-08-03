#!/usr/bin/env bash
#
# Ce qui SORT du BFF n'est jamais la commande Fleetbase brute.
#
# ── Pourquoi ce banc existe (03/08/2026) ──────────────────────────────────
#
# `GET /transporteur/commandes/:id` a servi la commande Fleetbase entière
# pendant une journée : `meta.declines[]` compris — uuid Fleetbase, motif,
# notes libres et **prix offert** à chaque transporteur ayant refusé la course
# —, plus `proof_url` et `custom_field_values[]`.
#
# Rien ne l'a signalé. Ni les cinq scénarios, qui étaient verts avant et après
# le correctif ; ni les tests Jest, dont un vérifiait justement la liste
# d'autorisation — mais en l'accordant avec le catalogue, c'est-à-dire en
# comparant deux listes pendant qu'un chemin sautait les deux.
#
# Un test unitaire prouve que la projection RETIRE. Seul un banc en conditions
# réelles prouve que la ROUTE l'appelle. Ce sont deux questions, et c'est la
# seconde qui a échoué.
#
# ── Le témoin, et pourquoi il est obligatoire ─────────────────────────────
#
# ⚠️ Un banc qui vérifie « la réponse ne contient pas X » est vert quand la
# réponse est vide, quand le compte n'a aucune course, quand le champ n'existe
# nulle part. C'est le défaut que ce dépôt a rencontré cinq fois : une donnée
# mal câblée ne casse pas, elle **disparaît** (règle 10).
#
# Donc on lit la MÊME commande deux fois — chez Fleetbase et par le BFF — et on
# refuse de conclure si la version Fleetbase ne porte pas ce qu'on cherche à ne
# pas voir. « Le contrôle est aveugle » et « il n'y avait rien à cacher » sont
# deux choses, et les confondre accuse le mauvais coupable.
#
# ── Et le pendant : ce qui doit RESTER ────────────────────────────────────
#
# Une projection qui rendrait `{}` passerait tous les tests d'absence. Le banc
# exige donc aussi les champs dont l'application a besoin — sans quoi il
# validerait une route cassée.
#
# ── Usage ─────────────────────────────────────────────────────────────────
#
#   ./scripts/test-frontiere-projection.sh [conducteur]
#
# N'inscrit RIEN : il lit un décor existant. Le plafond de 10 inscriptions par
# heure n'est donc pas consommé, et il se rejoue autant qu'on veut.

set -euo pipefail

BFF_URL="${BFF_URL:-http://localhost:3001}"
# Même défaut que les autres scénarios : `driver-session.sh` lit cette variable
# sans la définir, et `set -u` fait échouer le banc sur le décor plutôt que sur
# ce qu'il examine.
PASSWORD="${PASSWORD:-motdepasse123}"
DRIVER_HINT="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "jq requis."; exit 1; }

pass() { echo "✅ $1"; }
fail() { echo "❌ $1"; [ -n "${2:-}" ] && echo "   $2"; exit 1; }
step() { echo; echo "── $1 ──"; }
skip() { echo "⚠️  $1"; echo "   L'essai ne prouve RIEN — ce n'est pas un succès."; exit 2; }

dapi() {
  curl -sS -X GET "$BFF_URL$1" -H "Authorization: Bearer $DRIVER_TOKEN"
}

. "$(dirname "$0")/lib/fleetbase.sh"
. "$(dirname "$0")/lib/resolve-driver.sh"
. "$(dirname "$0")/lib/driver-session.sh"

echo "════════════════════════════════════════════════════════════════"
echo "  La frontière de projection, en conditions réelles"
echo "════════════════════════════════════════════════════════════════"

step "Décor"
resolve_driver "$DRIVER_HINT" || fail "${RESOLVE_DRIVER_ERROR:-Conducteur introuvable}"
obtain_driver_token "$DRIVER_UUID" || fail "${DRIVER_SESSION_ERROR:-Session conducteur impossible}"
pass "Conducteur : ${DRIVER_LABEL:-$DRIVER_UUID}"

# ── Trouver une course assignée à ce conducteur ────────────────────────────
#
# On prend l'historique en plus de l'actif : une course terminée porte plus de
# champs personnalisés (encaissement déclaré, échecs), donc elle est un
# meilleur témoin. Peu importe laquelle, du moment que Fleetbase en porte.
# ⚠️ **Un refus n'est PAS une liste vide** — et la première version de ce banc
# les confondait. Un 401 rendait `.orders == null`, donc « aucune course », donc
# un saut annoncé comme un décor insuffisant : le banc accusait le décor alors
# que c'était la session qui avait échoué. C'est le défaut que ce dépôt corrige
# depuis cinq fois (règle 10), reproduit dans l'outil censé le débusquer.
lire_liste() { # mode -> liste sur stdout, échoue bruyamment sur un refus
  local mode="$1" r
  r="$(dapi "/transporteur/commandes?mode=$mode")"
  if echo "$r" | jq -e '(.statusCode | type) == "number"' >/dev/null 2>&1; then
    fail "La liste ($mode) a été REFUSÉE — ce n'est pas un décor vide" \
      "$(echo "$r" | jq -c '{statusCode, code, message}')"
  fi
  printf '%s' "$r"
}

liste="$(lire_liste history)"
uuid="$(echo "$liste" | jq -r '(.orders // [])[0].uuid // empty')"

if [ -z "$uuid" ]; then
  liste="$(lire_liste assigned)"
  uuid="$(echo "$liste" | jq -r '(.orders // [])[0].uuid // empty')"
fi

[ -n "$uuid" ] || skip "Ce conducteur n'a aucune course — rien à examiner."
pass "Course examinée : $uuid"

# ── LE TÉMOIN : ce que Fleetbase porte réellement ─────────────────────────
step "Témoin — ce que Fleetbase porte sur cette commande"

# ⚠️ `/int/v1/orders/{uuid}` et non `/orders/{uuid}` — et c'est la LECTURE
# UNITAIRE qui compte : la liste ne sert AUCUN champ personnalisé (piège §3.1
# de `docs/ou_vit_quoi.md`). Y lire le témoin le rendrait toujours vide, donc
# ce banc sauterait toujours en annonçant « rien à cacher ».
brut="$(fb_get "/int/v1/orders/$uuid")" \
  || fail "Lecture Fleetbase impossible pour $uuid" "${FLEETBASE_ERROR:-}"
brut_data="$(echo "$brut" | jq -c '.data // .')"

a_cfv="$(echo "$brut_data" | jq -r 'has("custom_field_values")')"
nb_cfv="$(echo "$brut_data" | jq -r '(.custom_field_values // []) | length')"

[ "$a_cfv" = "true" ] && [ "$nb_cfv" -gt 0 ] || skip \
  "La commande Fleetbase ne porte AUCUN champ personnalisé ($nb_cfv). Il n'y a
   donc rien à laisser fuir, et un « aucune fuite » ne voudrait rien dire."

pass "Fleetbase porte $nb_cfv champ(s) personnalisé(s) et la clé custom_field_values"

# ── Ce que le BFF sert pour la MÊME commande ──────────────────────────────
step "Ce que le BFF sert — la fiche, puis la liste"

fiche="$(dapi "/transporteur/commandes/$uuid")"

echo "$fiche" | jq -e 'type == "object" and (.statusCode | type) != "number"' >/dev/null 2>&1 \
  || fail "La fiche n'a pas été servie" "$(echo "$fiche" | jq -c '.')"

# Les clés interdites, chacune avec la raison qui la met là.
verifier_absence() { # étiquette expression-jq sujet
  local label="$1" expr="$2" sujet="$3" present
  present="$(echo "$sujet" | jq -r "$expr")"
  [ "$present" = "false" ] || fail "$label — la donnée SORT" "$(echo "$sujet" | jq -c "$expr")"
  pass "$label"
}

verifier_absence "custom_field_values ne sort pas (valeurs brutes, non projetées)" \
  'has("custom_field_values")' "$fiche"
verifier_absence "proof_url ne sort pas (URL Fleetbase que rien ne protège)" \
  'has("proof_url")' "$fiche"
verifier_absence "meta.declines ne sort pas (uuid, motif et PRIX OFFERT des concurrents)" \
  '(.meta // {}) | has("declines")' "$fiche"
verifier_absence "meta.delivery_failures brut ne sort pas (porte proof_url)" \
  '(.meta // {}) | has("delivery_failures")' "$fiche"
verifier_absence "company_uuid ne sort pas" \
  'has("company_uuid")' "$fiche"

# ── Le pendant : ce qui doit RESTER ───────────────────────────────────────
#
# ⚠️ Sans cette partie, une route qui rendrait `{}` serait déclarée sûre.
step "Et ce que l'application doit continuer de recevoir"

for champ in uuid status; do
  v="$(echo "$fiche" | jq -r ".$champ // empty")"
  [ -n "$v" ] || fail "Le champ '$champ' a disparu de la fiche — la projection retire trop"
done
pass "uuid et status servis"

# `cod_amount` seulement si Fleetbase le porte : l'exiger sur une course qui
# n'en a pas ferait échouer le banc pour une raison qui n'est pas la sienne.
cod_brut="$(echo "$brut_data" | jq -r '[(.custom_field_values // [])[] | select(.custom_field.name == "cod_amount" or .custom_field_name == "cod_amount")] | length')"
if [ "${cod_brut:-0}" -gt 0 ]; then
  cod_servi="$(echo "$fiche" | jq -r '(.meta // {}) | has("cod_amount")')"
  [ "$cod_servi" = "true" ] || fail \
    "cod_amount est chez Fleetbase mais N'ARRIVE PAS au transporteur — il accepterait une course encaissée sans connaître le montant"
  pass "cod_amount traverse la projection"
else
  echo "   (cette course ne porte pas de cod_amount — non vérifié ici)"
fi

# La liste emprunte le même helper que la fiche : si elle divergeait, l'une des
# deux ne projetterait pas.
step "La liste sert la même chose que la fiche"

for cle in custom_field_values proof_url; do
  n="$(echo "$liste" | jq -r "[(.orders // [])[] | select(has(\"$cle\"))] | length")"
  [ "$n" = "0" ] || fail "$n course(s) de la liste portent '$cle'"
done
n_dec="$(echo "$liste" | jq -r '[(.orders // [])[] | select((.meta // {}) | has("declines"))] | length')"
[ "$n_dec" = "0" ] || fail "$n_dec course(s) de la liste portent meta.declines"
pass "La liste ne porte ni custom_field_values, ni proof_url, ni meta.declines"

echo
echo "════════════════════════════════════════════════════════════════"
echo "✅ La frontière tient — témoin Fleetbase à l'appui."
echo "   $nb_cfv champ(s) personnalisé(s) chez Fleetbase, aucun servi brut."
echo "════════════════════════════════════════════════════════════════"
