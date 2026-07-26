#!/usr/bin/env bash
# Clone Fleetbase (upstream, non versionné dans ce repo) et lance l'installation Docker officielle.
# À exécuter en local (WSL/Docker) — jamais testé dans le sandbox Claude Code (pas de daemon Docker disponible).
set -euo pipefail

FLEETBASE_DIR="fleetbase-src"

if [ -d "$FLEETBASE_DIR" ]; then
  echo "$FLEETBASE_DIR existe déjà."
  read -rp "Supprimer et recloner ? (o/N) " confirm
  [ "$confirm" = "o" ] || exit 1
  rm -rf "$FLEETBASE_DIR"
fi

git clone https://github.com/fleetbase/fleetbase.git "$FLEETBASE_DIR"
cd "$FLEETBASE_DIR"
./scripts/docker-install.sh

echo ""
echo "Une fois l'installation terminée : console sur http://localhost:4200, API sur http://localhost:8000."
echo "Extension FleetOps (nécessaire, pas installée par défaut) : flb install fleetbase/fleetops"
