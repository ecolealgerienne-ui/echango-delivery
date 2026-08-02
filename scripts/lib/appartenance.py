#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Le banc d'appartenance : un jeton valide ne donne pas droit à la ressource d'un autre.

── Pourquoi ce banc est distinct du banc de refus (règle 12) ─────────────────

`test-frontiere-http.sh` prouve **qui** vous êtes : sans jeton, avec un jeton
mort, avec le mauvais rôle, la porte est fermée. Il ne prouve rien sur la
question suivante, qui est celle qui expose des données réelles :

  *ce jeton est valide — mais cette commande est-elle à lui ?*

Cette seconde vérification ne vit dans aucun garde. Elle est **artisanale**,
répartie dans quatre-vingt-dix services (`getMerchantWithValidation`,
`resolveOrder`, `getDriverOrFail`, `getFleetWithValidation`), et repose donc
sur le fait que chaque auteur y a pensé. **Quarante et une routes prennent un
identifiant dans l'URL** ; au 02/08/2026, aucune n'avait jamais été appelée
avec l'identifiant de quelqu'un d'autre.

── Ce qui rend ce banc non tautologique, et c'est tout l'enjeu ───────────────

⚠️ **Un identifiant du mauvais TYPE rend 404 partout.** Passer un uuid de
commande à `/commercant/adresses/:id` donne « introuvable » — et un banc naïf y
lirait « l'appartenance est vérifiée ». Il aurait tout au vert sans avoir rien
prouvé, exactement comme le banc wilaya aurait conclu sur une mutation qui
n'avait jamais compilé.

D'où la forme en **deux temps, obligatoire** :

  1. **le témoin** — A appelle la route sur SA ressource, et doit obtenir 2xx.
     C'est ce qui établit que l'identifiant est réel, du bon type, et que la
     route fonctionne ;
  2. **l'épreuve** — B appelle la MÊME route sur la MÊME ressource, et doit
     être refusé.

Sans (1), un refus en (2) ne veut rien dire. Le banc **refuse de conclure**
quand le témoin échoue, plutôt que de compter un succès.

⚠️ **Et les identifiants ne sont pas écrits en dur** : ils sont découverts en
listant les ressources de A. Un identifiant recopié vieillit, disparaît, et le
banc se met alors à prouver « 404 sur une commande supprimée ».

── Ce que « refusé » veut dire, et pourquoi 404 plutôt que 403 ──────────────

Le pire cas admis est **« introuvable »**, jamais « la ressource de quelqu'un
d'autre ». 404 est même préférable à 403 : répondre « interdit » confirme que
l'identifiant existe, ce qui renseigne un curieux. Les deux sont acceptés ici —
c'est l'accès qui est en cause, pas la finesse du message.

⚠️ **Un 2xx est le seul échec vraiment grave**, et c'est le seul que ce banc
traite comme tel. Un 400 (validation) est compté « non concluant » : la route a
refusé, mais peut-être pour une raison qui n'a rien à voir avec l'appartenance.

── Ce que ce banc ne couvre PAS, et il faut le dire ─────────────────────────

Les routes où l'appartenance n'est **pas** la bonne question : accepter une
course libre (`/transporteur/commandes/:id/accepter`), prendre une opportunité
(`/flotte/opportunites/:id/prendre`). Elles sont **ouvertes à tout le persona**
par conception — les y soumettre attendrait un refus qui n'a aucune raison
d'arriver, et le banc accuserait le mauvais coupable.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get('BFF_URL', 'http://localhost:3001')
PASSWORD = os.environ.get('PASSWORD', 'motdepasse123')
PACE = float(os.environ.get('PACE_SECONDS', '0.55'))


# ── Les trois personas, chacun avec ses deux comptes et ses routes ───────────
#
# `list` sert à DÉCOUVRIR une ressource de A ; `witness` est la route dont le
# 2xx pour A établit que l'identifiant est bon ; `probes` est ce que B doit se
# voir refuser.
PERSONAS = [
    {
        'nom': 'commerçant',
        'a': os.environ.get('MERCHANT_EMAIL', 'app-parcours-commercant@echango.local'),
        'b': os.environ.get('MERCHANT_B_EMAIL', 'appartenance-commercant-b@echango.local'),
        'inscription': ('/auth/merchant/register',
                        {'businessName': 'Témoin appartenance', 'phone': '0555000101'}),
        'list': '/commercant/commandes?limit=5',
        'witness': ('GET', '/commercant/commandes/{id}'),
        'probes': [
            ('GET', '/commercant/commandes/{id}'),
            ('GET', '/commercant/commandes/{id}/modele'),
            ('GET', '/commercant/commandes/{id}/suivi'),
            ('GET', '/commercant/commandes/{id}/position'),
            ('GET', '/commercant/commandes/{id}/preuve'),
            ('POST', '/commercant/commandes/{id}/annuler'),
            ('POST', '/commercant/commandes/{id}/publier'),
            ('POST', '/commercant/commandes/{id}/encaissement',
             {'collectedAmount': 0}),
        ],
    },
    {
        'nom': 'entreprise',
        'a': os.environ.get('FLEET_EMAIL', 'app-parcours-entreprise@echango.local'),
        'b': os.environ.get('FLEET_B_EMAIL', 'appartenance-entreprise-b@echango.local'),
        'inscription': ('/auth/flotte/register',
                        {'businessName': 'Flotte témoin', 'phone': '0555000102'}),
        'list': '/flotte/commandes?limit=5',
        'witness': ('GET', '/flotte/commandes/{id}'),
        'probes': [
            ('GET', '/flotte/commandes/{id}'),
            ('POST', '/flotte/commandes/{id}/assigner',
             {'driverId': 'zzz-inexistant-0000'}),
        ],
    },
]


def call(verb, path, token=None, body=None, timeout=25):
    url = BASE.rstrip('/') + path
    data = json.dumps(body or {}).encode('utf-8') if verb in ('POST', 'PUT', 'PATCH') else None
    req = urllib.request.Request(url, data=data, method=verb)
    req.add_header('Content-Type', 'application/json')
    if token:
        req.add_header('Authorization', 'Bearer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, _body(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, _body(err.read())
    except Exception as err:
        return 0, {'code': 'transport:%s' % err}


def _body(raw):
    try:
        return json.loads(raw.decode('utf-8'))
    except Exception:
        return {}


def login(email, patience=6):
    """
    Se connecter, en distinguant « refusé » de « trop vite ».

    ⚠️ **Ce banc épuise le plafond de connexion tout seul.** Il est de 5 par
    minute et le banc en fait jusqu'à six (deux comptes par persona, plus la
    reconnexion d'après inscription). Sans cette attente, il rapportait
    « persona NON COUVERT » — un verdict qui accuse l'appartenance pour un
    problème de débit. Constaté sur ce banc même, deux fois.

    Un 429 n'est donc pas un échec de connexion : c'est « pas encore ».
    """
    for essai in range(patience):
        status, body = call('POST', '/auth/login',
                            body={'email': email, 'password': PASSWORD})
        if status in (200, 201):
            return body.get('token')
        if status != 429:
            return None
        attente = 20
        print('      (plafond de connexion atteint — %ds avant nouvel essai)' % attente)
        time.sleep(attente)
    print('      (plafond de connexion tenace — abandon après %d essais)' % patience)
    return None


def ensure(email, route, extra):
    """
    Le compte B, créé une seule fois. Connexion d'abord : une réinscription à
    chaque passage consommerait le plafond horaire (10/h) que la suite des
    scénarios remplit déjà presque.
    """
    token = login(email)
    if token:
        return token, False
    payload = dict(extra)
    payload.update({'email': email, 'password': PASSWORD})
    status, body = call('POST', route, body=payload)
    if status not in (200, 201):
        print('      inscription refusée : HTTP %s · %s · %s'
              % (status, body.get('code'), body.get('message')))
        return None, False
    token = login(email)
    if not token:
        # Un compte créé mais non connectable : le dire, plutôt que de laisser
        # croire que l'inscription a échoué.
        print('      compte créé mais connexion refusée — validation en attente ?')
    return token, True


def first_id(body):
    """Le premier identifiant d'une liste, quelle que soit son enveloppe."""
    rows = body if isinstance(body, list) else (
        body.get('data') or body.get('orders') or [])
    for row in rows:
        for key in ('uuid', 'public_id', 'id'):
            if row.get(key):
                return row[key]
    return None


def verdict(status):
    """
    ⚠️ Trois issues, et les confondre serait le défaut de ce banc.

    - **2xx** : la ressource d'autrui a été servie. C'est le seul vrai échec, et
      il est grave.
    - **403/404** : refusé. C'est ce qu'on attend.
    - **le reste** (400, 429, 500…) : la route a refusé, mais peut-être pour une
      raison étrangère à l'appartenance. Non concluant — jamais compté comme un
      succès, sinon un banc entier pourrait passer sur des erreurs de validation.
    """
    if 200 <= status < 300:
        return 'brèche'
    if status in (403, 404):
        return 'refusé'
    return 'non concluant'


def run():
    print('banc d’appartenance — la ressource de A doit être refusée à B\n')
    total_refus = 0
    breaches = []
    unclear = []
    skipped = []

    for p in PERSONAS:
        print('══ %s ══' % p['nom'])
        token_a = login(p['a'])
        if not token_a:
            print('   ❌ connexion A impossible (%s) — persona NON COUVERT' % p['a'])
            skipped.append(p['nom'])
            continue
        time.sleep(1)
        token_b, created = ensure(p['b'], *p['inscription'])
        if not token_b:
            print('   ❌ compte B indisponible (%s) — persona NON COUVERT' % p['b'])
            skipped.append(p['nom'])
            continue
        if created:
            print('   (compte B créé — une inscription consommée, une seule fois)')

        status, body = call('GET', p['list'], token_a)
        rid = first_id(body) if 200 <= status < 300 else None
        if not rid:
            print('   ❌ aucune ressource chez A (liste %s) — persona NON COUVERT' % status)
            skipped.append(p['nom'])
            continue
        print('   ressource de A : %s' % rid)

        # ── Le témoin, sans lequel tout refus serait creux ────────────────────
        wverb, wpath = p['witness']
        wstatus, _ = call(wverb, wpath.format(id=rid), token_a)
        time.sleep(PACE)
        if not 200 <= wstatus < 300:
            print('   ❌ témoin manqué : A n’obtient pas sa propre ressource (%s).' % wstatus)
            print('      Sans lui, un 404 pour B ne prouverait rien — persona NON COUVERT.')
            skipped.append(p['nom'])
            continue
        print('   témoin : A lit bien sa ressource (%s)' % wstatus)

        for sonde in p['probes']:
            verb, path = sonde[0], sonde[1]
            corps = sonde[2] if len(sonde) > 2 else None
            status, body = call(verb, path.format(id=rid), token_b, corps)
            time.sleep(PACE)
            issue = verdict(status)
            if issue == 'brèche':
                breaches.append((p['nom'], verb, path, status))
                print('   ❌ %-6s %-44s SERVIE À B (%s)' % (verb, path, status))
            elif issue == 'non concluant':
                unclear.append((p['nom'], verb, path, status, body.get('code')))
                print('   ⚠️ %-6s %-44s %s / %s' % (verb, path, status, body.get('code')))
            else:
                total_refus += 1
                print('   ✓ %-6s %-44s %s' % (verb, path, status))
        print()

    print('=' * 64)
    print('  %d refus constatés · %d brèche(s) · %d non concluant(s) · %d persona(s) non couvert(s)'
          % (total_refus, len(breaches), len(unclear), len(skipped)))
    if skipped:
        print('  ⚠️ non couverts : %s — leur silence n’est PAS un succès.' % ', '.join(skipped))
    print('=' * 64)

    if breaches:
        print('❌ des ressources d’autrui sont servies.')
        return 1
    if skipped or unclear:
        print('⚠️ aucune brèche vue, mais la couverture est incomplète — verdict PARTIEL.')
        return 1
    print('✅ toutes les routes éprouvées refusent la ressource d’autrui.')
    return 0


def self_test():
    ok = True

    def check(label, got, want):
        nonlocal ok
        if got != want:
            ok = False
            print('   ✗ %s : %r au lieu de %r' % (label, got, want))
        else:
            print('   ✓ %s' % label)

    print('— le verdict —')
    check('403 = refusé', verdict(403), 'refusé')
    check('404 = refusé', verdict(404), 'refusé')
    print('— ce que le banc DOIT refuser —')
    check('200 = brèche', verdict(200), 'brèche')
    check('201 = brèche', verdict(201), 'brèche')
    # ⚠️ Le cas qui compte : un 400 ressemble à un refus et n'en est pas un.
    check('400 non concluant', verdict(400), 'non concluant')
    check('429 non concluant', verdict(429), 'non concluant')
    check('500 non concluant', verdict(500), 'non concluant')

    print('— la découverte d’identifiant —')
    check('uuid préféré', first_id({'data': [{'uuid': 'u1', 'id': 3}]}), 'u1')
    check('enveloppe orders', first_id({'orders': [{'public_id': 'o1'}]}), 'o1')
    check('liste nue', first_id([{'id': 'x'}]), 'x')
    # Une liste vide ne doit pas fabriquer d'identifiant : le persona sera
    # déclaré non couvert, et c'est la bonne réponse.
    check('liste vide ⇒ rien', first_id({'data': []}), None)
    check('ligne sans identifiant ⇒ rien', first_id({'data': [{'x': 1}]}), None)

    print('✅ auto-test réussi' if ok else '❌ auto-test ÉCHOUÉ')
    return 0 if ok else 1


if __name__ == '__main__':
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
    sys.exit(self_test() if '--self-test' in sys.argv else run())
