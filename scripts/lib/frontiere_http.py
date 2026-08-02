#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Le banc de refus : chaque route protégée doit REFUSER ce qui n'a pas le droit.

── Pourquoi ce banc existe (règle 12) ────────────────────────────────────────

Le BFF ferme par défaut : l'authentification est un garde **global**, et une
route se retire explicitement avec `@Public`. La mécanique est bonne. Mais au
02/08/2026 **rien ne l'avait jamais vue refuser** : aucun test, aucun scénario
n'appelait une route sans jeton, avec le jeton d'un autre persona, ou avec un
jeton révoqué. Quatre-vingt-sept protections étaient supposées, zéro constatée.

⚠️ **Un `@Public` posé par erreur ne faisait échouer aucun contrôle.** C'est le
mode de panne qui compte : il n'y a ni exception, ni journal, ni écran cassé —
juste une route ouverte que personne ne regarde.

── Ce qui rend ce banc utile plutôt que décoratif ────────────────────────────

**Il énumère les routes depuis la source, il ne les liste pas.** Une route
ajoutée demain est couverte sans que personne y pense — c'est toute la valeur.
Une liste écrite à la main aurait le défaut qu'elle prétend corriger : elle
vieillit en silence, et le jour où elle manque une route, elle affiche un vert
qui veut dire « je n'ai pas regardé ».

⚠️ **Une énumération vide passerait au vert.** Zéro route testée, zéro échec.
Le banc **refuse donc de conclure** en dessous d'un plancher de routes, et il
dit ce qu'il a compté. C'est la même précaution que « la mutation n'a jamais
pris effet » du banc wilaya : *« tout va bien »* et *« je n'ai rien regardé »*
sont deux choses, et les confondre accuse le mauvais coupable.

── Les trois refus attendus, et pourquoi ce sont ceux-là ─────────────────────

| jeton présenté            | attendu | code                      |
|---------------------------|---------|---------------------------|
| aucun                     | 401     | `auth.missing_token`      |
| révoqué (`tokenVersion`)  | 401     | `auth.session_revoked`    |
| valide, **mauvais rôle**  | 403     | `server.persona_forbidden`|

Le **code** est vérifié, pas seulement le statut. Un 401 sans code serait une
protection qui marche mais que l'application ne sait pas traduire (règle 3), et
un 403 rendu par le mauvais garde ne prouverait pas ce qu'on croit.

⚠️ **Le jeton révoqué doit rendre 401 sur TOUTES les routes**, y compris celles
d'un autre persona : `JwtAuthGuard` s'exécute avant `PersonaGuard`. Un 403 à cet
endroit signalerait que l'ordre des gardes a changé — et donc qu'un jeton mort
atteint le contrôle de rôle avant d'être rejeté.

── Ce que le banc ne fait PAS ────────────────────────────────────────────────

Il ne teste pas l'**appartenance** — « ce jeton est valide, mais cette commande
est-elle à lui ? ». C'est une autre question, et elle a son propre banc
(`test-appartenance.sh`). Les confondre laisserait croire que la seconde est
couverte parce que la première l'est.

── Les identifiants d'URL sont volontairement bidons ─────────────────────────

`:id` est remplacé par une valeur inexistante. Si un garde tombe, la requête
atteint le service et répond « introuvable » **au lieu de modifier une vraie
ressource** — un banc de sécurité ne doit pas devenir dangereux le jour où il
trouve quelque chose.
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.normpath(os.path.join(HERE, '..', '..', 'backend', 'bff', 'src'))

# ⚠️ Plancher, pas un compte exact. Un compte exact obligerait à toucher ce
# fichier à chaque route ajoutée, donc à le désactiver un jour de fatigue. Le
# plancher n'attrape qu'une chose, et c'est la seule qui compte : une
# énumération qui s'est effondrée et rendrait le banc vide.
MIN_ROUTES = 60

VERBS = ('Get', 'Post', 'Put', 'Patch', 'Delete')
BOGUS_ID = 'zzz-inexistant-0000'

# ⚠️ **Les routes ouvertes sont épinglées, et c'est la garde la plus
# importante de ce fichier.**
#
# La première version ne les listait pas — elle testait « les routes
# protégées », c'est-à-dire celles que la source déclarait protégées. Éprouvée
# par mutation du vrai contrôleur (`@Public` posé sur `GET /commercant/
# commandes`), **elle est passée au vert** : la route ouverte avait simplement
# quitté l'ensemble testé, et le total était passé de 87 à 86 sans un mot.
#
# C'est le défaut exact que ce banc existe pour attraper, et il l'a laissé
# passer parce qu'il déduisait ce qu'il fallait tester de ce qu'il fallait
# vérifier. **Un contrôle qui prend sa cible dans la donnée qu'il examine ne
# contrôle rien** — même famille que la vérification qui réutilisait la
# fonction fautive.
#
# Chaque ligne ci-dessous est donc une **décision**, et l'ajout d'une route
# ouverte doit passer par ce fichier.
PUBLIC_ROUTES = {
    'GET /health',
    'POST /auth/merchant/register',
    'POST /auth/merchant/login',
    'POST /auth/flotte/register',
    'POST /auth/flotte/login',
    'POST /auth/login',
    'POST /auth/transporteur/register',
    'POST /auth/transporteur/login',
}


def public_drift(routes):
    """
    Ce qui s'est ouvert, et ce qui s'est refermé.

    Les deux sont des écarts, mais ils ne se lisent pas pareil : une route
    **ouverte** en plus est une brèche, une route **refermée** est une bonne
    nouvelle dont la liste n'a pas été prévenue. Les confondre ferait traiter
    un progrès comme un incident, et un incident comme un oubli de tenue à jour.
    """
    seen = {'%s %s' % (r['verb'], r['path']) for r in routes if r['public']}
    return sorted(seen - PUBLIC_ROUTES), sorted(PUBLIC_ROUTES - seen)


# ── Énumération ──────────────────────────────────────────────────────────────

def enumerate_routes(src_dir=SRC):
    """Toutes les routes déclarées, avec leur exposition et leur rôle exigé."""
    routes = []
    for root, _, files in os.walk(src_dir):
        for fn in files:
            if not fn.endswith('.controller.ts'):
                continue
            path = os.path.join(root, fn)
            with open(path, encoding='utf-8') as fh:
                src = fh.read()
            routes.extend(parse_controller(src, os.path.relpath(path, src_dir)))
    return routes


def parse_controller(src, origin='?'):
    """Les routes d'un contrôleur. Fonction pure : c'est elle qu'on éprouve."""
    prefix_m = re.search(r"@Controller\(\s*'([^']*)'\s*\)", src)
    prefix = prefix_m.group(1) if prefix_m else ''

    # `@Persona` posé sur la CLASSE : il vaut pour toutes ses routes. On le
    # reconnaît à ce qu'il précède `@Controller`, seule marque fiable.
    cls_m = re.search(r"@Persona\(\s*'([^']+)'\s*\)\s*\n\s*@Controller", src)
    cls_persona = cls_m.group(1) if cls_m else None

    routes = []
    pending_public = False
    pending_persona = None
    for line in src.split('\n'):
        t = line.strip()
        if t.startswith('@Public'):
            pending_public = True
            continue
        mp = re.match(r"@Persona\(\s*'([^']+)'\s*\)", t)
        if mp:
            pending_persona = mp.group(1)
            continue
        mr = re.match(r"@(%s)\(\s*'?([^')]*)'?\s*\)" % '|'.join(VERBS), t)
        if mr:
            sub = mr.group(2).strip()
            full = '/' + '/'.join(p for p in (prefix, sub) if p)
            routes.append({
                'verb': mr.group(1).upper(),
                'path': full,
                'public': pending_public,
                'persona': pending_persona or cls_persona,
                'origin': origin,
            })
            pending_public = False
            pending_persona = None
    return routes


def concrete(path):
    """Une URL appelable : les paramètres deviennent des valeurs inexistantes."""
    return re.sub(r':[A-Za-z_]\w*', BOGUS_ID, path)


# ── Verdict ──────────────────────────────────────────────────────────────────

EXPECTED = {
    'aucun jeton': (401, 'auth.missing_token'),
    'jeton révoqué': (401, 'auth.session_revoked'),
    'mauvais rôle': (403, 'server.persona_forbidden'),
}


def verdict(case, status, code):
    """
    Ce refus est-il celui qu'on attend ?

    ⚠️ Le statut **et** le code. Un 401 sans code passerait pour une protection
    correcte alors que l'application n'aurait rien à traduire — et c'est
    précisément la porte par laquelle un message générique remplace un refus
    explicite (règle 3).

    ⚠️ Le 429 est rendu à part, jamais confondu avec un refus : le débit est
    plafonné à 120/min et le banc en fait plusieurs centaines. Le prendre pour
    un succès ferait passer un banc entier de faux verts.
    """
    if status == 429:
        return ('débit', 'plafond de débit atteint — cet appel ne prouve rien')
    want_status, want_code = EXPECTED[case]
    if status != want_status:
        return ('échec', 'statut %s au lieu de %s' % (status, want_status))
    if code != want_code:
        return ('échec', 'code %r au lieu de %r' % (code, want_code))
    return ('ok', '')


# ── Appels ───────────────────────────────────────────────────────────────────

def call(base, verb, path, token=None, timeout=20):
    """Rend (statut, code). Ne lève pas : un refus arrive en HTTP, pas en exception."""
    url = base.rstrip('/') + path
    body = b'{}' if verb in ('POST', 'PUT', 'PATCH') else None
    req = urllib.request.Request(url, data=body, method=verb)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, _code(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, _code(err.read())
    except Exception as err:                      # réseau, DNS, BFF éteint
        return 0, 'transport:%s' % err


def _code(raw):
    try:
        return (json.loads(raw.decode('utf-8')) or {}).get('code')
    except Exception:
        return None


def login(base, email, password):
    req = urllib.request.Request(
        base.rstrip('/') + '/auth/login',
        data=json.dumps({'email': email, 'password': password}).encode('utf-8'),
        method='POST')
    req.add_header('Content-Type', 'application/json')
    with urllib.request.urlopen(req, timeout=30) as resp:
        return (json.loads(resp.read().decode('utf-8')) or {}).get('token')


# ── Auto-test (règle 8) ──────────────────────────────────────────────────────

def self_test():
    """
    Le banc doit prouver qu'il sait dire non — sur son énumération comme sur son
    verdict. Autant de cas qui DOIVENT échouer que de cas qui doivent passer.
    """
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print('   ✗ %s : %r au lieu de %r' % (label, got, want))
        else:
            print('   ✓ %s' % label)

    print('— énumération —')
    src = """
@Persona('merchant')
@Controller('commercant')
export class C {
  @Get('commandes')
  a() {}
  @Public()
  @Post('ouvert')
  b() {}
  @Get('commandes/:id')
  c() {}
  @Persona('fleet')
  @Delete('special')
  d() {}
}
"""
    rs = parse_controller(src)
    check('quatre routes trouvées', len(rs), 4)
    check('préfixe appliqué', rs[0]['path'], '/commercant/commandes')
    check('rôle de classe hérité', rs[0]['persona'], 'merchant')
    check('@Public reconnu', rs[1]['public'], True)
    # ⚠️ Cas qui a cassé une version antérieure : `@Public` ne doit PAS fuir
    # sur la route suivante.
    check('@Public ne déborde pas', rs[2]['public'], False)
    check('rôle de méthode gagne', rs[3]['persona'], 'fleet')
    check('paramètre rendu concret', concrete(rs[2]['path']),
          '/commercant/commandes/' + BOGUS_ID)

    print('— refus attendus —')
    check('401 + bon code = ok', verdict('aucun jeton', 401, 'auth.missing_token')[0], 'ok')
    check('403 + bon code = ok',
          verdict('mauvais rôle', 403, 'server.persona_forbidden')[0], 'ok')

    print('— ce que le banc DOIT refuser —')
    check('200 refusé', verdict('aucun jeton', 200, None)[0], 'échec')
    check('404 refusé', verdict('aucun jeton', 404, 'x')[0], 'échec')
    # Le cas le plus insidieux : la protection marche, mais sans code.
    check('401 sans code refusé', verdict('aucun jeton', 401, None)[0], 'échec')
    check('bon statut mauvais code refusé',
          verdict('jeton révoqué', 401, 'auth.missing_token')[0], 'échec')
    # ⚠️ Un jeton mort qui atteint le contrôle de rôle : l'ordre des gardes a
    # changé, et le banc doit le voir plutôt que de l'accepter.
    check('403 sur jeton révoqué refusé',
          verdict('jeton révoqué', 403, 'server.persona_forbidden')[0], 'échec')
    check('429 isolé, jamais compté comme succès',
          verdict('aucun jeton', 429, None)[0], 'débit')

    print('— l’épinglage des routes ouvertes —')
    # C'est LE cas qui manquait : la mutation réelle passait au vert.
    ouvert = [{'verb': 'GET', 'path': '/commercant/commandes', 'public': True,
               'persona': 'merchant', 'origin': 't'}]
    check('une route ouverte en trop est vue', public_drift(ouvert)[0],
          ['GET /commercant/commandes'])
    epinglees = [{'verb': v, 'path': q, 'public': True, 'persona': None, 'origin': 't'}
                 for v, q in (x.split(' ', 1) for x in PUBLIC_ROUTES)]
    check('l’ensemble attendu ne dérive pas', public_drift(epinglees), ([], []))
    check('une route refermée est signalée à part',
          public_drift(epinglees[:-1])[1] != [], True)

    print('— le plancher —')
    check('énumération effondrée détectable', len(parse_controller('')) < MIN_ROUTES, True)

    print('✅ auto-test réussi' if ok else '❌ auto-test ÉCHOUÉ')
    return 0 if ok else 1


# ── Le banc ──────────────────────────────────────────────────────────────────

def run():
    base = os.environ.get('BFF_URL', 'http://localhost:3001')
    password = os.environ.get('PASSWORD', 'motdepasse123')
    accounts = {
        'merchant': os.environ.get('MERCHANT_EMAIL', 'app-parcours-commercant@echango.local'),
        'fleet': os.environ.get('FLEET_EMAIL', 'app-parcours-entreprise@echango.local'),
        'transporteur': os.environ.get('DRIVER_EMAIL', 'driver-test-10000@echango.local'),
    }
    # ⚠️ Le débit global est de 120/min et ce banc fait plusieurs centaines
    # d'appels. Sans cadence, la moitié reviendrait en 429 — que le verdict
    # refuse de compter comme un succès, donc le banc échouerait pour une
    # raison qui n'a rien à voir avec la sécurité.
    pace = float(os.environ.get('PACE_SECONDS', '0.55'))

    routes = enumerate_routes()
    public = [r for r in routes if r['public']]
    guarded = [r for r in routes if not r['public']]

    print('routes énumérées : %d  (%d publiques, %d protégées)'
          % (len(routes), len(public), len(guarded)))
    if len(routes) < MIN_ROUTES:
        print('❌ énumération sous le plancher de %d — le banc REFUSE de conclure.'
              % MIN_ROUTES)
        print('   Un banc vide passe au vert : « rien à signaler » et « je n’ai')
        print('   rien regardé » ne se disent pas pareil.')
        return 2

    # ⚠️ **Avant tout appel.** Une route devenue publique quitte l'ensemble
    # testé : sans ce contrôle, l'ouvrir ferait *baisser* le nombre d'échecs.
    ouvertes, refermees = public_drift(routes)
    print('\nroutes publiques déclarées (chacune est une décision, cf. règle 12) :')
    for r in public:
        marque = '  <- NON EPINGLEE' if '%s %s' % (r['verb'], r['path']) in ouvertes else ''
        print('   %-6s %-40s%s' % (r['verb'], r['path'], marque))

    if ouvertes:
        print('\n❌ %d route(s) OUVERTE(S) sans décision : elles ne sont plus'
              % len(ouvertes))
        print('   protégées, et elles ont quitté l’ensemble testé en silence.')
        for x in ouvertes:
            print('     %s' % x)
        print('   Si l’ouverture est voulue, l’inscrire dans PUBLIC_ROUTES —')
        print('   c’est le seul endroit où cette décision se prend.')
        return 1
    if refermees:
        print('\n⚠️ %d route(s) épinglée(s) comme publiques ne le sont plus.'
              % len(refermees))
        print('   Ce n’est pas une brèche — c’est la liste qui a vieilli. À jour :')
        for x in refermees:
            print('     %s' % x)
        return 1

    tokens = {}
    for kind, email in accounts.items():
        try:
            tokens[kind] = login(base, email, password)
        except Exception as err:
            print('❌ connexion %s impossible (%s) — le banc ne prouve RIEN sans jeton.'
                  % (kind, err))
            return 2
        if not tokens[kind]:
            print('❌ aucun jeton pour %s — banc annulé.' % kind)
            return 2
        time.sleep(1)
    print('\njetons obtenus : %s' % ', '.join(sorted(tokens)))

    failures = []
    throttled = 0
    tested = 0

    def probe(case, route, token):
        nonlocal throttled, tested
        status, code = call(base, route['verb'], concrete(route['path']), token)
        time.sleep(pace)
        tested += 1
        state, why = verdict(case, status, code)
        if state == 'débit':
            throttled += 1
        elif state == 'échec':
            failures.append((case, route['verb'], route['path'], why))

    # ── 1. Aucun jeton ────────────────────────────────────────────────────────
    print('\n=== 1. aucun jeton — %d routes ===' % len(guarded))
    for r in guarded:
        probe('aucun jeton', r, None)

    # ── 2. Mauvais rôle ───────────────────────────────────────────────────────
    #
    # ⚠️ Seules les routes qui EXIGENT un rôle. Les autres (`/auth/verify`)
    # acceptent tout jeton valide : les y soumettre attendrait un refus qui n'a
    # aucune raison d'arriver, et le banc accuserait le mauvais coupable.
    with_role = [r for r in guarded if r['persona']]
    print('\n=== 2. jeton valide, mauvais rôle — %d routes ===' % len(with_role))
    for r in with_role:
        other = next(k for k in tokens if k != r['persona'])
        probe('mauvais rôle', r, tokens[other])

    # ── 3. Jeton révoqué ──────────────────────────────────────────────────────
    #
    # Révoqué EN DERNIER, et seulement celui du commerçant : les deux autres
    # servent encore au test de rôle ci-dessus. `revoquer-sessions` incrémente
    # `tokenVersion`, ce que le garde compare au claim `tv` du jeton.
    print('\n=== 3. jeton révoqué ===')
    status, code = call(base, 'POST', '/auth/revoquer-sessions', tokens['merchant'])
    if status not in (200, 201):
        print('❌ révocation impossible (%s / %s) — cette section ne prouve RIEN.'
              % (status, code))
        return 2
    print('   sessions du commerçant révoquées ; son jeton doit être mort partout')
    dead = tokens['merchant']
    # Sur TOUTES les routes protégées, y compris celles d'un autre rôle : le
    # garde de jeton passe avant celui de rôle, et un 403 ici dirait que cet
    # ordre a changé.
    for r in guarded:
        probe('jeton révoqué', r, dead)

    # ── Verdict ───────────────────────────────────────────────────────────────
    print('\n' + '=' * 64)
    print('  %d appels, %d refus attendus obtenus, %d échecs, %d plafonnés'
          % (tested, tested - len(failures) - throttled, len(failures), throttled))
    if throttled:
        print('  ⚠️ %d appels ont buté sur le plafond de débit : ils ne prouvent rien.'
              % throttled)
        print('     Augmenter PACE_SECONDS et relancer.')
    for case, verb, path, why in failures[:40]:
        print('  ❌ [%s] %-6s %-45s %s' % (case, verb, path, why))
    print('=' * 64)

    if failures:
        print('❌ des routes ne refusent pas ce qu’elles devraient refuser.')
        return 1
    if throttled:
        print('⚠️ aucun échec, mais %d appels non concluants — verdict PARTIEL.' % throttled)
        return 1
    print('✅ les %d routes protégées refusent les trois cas.' % len(guarded))
    return 0


if __name__ == '__main__':
    # ⚠️ La console Windows est en cp1252 : sans cette ligne, le banc meurt sur
    # sa première coche au lieu de rendre son verdict — un plantage qui se lit
    # comme un échec de ce qu'il mesure.
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

    if '--self-test' in sys.argv:
        sys.exit(self_test())
    if '--list' in sys.argv:
        print(json.dumps(enumerate_routes(), ensure_ascii=False, indent=1))
        sys.exit(0)
    sys.exit(run())
