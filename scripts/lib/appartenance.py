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
import re
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get('BFF_URL', 'http://localhost:3001')
PASSWORD = os.environ.get('PASSWORD', 'motdepasse123')
PACE = float(os.environ.get('PACE_SECONDS', '0.55'))

# Conducteur réel employé pour poser les décors (favori, invitation). Réglable
# pour un autre environnement ; un identifiant inventé serait refusé.
SONDE_DRIVER = os.environ.get('SONDE_DRIVER_UUID',
                              'eec8c72d-fd1e-4416-b516-69b584a1a65b')


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
        'ressources': [
            {
                'quoi': 'commande',
                'list': '/commercant/commandes?limit=5',
                # Le témoin fort : A obtient sa ressource par cette route même.
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
                'quoi': 'adresse du carnet',
                'list': '/commercant/adresses',
                # ⚠️ **Aucun témoin fort possible : il n'existe pas de
                # `GET /commercant/adresses/:id`.** Le seul témoin est que
                # l'identifiant vient de la liste de A — il est donc réel, du bon
                # type, et à lui. C'est plus faible, et le rapport le dit :
                # exercer PUT ou DELETE avec le jeton de A pour prouver que la
                # route marche **détruirait sa donnée**.
                'witness': None,
                'probes': [
                    ('PUT', '/commercant/adresses/{id}',
                     {'name': 'sonde', 'contactPhone': '0555000199',
                      'latitude': 36.75, 'longitude': 3.06}),
                    ('DELETE', '/commercant/adresses/{id}'),
                ],
            },
            {
                'quoi': 'notification',
                'list': '/commercant/notifications',
                # Pas de `GET /commercant/notifications/:id` : témoin faible,
                # l'identifiant vient de la liste de A.
                'witness': None,
                'probes': [
                    ('POST', '/commercant/notifications/{id}/lu'),
                ],
            },
            {
                'quoi': 'favori',
                'list': '/commercant/transporteurs/favoris',
                'witness': None,
                # ⚠️ A n'a pas toujours de favori, et une ressource « non
                # éprouvée » à chaque passage rendrait le banc durablement
                # rouge — donc ignoré. Le banc pose son propre décor et le
                # retire : il ne dépend pas de l'état laissé par d'autres.
                # ⚠️ Un identifiant inventé est REFUSÉ (400) : la route vérifie
                # que le conducteur existe. Il faut donc un vrai — celui du
                # conducteur de test, réglable pour un autre environnement.
                'provision': ('POST', '/commercant/transporteurs/favoris',
                              {'fleetbaseDriverUuid': SONDE_DRIVER,
                               'driverName': 'Sonde appartenance',
                               'partyType': 'driver'}),
                'cleanup': ('DELETE', '/commercant/transporteurs/favoris/{id}'),
                'probes': [
                    ('DELETE', '/commercant/transporteurs/favoris/{id}'),
                ],
            },
        ],
    },
    {
        'nom': 'entreprise',
        'a': os.environ.get('FLEET_EMAIL', 'app-parcours-entreprise@echango.local'),
        'b': os.environ.get('FLEET_B_EMAIL', 'appartenance-entreprise-b@echango.local'),
        'ressources': [
            {
                'quoi': 'commande',
                'list': '/flotte/commandes?limit=5',
                'witness': ('GET', '/flotte/commandes/{id}'),
                'probes': [
                    ('GET', '/flotte/commandes/{id}'),
                    ('POST', '/flotte/commandes/{id}/assigner',
                     {'driverId': 'zzz-inexistant-0000'}),
                ],
            },
            {
                'quoi': 'adhésion',
                'list': '/flotte/adhesions',
                'witness': None,
                # ⚠️ Décor léger et **inerte** : une invitation en attente ne
                # rattache personne tant que le conducteur ne l'accepte pas.
                # Elle est conservée d'un passage à l'autre (la liste est lue
                # d'abord), donc le banc n'en accumule pas.
                'provision': ('POST', '/flotte/conducteurs/{driver}/adhesion', {}),
                'probes': [
                    ('POST', '/flotte/adhesions/{id}/suspendre'),
                    ('POST', '/flotte/adhesions/{id}/reactiver'),
                ],
            },
        ],
    },
    {
        'nom': 'transporteur',
        'a': os.environ.get('DRIVER_EMAIL', 'driver-test-10000@echango.local'),
        'b': os.environ.get('DRIVER_B_EMAIL', 'transporteur-test-4093@echango.local'),
        # ⚠️ **Pas d'inscription possible ici** : un conducteur entre par
        # invitation, pas par un formulaire ouvert. Les deux comptes doivent
        # donc préexister — à défaut le persona est déclaré NON COUVERT, ce qui
        # est la bonne réponse : mieux vaut un trou nommé qu'un vert supposé.
        'sans_inscription': True,
        'ressources': [
            {
                'quoi': 'course assignée',
                'list': '/transporteur/commandes?type=assigned',
                'witness': ('GET', '/transporteur/commandes/{id}'),
                # `accepter` et `refuser` sont exclus : une course **libre** est
                # ouverte à tout transporteur, et l'appartenance n'y est pas la
                # question. Ici la course est assignée à A, donc les gestes qui
                # la font avancer n'appartiennent qu'à lui.
                'probes': [
                    ('GET', '/transporteur/commandes/{id}'),
                    ('GET', '/transporteur/commandes/{id}/activites-suivantes'),
                    ('POST', '/transporteur/commandes/{id}/demarrer'),
                    ('POST', '/transporteur/commandes/{id}/terminer',
                     {'collectedAmount': 0}),
                    ('POST', '/transporteur/commandes/{id}/activite',
                     {'activity': {'code': 'dispatched'}}),
                    ('POST', '/transporteur/commandes/{id}/echec',
                     {'reason': 'client_absent'}),
                ],
            },
            {
                'quoi': 'rattachement à une entreprise',
                'list': '/transporteur/entreprises',
                'witness': None,
                'probes': [
                    ('POST', '/transporteur/entreprises/{id}/accepter'),
                    ('POST', '/transporteur/entreprises/{id}/refuser'),
                    ('POST', '/transporteur/entreprises/{id}/quitter'),
                ],
            },
            {
                'quoi': 'encaissement',
                'list': '/transporteur/caisse/encaissements',
                'witness': None,
                # ⚠️ **Absence NOTÉE, pas fatale — et c'est un arbitrage.**
                #
                # Un encaissement n'existe qu'après une livraison payée à la
                # porte. En poser un demanderait d'écrire dans le **registre de
                # caisse**, et un banc de sécurité n'a pas à créer des écritures
                # comptables pour prouver un refus — la remise à zéro d'un
                # registre est déjà réservée au développement, avec un aveu
                # explicite.
                #
                # Faire échouer le banc quand la base n'en porte pas le rendrait
                # **durablement rouge**, donc ignoré — et un banc ignoré ne
                # protège rien. Il le dit à chaque passage, dans le récapitulatif,
                # plutôt que de se taire ou de crier.
                'si_absent': 'noter',
                'probes': [
                    ('POST', '/transporteur/caisse/encaissements/{id}/confirmer'),
                    ('POST', '/transporteur/caisse/encaissements/{id}/contester',
                     {'reason': 'sonde d’appartenance'}),
                ],
            },
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


# ⚠️ Un identifiant que `FleetbaseIdPipe` refuse ne peut pas être sondé : la
# route répond 400 (`validation.invalid_id`) **avant** d'examiner
# l'appartenance, et la sonde ressort « non concluante ». Constaté : la liste
# des encaissements du transporteur mêle des lignes `earning:<uuid>`, dont le
# deux-points est hors du motif accepté. On ne retient donc que ce qui peut
# franchir le pipe — c'est le même motif, recopié nulle part ailleurs ici.
ID_ACCEPTABLE = re.compile(r'^[A-Za-z0-9_-]{1,64}$')


def first_id(body):
    """
    Le premier identifiant **sondable** d'une liste, quelle que soit son
    enveloppe. Rend `None` si aucun ne l'est — le persona sera alors déclaré
    non éprouvé, ce qui est la bonne réponse.
    """
    rows = body if isinstance(body, list) else (
        body.get('data') or body.get('orders') or [])
    if not isinstance(rows, list):
        return None
    for row in rows:
        if not isinstance(row, dict):
            continue
        for key in ('uuid', 'public_id', 'id'):
            valeur = row.get(key)
            if valeur and ID_ACCEPTABLE.match(str(valeur)):
                return valeur
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
    refus = 0
    breches, flous, non_couverts, notes = [], [], [], []

    for p in PERSONAS:
        print('══ %s ══' % p['nom'])
        token_a = login(p['a'])
        if not token_a:
            print('   ❌ connexion A impossible (%s) — persona NON COUVERT' % p['a'])
            non_couverts.append(p['nom'])
            continue

        if p.get('sans_inscription'):
            token_b = login(p['b'])
            if not token_b:
                print('   ❌ second compte indisponible (%s) et non inscriptible' % p['b'])
                print('      — un conducteur entre par invitation. Persona NON COUVERT.')
                non_couverts.append(p['nom'])
                continue
        else:
            token_b = login(p['b'])
            if not token_b:
                print('   ❌ compte B indisponible (%s) — persona NON COUVERT' % p['b'])
                non_couverts.append(p['nom'])
                continue

        for r in p['ressources']:
            status, body = call('GET', r['list'], token_a)
            rid = first_id(body) if 200 <= status < 300 else None
            pose = False
            if not rid and r.get('provision'):
                pverb, ppath, pbody = r['provision']
                # Certains décors désignent un conducteur dans leur chemin. Il
                # doit être RÉEL : un identifiant inventé est refusé en 400, et
                # la sonde ne prouverait rien.
                ppath = ppath.replace('{driver}', SONDE_DRIVER)
                pstatus, pbody_out = call(pverb, ppath, token_a, pbody)
                time.sleep(PACE)
                if 200 <= pstatus < 300:
                    rid = pbody_out.get('id') or pbody_out.get('uuid')
                    pose = bool(rid)
                if not pose:
                    print('   ⚠️ %s : décor impossible à poser (%s)' % (r['quoi'], pstatus))
            if not rid:
                if r.get('si_absent') == 'noter':
                    print('   ○ %s : absent de cet environnement — routes NON ÉPROUVÉES'
                          % r['quoi'])
                    notes.append('%s/%s (%d routes)'
                                 % (p['nom'], r['quoi'], len(r['probes'])))
                else:
                    print('   ⚠️ %s : aucune ressource chez A (liste %s) — NON ÉPROUVÉE'
                          % (r['quoi'], status))
                    non_couverts.append('%s/%s' % (p['nom'], r['quoi']))
                continue

            if r['witness']:
                wverb, wpath = r['witness']
                wstatus, _ = call(wverb, wpath.format(id=rid), token_a)
                time.sleep(PACE)
                if not 200 <= wstatus < 300:
                    print('   ❌ %s : témoin manqué — A n’obtient pas sa ressource (%s).'
                          % (r['quoi'], wstatus))
                    print('      Sans lui, un refus pour B ne prouverait rien. NON ÉPROUVÉE.')
                    non_couverts.append('%s/%s' % (p['nom'], r['quoi']))
                    continue
                temoin = 'A lit sa ressource (%s)' % wstatus
            else:
                # ⚠️ Témoin faible, et il est nommé comme tel : l'identifiant
                # vient de la liste de A, donc il est réel et à lui — mais
                # aucune route ne confirme qu'elle répond 2xx pour son
                # propriétaire, parce que l'exercer détruirait sa donnée.
                temoin = 'identifiant issu de la liste de A (témoin faible)'

            print('   %s %s — %s' % (r['quoi'], rid, temoin))
            for sonde in r['probes']:
                verb, path = sonde[0], sonde[1]
                corps = sonde[2] if len(sonde) > 2 else None
                status, body = call(verb, path.format(id=rid), token_b, corps)
                time.sleep(PACE)
                issue = verdict(status)
                if issue == 'brèche':
                    breches.append((p['nom'], verb, path, status))
                    print('      ❌ %-6s %-46s SERVIE À B (%s)' % (verb, path, status))
                elif issue == 'non concluant':
                    flous.append((p['nom'], verb, path, status, body.get('code')))
                    print('      ⚠️ %-6s %-46s %s / %s'
                          % (verb, path, status, body.get('code')))
                else:
                    refus += 1
                    print('      ✓ %-6s %-46s %s' % (verb, path, status))

            # Le décor posé par le banc repart avec lui : un favori oublié
            # changerait l'attribution des courses des scénarios suivants.
            if pose and r.get('cleanup'):
                cverb, cpath = r['cleanup']
                call(cverb, cpath.format(id=rid), token_a)
                time.sleep(PACE)
                print('      (décor retiré)')
        print()

    print('=' * 70)
    print('  %d refus constatés · %d brèche(s) · %d non concluant(s) · %d non couvert(s)'
          % (refus, len(breches), len(flous), len(non_couverts)))
    if non_couverts:
        print('  ⚠️ non couverts : %s' % ', '.join(non_couverts))
        print('     Leur silence n’est PAS un succès.')
    if notes:
        # Imprimé à chaque passage, exprès : ce qui n'apparaît pas finit oublié.
        print('  ○ absents de cet environnement, donc NON ÉPROUVÉS : %s'
              % ', '.join(notes))
        print('     Les poser demanderait d’écrire dans le registre de caisse.')
    print('=' * 70)

    if breches:
        print('❌ des ressources d’autrui sont servies.')
        return 1
    if non_couverts or flous:
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
    # ⚠️ Le cas réel : la liste des encaissements mêle des lignes `earning:<uuid>`
    # que `FleetbaseIdPipe` refuse. Les sonder donnait 400 avant toute question
    # d'appartenance — deux routes restaient non éprouvées sous couvert de refus.
    check('identifiant hors motif ignoré',
          first_id({'data': [{'id': 'earning:3c32-abc'}]}), None)
    check('la ligne suivante, sondable, est prise',
          first_id({'data': [{'id': 'earning:x'}, {'id': 'cmsc9nkde0018'}]}),
          'cmsc9nkde0018')
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
