#!/usr/bin/env bash
# Appels Fleetbase avec la clé de service, pour l'outillage de test.
#
# ── Pourquoi une bibliothèque ──────────────────────────────────────────────
#
# Trois scripts avaient déjà recopié la même lecture de `.env` et le même
# repli réseau, avec les deux mêmes pièges à chaque fois :
#
#   1. **Jamais `source` sur le `.env`** — un token Sanctum contient un `|`,
#      que le shell exécuterait comme un tube.
#   2. **`host.docker.internal` ne résout pas depuis l'hôte** — c'est l'adresse
#      de l'hôte *vue depuis un conteneur*. La valeur du `.env` est juste pour
#      le BFF et fausse pour un shell ; d'où le repli sur `localhost`.
#
# À sourcer :  . "$(dirname "$0")/lib/fleetbase.sh"

_fb_env_file="${ENV_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/backend/bff/.env}"

# Lecture ligne à ligne, jamais `source` (cf. piège 1 ci-dessus).
fb_env() { # clé -> valeur sur stdout
  [ -f "$_fb_env_file" ] || return 0
  local line
  line="$(grep -E "^[[:space:]]*$1=" "$_fb_env_file" | tail -n 1)" || return 0
  [ -n "$line" ] || return 0
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

_fb_base=""   # résolue une fois, après le repli éventuel
_fb_key=""

_fb_init() {
  [ -z "$_fb_base" ] || return 0
  _fb_base="${FLEETBASE_API_URL:-$(fb_env FLEETBASE_API_URL)}"
  _fb_base="${_fb_base:-http://localhost:8000}"
  _fb_key="${FLEETBASE_API_KEY:-$(fb_env FLEETBASE_API_KEY)}"
  [ -n "$_fb_key" ] || { FLEETBASE_ERROR="FLEETBASE_API_KEY introuvable ($_fb_env_file)"; return 1; }
}

# Corps sur stdout ; 1 et FLEETBASE_ERROR en cas d'échec.
fb_api() { # méthode chemin [corps-json]
  _fb_init || return 1
  local method="$1" path="$2" body="${3:-}"
  FLEETBASE_ERROR=""

  local -a args=(-sS --fail -X "$method"
    -H "Authorization: Bearer $_fb_key" -H 'Accept: application/json')
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")

  local out
  if out="$(curl "${args[@]}" "$_fb_base$path" 2>/dev/null)"; then
    printf '%s' "$out"; return 0
  fi

  # Repli (cf. piège 2). Tenté une seule fois : `_fb_base` est réécrite, donc
  # les appels suivants partent directement sur la bonne adresse.
  local fallback="${_fb_base/host.docker.internal/localhost}"
  if [ "$fallback" != "$_fb_base" ] \
     && out="$(curl "${args[@]}" "$fallback$path" 2>/dev/null)"; then
    _fb_base="$fallback"
    printf '%s' "$out"; return 0
  fi

  FLEETBASE_ERROR="Fleetbase : $method $path a échoué (base $_fb_base)"
  # ⚠️ Dit AUSSI sur stderr, et pas seulement dans la variable.
  #
  # `FLEETBASE_ERROR` est posé dans le shell où la fonction s'exécute — donc
  # **perdu** dès qu'on écrit `x="$(fb_api …)"`, qui est la forme la plus
  # courante dans ces scripts. Le défaut ne se voit pas : l'appelant affiche un
  # « ${FLEETBASE_ERROR:-} » vide, ou pire, retombe sur un message par défaut
  # qui accuse autre chose — « Conducteur introuvable » pour une panne réseau,
  # constaté sur `resolve_driver`. Une sortie d'erreur, elle, traverse.
  echo "   ⚠️  $FLEETBASE_ERROR" >&2
  return 1
}

fb_get() { fb_api GET "$1"; }

# Les conducteurs de l'organisation, en un seul endroit.
#
# ⚠️ Cette lecture vivait dans `resolve-driver.sh`, et le diagnostic d'invitation
# de `driver-session.sh` en a eu besoin à son tour. Deux copies, c'est une borne
# qui diverge sans bruit : celle qui plafonne à 100 déclare « introuvable » un
# conducteur que l'autre voit, et le message d'erreur envoie alors chercher au
# mauvais endroit. Le critère de la règle 5 répond oui — si la borne ou la route
# change, les deux doivent changer.
#
# ⚠️ `.drivers // .data` et **aucun repli sur `[]`** : une réponse d'une forme
# inattendue doit remonter comme un échec, pas comme « aucun conducteur ».
fb_drivers() { # -> tableau JSON des conducteurs
  local response
  response="$(fb_get '/int/v1/drivers?limit=200')" || return 1
  echo "$response" | jq -e '.drivers // .data' 2>/dev/null || {
    FLEETBASE_ERROR="réponse inattendue de /int/v1/drivers (ni « drivers » ni « data »)"
    return 1
  }
}

# Active un fournisseur, en tenant le rôle de l'admin qui le ferait en console.
#
# ── Pourquoi cette fonction existe ──────────────────────────────────────────
#
# Depuis le Lot 0 du chantier facilitateur, un `Vendor` d'entreprise de
# transport naît `inactive` et `loginFleet` refuse tant qu'un admin ne l'a pas
# validé. C'est voulu, et le garde reste entier : ce qui est automatisé ici
# n'est pas le contournement du garde, c'est **le geste de l'admin**. Le même
# raisonnement que pour le commerçant, dont `test-parcours-argent.sh` fait déjà
# l'activation avec la clé de service — `register-merchant.sh` restant le script
# qui joue le parcours à la main et prouve le garde.
#
# Sans elle, trois scripts s'arrêtaient à leur première ligne utile : plus
# aucun moyen automatisé d'obtenir une session opérateur.
#
# La recherche se fait par **email** et non par nom : les comptes de test
# partagent tous « Flotte de test », et activer le mauvais fournisseur produit
# un refus qu'on met dix minutes à comprendre.
fb_activate_vendor_by_email() { # email
  local vendors uuid now
  vendors="$(fb_get '/int/v1/vendors?limit=200')" || return 1

  uuid="$(echo "$vendors" | jq -r --arg e "$1" \
    '(.vendors // .data // []) | map(select(.email == $e)) | last.uuid // empty')"
  [ -n "$uuid" ] || { FLEETBASE_ERROR="aucun fournisseur d'email « $1 »"; return 1; }

  fb_api PUT "/int/v1/vendors/$uuid" '{"status":"active"}' >/dev/null || return 1

  # Relu, jamais déduit du code HTTP : `status` n'est pas garanti `fillable`,
  # et un `PUT` qui l'ignore répond 200 sans rien changer. Le refus de connexion
  # suivant serait alors mis sur le compte du garde plutôt que du PUT.
  vendors="$(fb_get '/int/v1/vendors?limit=200')" || return 1
  now="$(echo "$vendors" | jq -r --arg u "$uuid" \
    '(.vendors // .data // []) | map(select(.uuid == $u)) | first.status // empty')"
  [ "$now" = "active" ] \
    || { FLEETBASE_ERROR="statut resté « ${now:-inconnu} » après le PUT"; return 1; }
}
