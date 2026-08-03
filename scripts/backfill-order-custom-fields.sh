#!/usr/bin/env bash
# Reprise de données : `Order.specMeta` → champs personnalisés Fleetbase.
#
# ── Pourquoi ce script existe ───────────────────────────────────────────────
#
# `specMeta` était le **filet** posé le 30/07/2026 en attendant les champs
# personnalisés : une copie locale de ce que le commerçant avait demandé, servie
# en dernier recours quand la console avait effacé le `meta` de la commande.
#
# Les champs personnalisés sont en place, et il est prouvé qu'ils survivent à
# une écriture partielle (mesuré le 03/08/2026). Le filet n'a donc plus rien à
# rattraper — sauf pour les commandes créées **avant** la migration, qui n'ont
# aucun champ personnalisé et ne vivent que par lui. Supprimer la colonne sans
# les reprendre effacerait leur prix et leur montant à encaisser.
#
# ⚠️ **N'écrit QUE ce qui manque.** Une clé déjà présente en amont fait foi
# (règle 1) : la réécrire ferait de la copie locale la vraie source et rendrait
# invisible une correction faite en console. C'est l'ordre de préséance
# d'`effectiveOrderMeta`, appliqué à l'envers.
#
# ⚠️ **Idempotent** : relancé, il ne trouve plus rien à écrire. C'est la seule
# forme acceptable pour une reprise de données — un script qu'on n'ose relancer
# est un script qu'on ne relance pas quand il a échoué au milieu.
#
#   ./scripts/backfill-order-custom-fields.sh [--dry-run]
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY=""
[ "${1:-}" = "--dry-run" ] && DRY="1"

ENVF="${BFF_ENV:-$HERE/../backend/bff/.env}"
[ -f "$ENVF" ] || { echo "❌ .env introuvable ($ENVF) — ce script tourne depuis la copie qui porte la configuration"; exit 2; }

KEY=$(grep -E '^FLEETBASE_API_KEY=' "$ENVF" | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')
[ -n "$KEY" ] || { echo "❌ FLEETBASE_API_KEY absente"; exit 2; }

PGC="${BFF_PG_CONTAINER:-echango_bff_postgres}"
PGU=$(docker exec "$PGC" printenv POSTGRES_USER)
PGD=$(docker exec "$PGC" printenv POSTGRES_DB)

echo "── Lecture des specMeta locaux ──"
docker exec "$PGC" psql -U "$PGU" -d "$PGD" -tAc \
  'select "fleetbaseOrderId" || E'"'"'\t'"'"' || coalesce("specMeta"::text, '"'"''"'"') from "Order" where "specMeta" is not null;' \
  > /tmp/specmeta.tsv
echo "   $(wc -l < /tmp/specmeta.tsv) commandes portent un specMeta"

FLEETBASE_API_KEY="$KEY" DRY="$DRY" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

API = os.environ.get('FLEETBASE_API_URL', 'http://localhost:8000') + '/int/v1'
H = {'Authorization': 'Bearer ' + os.environ['FLEETBASE_API_KEY'],
     'Content-Type': 'application/json'}
DRY = bool(os.environ.get('DRY'))

# Le catalogue, recopié depuis `order-custom-fields.ts`.
#
# ⚠️ **Une copie, et elle est assumée** : ce script est un one-shot de reprise,
# pas un composant. Le faire importer le TypeScript demanderait de démarrer
# Nest pour lire treize chaînes. La divergence possible est bornée dans le
# temps — le script disparaît une fois la reprise faite.
#
# ⚠️ `currency` est EXCLU : Fleetbase sert déjà une colonne de ce nom (défaut
# du 02/08/2026). L'écrire en champ personnalisé recréerait la collision.
CATALOGUE = ['price', 'price_source', 'cod_amount', 'cod_goods_amount',
             'cod_currency', 'cod_includes_delivery', 'vehicle_type',
             'prefer_favourites', 'instructions', 'pickup_notes',
             'dropoff_notes', 'items']
LISTES = {'items'}

def appel(verb, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(API + path, data=data, headers=H, method=verb)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode() or '{}')
    except urllib.error.HTTPError as e:
        return {'_erreur': '%s %s' % (e.code, e.read().decode()[:160])}
    except Exception as e:
        return {'_erreur': str(e)}

lignes = [l.rstrip('\n') for l in open('/tmp/specmeta.tsv', encoding='utf-8') if l.strip()]
print('── Reprise ──')

# uuid de définition, par nom, et par configuration de commande
defs_par_config = {}
def definitions(cfg):
    if cfg in defs_par_config:
        return defs_par_config[cfg]
    d = appel('GET', '/custom-fields?subject_uuid=%s&limit=200' % cfg)
    m = {r['name']: r['uuid'] for r in (d.get('custom_fields') or []) if r.get('name')}
    defs_par_config[cfg] = m
    return m

repris = deja = introuvable = echec = 0
for ligne in lignes:
    parts = ligne.split('\t', 1)
    if len(parts) != 2:
        continue
    uuid, brut = parts
    try:
        spec = json.loads(brut)
    except Exception:
        continue
    if not isinstance(spec, dict):
        continue

    o = appel('GET', '/orders/%s?with[]=customFieldValues.customField' % uuid)
    if '_erreur' in o:
        introuvable += 1
        continue
    o = o.get('order') or o
    presentes = {(v.get('custom_field') or {}).get('name')
                 for v in (o.get('custom_field_values') or [])}

    cfg = o.get('order_config_uuid')
    if not cfg:
        introuvable += 1
        continue
    defs = definitions(cfg)

    a_ecrire = []
    for cle in CATALOGUE:
        nom = cle.replace('_', '-')
        if nom in presentes:            # l'amont fait foi
            continue
        val = spec.get(cle)
        if val is None:
            continue
        uid = defs.get(nom)
        if not uid:
            continue
        # Tout est stocké en chaîne côté Fleetbase (cast `CustomValue`).
        encode = json.dumps(val) if cle in LISTES else (
            'true' if val is True else 'false' if val is False else str(val))
        a_ecrire.append({'custom_field_uuid': uid, 'value': encode,
                         'value_type': 'array' if cle in LISTES else 'text'})

    if not a_ecrire:
        deja += 1
        continue
    if DRY:
        print('   [essai] %s — %d clés' % (uuid[:8], len(a_ecrire)))
        repris += 1
        continue

    pid = o.get('public_id') or uuid
    r = appel('PUT', '/orders/%s' % pid, {'order': {'custom_field_values': a_ecrire}})
    if '_erreur' in r:
        echec += 1
        print('   ❌ %s : %s' % (uuid[:8], r['_erreur']))
    else:
        repris += 1

print()
print('   reprises          : %d' % repris)
print('   déjà complètes    : %d' % deja)
print('   commande absente  : %d' % introuvable)
print('   échecs            : %d' % echec)
print()
if echec:
    print('   ⚠️ Des écritures ont échoué — NE PAS supprimer `specMeta` avant de les avoir reprises.')
    sys.exit(1)
print('   ✅ Reprise terminée. `Order.specMeta` peut être supprimé.')
PY
