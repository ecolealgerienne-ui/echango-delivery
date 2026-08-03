#!/usr/bin/env bash
# Reprise de données : ce que le BFF stockait → champs personnalisés Fleetbase.
#
#   `Order.specMeta`  → prix, montant à encaisser, colis…  (03/08/2026)
#   `OrderDecline`    → `declines`                          (03/08/2026)
#   `DriverFavourite` → `favourites` (sur le Vendor)        (03/08/2026)
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

echo "── Lecture des favoris locaux ──"
docker exec "$PGC" psql -U "$PGU" -d "$PGD" -tAc   'select m."fleetbaseVendorUuid" || chr(9) || f."partyType" || chr(9)
          || f."fleetbaseDriverUuid" || chr(9) || coalesce(f."driverName", '"'"''"'"')
     from "DriverFavourite" f
     join "MerchantAccount" m on m.id = f."merchantId"
    where m."fleetbaseVendorUuid" is not null;'   > /tmp/favourites.tsv 2>/dev/null || : > /tmp/favourites.tsv
echo "   $(wc -l < /tmp/favourites.tsv) favoris à reprendre"

echo "── Lecture des refus locaux ──"
docker exec "$PGC" psql -U "$PGU" -d "$PGD" -tAc   'select d."fleetbaseOrderUuid" || E'"'"'	'"'"' || coalesce(a."fleetbaseDriverUuid", '"'"''"'"')
          || E'"'"'	'"'"' || d.reason
          || E'"'"'	'"'"' || coalesce(d.notes, '"'"''"'"')
          || E'"'"'	'"'"' || d."wasAssigned"
          || E'"'"'	'"'"' || coalesce(d."offeredPrice"::text, '"'"''"'"')
          || E'"'"'	'"'"' || coalesce(d.currency, '"'"''"'"')
          || E'"'"'	'"'"' || d."declinedAt"
     from "OrderDecline" d
     join "DriverAccount" a on a.id = d."driverId";'   > /tmp/declines.tsv 2>/dev/null || : > /tmp/declines.tsv
echo "   $(wc -l < /tmp/declines.tsv) refus à reprendre"

echo "── Lecture des specMeta locaux ──"
docker exec "$PGC" psql -U "$PGU" -d "$PGD" -tAc \
  'select "fleetbaseOrderId" || E'"'"'\t'"'"' || coalesce("specMeta"::text, '"'"''"'"') from "Order" where "specMeta" is not null;' \
  > /tmp/specmeta.tsv
echo "   $(wc -l < /tmp/specmeta.tsv) commandes portent un specMeta"

FLEETBASE_API_KEY="$KEY" DRY="$DRY" NB_DECLINES="$(wc -l < /tmp/declines.tsv)" NB_FAVS="$(wc -l < /tmp/favourites.tsv)" python3 - <<'PY'
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

# ── Les refus ──────────────────────────────────────────────────────────────
#
# ⚠️ Regroupés PAR COMMANDE avant d'écrire : le champ `declines` est une liste,
# et l'écrire une fois par refus ferait autant d'aller-retours que de lignes —
# en écrasant à chaque fois la liste précédente si on ne relisait pas. On
# construit la liste complète, puis on l'écrit d'un coup.
par_commande = {}
illisibles = []
sans_uuid = 0
# Le compte vient de BASH, qui a ecrit le fichier. Le comparer a ce que python
# lit reellement est la seule facon de detecter un fichier ouvert a vide — sans
# quoi le script annonce « 0 refus a reprendre » sur onze lignes ecrites, ce
# qu'il a fait trois fois avant que ce temoin existe.
attendu = int(os.environ.get('NB_DECLINES') or 0)
try:
    brut_declines = list(open('/tmp/declines.tsv', encoding='utf-8'))
except OSError as e:
    print('   LECTURE IMPOSSIBLE de /tmp/declines.tsv : %s' % e)
    brut_declines = []
if len(brut_declines) != attendu:
    print('   ATTENTION bash a ecrit %d ligne(s), python en lit %d'
          % (attendu, len(brut_declines)))
for ligne in brut_declines:
    ch = ligne.rstrip('\n').split('\t')
    if len(ch) < 8 or not ch[0]:
        # NE PAS ignorer en silence : une ligne qu'on ne sait pas decouper est
        # un refus qu'on s'apprete a perdre, et un `continue` muet ferait dire
        # au script « tout est repris » alors qu'il n'a rien vu.
        illisibles.append(ligne[:120])
        continue
    uuid, duuid, motif, notes, assigne, prix, devise, quand = ch[:8]
    if not duuid:
        # Conducteur sans uuid Fleetbase : on ne saurait pas a qui l'attribuer,
        # et un refus anonyme ne filtrerait la liste de personne.
        #
        # COMPTE, jamais ignore en silence : c'est une perte, et une perte se
        # dit. La premiere version faisait un `continue` muet et le recapitulatif
        # annoncait « 0 refus a reprendre » sur onze lignes lues.
        sans_uuid += 1
        continue
    par_commande.setdefault(uuid, []).append({
        'driver_uuid': duuid,
        'reason': motif,
        'notes': notes or None,
        'was_assigned': assigne in ('t', 'true', 'True'),
        'pricing_inputs': None,
        'offered_price': float(prix) if prix else None,
        'currency': devise or None,
        'declined_at': quand,
    })

if illisibles:
    print('   ATTENTION %d ligne(s) de refus non decoupables :' % len(illisibles))
    for l in illisibles[:3]:
        print('      %r' % l)

if sans_uuid:
    print('   %d refus ecarte(s) : conducteur sans uuid Fleetbase' % sans_uuid)

refus_repris = refus_deja = 0
for uuid, elements in par_commande.items():
    o = appel('GET', '/orders/%s?with[]=customFieldValues.customField' % uuid)
    if '_erreur' in o:
        introuvable += 1
        continue
    o = o.get('order') or o
    cfg = o.get('order_config_uuid')
    if not cfg:
        introuvable += 1
        continue
    defs = definitions(cfg)
    uid = defs.get('declines')
    if not uid:
        # ATTENTION La definition n'existe pas encore : le BFF la cree
        # paresseusement a la premiere commande, et un BFF qui n'a pas encore
        # ce champ dans son catalogue ne l'a jamais creee.
        #
        # La creer ICI plutot que de passer : un `continue` muet faisait
        # « 11 refus lus, 0 repris » sans une ligne d'explication, et c'est
        # exactement ce qui a coute trois passages a diagnostiquer.
        cree = appel('POST', '/custom-fields', {
            'subject_uuid': cfg, 'subject_type': 'order-config',
            'name': 'declines', 'label': 'declines', 'type': 'text',
            'description': 'Refus enregistres : qui, quand, pour quel motif.'})
        r = cree.get('custom_field') or cree.get('custom_field_value') or cree
        uid = r.get('uuid') if isinstance(r, dict) else None
        if not uid:
            print('   ECHEC creation de la definition `declines` : %s'
                  % str(cree)[:160])
            echec += 1
            continue
        defs['declines'] = uid

    # Idempotence : on ne réécrit pas un conducteur déjà présent en amont.
    # ATTENTION La valeur relue peut etre DEJA deserialisee.
    #
    # `CustomValue::get()` desserialise quand `value_type` vaut `array`, mais
    # pas toujours — cela depend de l'ordre d'affectation cote Fleetbase. Un
    # `json.loads()` inconditionnel echouait donc sur une liste, tombait dans le
    # `except`, et repartait d'une liste vide : le script reecrivait les onze
    # refus a chaque passage au lieu de les reconnaitre. Il n'etait PAS
    # idempotent, et c'est le second passage qui l'a montre — pas la relecture.
    existants = []
    for v in (o.get('custom_field_values') or []):
        if (v.get('custom_field') or {}).get('name') != 'declines':
            continue
        brut_val = v.get('value')
        if isinstance(brut_val, list):
            existants = brut_val
        elif isinstance(brut_val, str) and brut_val.strip():
            try:
                lu = json.loads(brut_val)
                existants = lu if isinstance(lu, list) else []
            except Exception:
                existants = []
    deja_la = {e.get('driver_uuid') for e in existants if isinstance(e, dict)}
    neufs = [e for e in elements if e['driver_uuid'] not in deja_la]
    if not neufs:
        refus_deja += 1
        continue
    if DRY:
        print('   [essai] refus %s — %d' % (uuid[:8], len(neufs)))
        refus_repris += 1
        continue

    pid = o.get('public_id') or uuid
    r = appel('PUT', '/orders/%s' % pid, {'order': {'custom_field_values': [
        {'custom_field_uuid': uid, 'value': json.dumps(existants + neufs),
         'value_type': 'array'}]}})
    if '_erreur' in r:
        echec += 1
        print('   ❌ refus %s : %s' % (uuid[:8], r['_erreur']))
    else:
        refus_repris += 1

# ── Les favoris ────────────────────────────────────────────────────────────
#
# Portés par le VENDOR du commerçant, avec une definition par vendor : chaque
# commercant a la sienne (`subject_uuid` = uuid du vendor). Un cache global
# rendrait la definition d'un commercant a un autre.
attendu_favs = int(os.environ.get('NB_FAVS') or 0)
try:
    lignes_favs = list(open('/tmp/favourites.tsv', encoding='utf-8'))
except OSError:
    lignes_favs = []

par_vendor = {}
favs_illisibles = []
for ligne in lignes_favs:
    ch = ligne.rstrip('\n').split('\t')
    if len(ch) < 4 or not ch[0] or not ch[2]:
        favs_illisibles.append(ligne[:120])
        continue
    vuuid, ptype, puuid, pname = ch[:4]
    par_vendor.setdefault(vuuid, []).append({
        'party_type': ptype, 'party_uuid': puuid,
        'party_name': pname or None, 'added_at': None})

favs_repris = favs_deja = 0
for vuuid, elements in par_vendor.items():
    v = appel('GET', '/vendors/%s?with[]=customFieldValues.customField' % vuuid)
    if '_erreur' in v:
        introuvable += 1
        continue
    v = v.get('vendor') or v

    uid = None
    existants = []
    for row in (v.get('custom_field_values') or []):
        if (row.get('custom_field') or {}).get('name') != 'favourites':
            continue
        uid = (row.get('custom_field') or {}).get('uuid')
        brut_val = row.get('value')
        if isinstance(brut_val, list):
            existants = brut_val
        elif isinstance(brut_val, str) and brut_val.strip():
            try:
                lu = json.loads(brut_val)
                existants = lu if isinstance(lu, list) else []
            except Exception:
                existants = []

    if not uid:
        d = appel('GET', '/custom-fields?subject_uuid=%s&limit=200' % vuuid)
        uid = next((r['uuid'] for r in (d.get('custom_fields') or [])
                    if r.get('name') == 'favourites'), None)
    if not uid:
        cree = appel('POST', '/custom-fields', {
            'subject_uuid': vuuid, 'subject_type': 'vendor',
            'name': 'favourites', 'label': 'favourites', 'type': 'text',
            'description': 'Transporteurs et entreprises mis en favori.'})
        r = cree.get('custom_field') or cree.get('custom_field_value') or cree
        uid = r.get('uuid') if isinstance(r, dict) else None
    if not uid:
        print('   ECHEC creation de la definition `favourites` sur %s' % vuuid[:8])
        echec += 1
        continue

    deja_la = {(e.get('party_type'), e.get('party_uuid'))
               for e in existants if isinstance(e, dict)}
    neufs = [e for e in elements
             if (e['party_type'], e['party_uuid']) not in deja_la]
    if not neufs:
        favs_deja += 1
        continue
    if DRY:
        print('   [essai] favoris %s — %d' % (vuuid[:8], len(neufs)))
        favs_repris += 1
        continue

    r = appel('PUT', '/vendors/%s' % (v.get('public_id') or vuuid),
              {'vendor': {'custom_field_values': [
                  {'custom_field_uuid': uid,
                   'value': json.dumps(existants + neufs),
                   'value_type': 'array'}]}})
    if '_erreur' in r:
        echec += 1
        print('   ECHEC favoris %s : %s' % (vuuid[:8], r['_erreur']))
    else:
        favs_repris += 1

bilan_favs_vide = attendu_favs > 0 and (favs_repris + favs_deja) == 0

print()
print('   reprises          : %d' % repris)
print('   favoris repris    : %d (%d vendors deja a jour)' % (favs_repris, favs_deja))
print('   refus repris      : %d (%d commandes déjà à jour)' % (refus_repris, refus_deja))
print('   déjà complètes    : %d' % deja)
print('   commande absente  : %d' % introuvable)
print('   échecs            : %d' % echec)
print()
# ⚠️ **`introuvable` est AUSSI bloquant, et ça a failli manquer.**
#
# La première version ne testait que `echec`. Un passage où **546 commandes sur
# 546 étaient introuvables** — Fleetbase redémarré au milieu — a donc affiché
# « ✅ peut être supprimé » : un contrôle qui rassure au moment précis où il
# aurait dû crier. C'est le défaut que ce dépôt dénonce partout, commis dans le
# script qui décide d'une suppression de données.
#
# Une commande qu'on n'a PAS PU LIRE n'est pas une commande dont on a vérifié
# qu'elle était complète. « Je n'ai pas pu savoir » n'est pas « rien à
# signaler ».
# ATTENTION Le controle qui manquait, et c'est le plus important du script.
#
# Onze refus lus, zero repris, zero deja a jour — et le script affichait
# quand meme « peut etre supprime ». Aucun des controles precedents ne
# regardait le BILAN : ils verifiaient chacun leur etape, et le total pouvait
# etre nul sans que rien ne proteste.
#
# Un script de reprise qui lit des lignes et n'en traite aucune n'a pas
# « rien a faire » : il a echoue sans le dire.
bilan_refus_vide = attendu > 0 and (refus_repris + refus_deja) == 0

if (echec or introuvable or illisibles or favs_illisibles or bilan_refus_vide
        or bilan_favs_vide or len(brut_declines) != attendu
        or len(lignes_favs) != attendu_favs):
    print('   ⚠️ NE RIEN SUPPRIMER.')
    if echec:
        print('      %d écriture(s) ont échoué.' % echec)
    if bilan_favs_vide:
        print('      %d favoris lus, AUCUN repris ni deja present.' % attendu_favs)
    if favs_illisibles:
        print('      %d ligne(s) de favoris illisibles.' % len(favs_illisibles))
    if bilan_refus_vide:
        print('      %d refus lus, AUCUN repris ni deja present.' % attendu)
    if illisibles:
        print('      %d ligne(s) de refus illisibles.' % len(illisibles))
    if len(brut_declines) != attendu:
        print("      le fichier des refus n'a pas ete lu en entier.")
    if introuvable:
        print('      %d commande(s) n\'ont pas pu etre lues : Fleetbase' % introuvable)
        print('      indisponible, ou commandes supprimees en amont. Relancer.')
    sys.exit(1)
print('   ✅ Reprise terminée. specMeta, OrderDecline et DriverFavourite peuvent partir.')
PY
