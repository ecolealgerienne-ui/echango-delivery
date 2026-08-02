#!/usr/bin/env bash
#
# Banc de refus de la frontière HTTP (règle 12).
#
# Chaque route protégée est appelée sans jeton, avec le jeton d'un autre rôle,
# et avec un jeton révoqué. Les trois doivent être refusés — avec le bon statut
# ET le bon code, parce qu'un refus sans code est un refus que l'application ne
# sait pas traduire.
#
# ⚠️ **Les routes sont énumérées depuis la source**, jamais listées à la main :
# une route ajoutée demain est couverte sans que personne y pense. Une liste
# écrite à la main aurait le défaut qu'elle prétend corriger.
#
# Le détail, les motifs et l'auto-test sont dans `lib/frontiere_http.py`.
#
#   ./scripts/test-frontiere-http.sh
#   PACE_SECONDS=0.8 ./scripts/test-frontiere-http.sh   # si le débit plafonne
#   python3 scripts/lib/frontiere_http.py --self-test   # 16 cas, dont 6 refus
#   python3 scripts/lib/frontiere_http.py --list        # les routes vues
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "❌ python3 absent — le banc ne peut pas s'exécuter, et l'absence de"
  echo "   verdict n'est pas un verdict."
  exit 2
}

# ⚠️ L'auto-test d'abord, et un échec y est bloquant. Un banc dont on n'a pas
# vérifié qu'il sait dire non ne prouve rien de ce qu'il déclare ensuite.
echo "── auto-test du banc ──"
python3 "$HERE/lib/frontiere_http.py" --self-test || {
  echo "❌ l'auto-test échoue : le banc lui-même est en cause, pas les routes."
  exit 2
}

echo
echo "── banc de refus ──"
exec python3 "$HERE/lib/frontiere_http.py"
