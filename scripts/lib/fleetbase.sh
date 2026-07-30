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
  return 1
}

fb_get() { fb_api GET "$1"; }
