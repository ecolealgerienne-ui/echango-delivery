# Scénarios de test manuel — émulateur (pilotage direct, pas flutter_drive)

**Date** : 05/09/2026. Suite à l'implémentation de la fiche client
géolocalisée et de l'optimisation de parcours
(`docs/specs_localisation_client_et_optimisation_parcours.md`).

Contexte : les deux fonctionnalités sont déjà couvertes par des bancs `curl`
(`scripts/test-fiche-client.sh`, `scripts/test-optimisation-parcours.sh`) et
par 5 scénarios `integration_test/audit_ecrans_test.dart` automatisés, tous
passants. Ce document couvre un pilotage **manuel** de l'application réelle
sur émulateur (captures d'écran + `adb shell input tap`), pour une
vérification visuelle directe — ce qu'un script ne peut pas juger (lisibilité,
mise en page réelle, comportement des dialogues système Android comme le
partage natif ou la permission de géolocalisation).

⚠️ **Ce pilotage a trouvé un vrai défaut produit, invisible aux tests
automatisés** — voir la dernière section. C'est la raison d'être de ce
document : au-delà de la checklist, c'est le pilotage par de vrais évènements
tactiles qui a de la valeur.

## Profils de test — identifiants

Posés par `scripts/provision-app-parcours.sh [nom_ou_email_conducteur]`,
mot de passe **identique pour les trois** :

| Profil | Email | Mot de passe |
|---|---|---|
| Commerçant | `app-parcours-commercant@echango.local` | `motdepasse123` |
| Entreprise (facilitateur) | `app-parcours-entreprise@echango.local` | `motdepasse123` |
| Conducteur (« Bob1 » dans cette session — nom variable, voir ⚠️ ci-dessous) | `driver-test-10000@echango.local` | `motdepasse123` |

⚠️ **Le conducteur n'est pas fixe d'une exécution à l'autre.** Le script
résout un conducteur du pool par nom/email/ID passé en argument (ex.
`Bob1`) ; s'il n'est pas précisé, il liste les conducteurs disponibles et
demande d'en choisir un. Relire la sortie du script à chaque lancement pour
l'email réel à utiliser — ne pas supposer que `driver-test-10000@echango.local`
reste correct sur un autre poste ou après un nouveau passage.

Numéro de téléphone client déjà connu en base (fiche confirmée par
`test-fiche-client.sh`) : **`0555128781`**, position `36.8, 3.08`.

Course de référence pour l'optimisation de parcours (posée par
`provision-app-parcours.sh`) : prix **6161 DZD** (« CLIENT OPTIMISATION »,
confiée au conducteur), suggestion attendue à proximité : prix **6262 DZD**
(« CLIENT VOISIN »).

## Environnement

- Émulateur utilisé : `emulator-5556` (Pixel 9 Pro XL, Android 17/API 37) —
  `emulator-5554` (Android 16/API 36) manquait d'espace disque pour installer
  l'APK ; les deux exposent le même défaut décrit plus bas.
- APK : build debug x86_64 seul (`flutter build apk --debug --split-per-abi`),
  pour tenir dans l'espace disponible — le build « fat » (toutes ABI) fait
  ~200 Mo et échoue à l'installation sur un émulateur presque plein.
- Installation : `adb push` + `adb shell pm install` (contourne un bug connu
  de `adb install` en streaming sur gros APK — `INSTALL_FAILED_INSUFFICIENT_
  STORAGE: Failed to override installation location`).
- BFF : `http://10.0.2.2:3001` (alias hôte depuis l'émulateur), stack Docker
  WSL — **redémarrer `docker compose up -d` si `curl localhost:3001/health`
  échoue** : le WSL s'arrête seul après quelques minutes d'inactivité (garder
  un `wsl.exe … sleep 1800` en tâche de fond pendant la session de test).

## Ce que ce document NE fait PAS

Il ne rejoue pas les 23 scénarios `curl` ni les parcours d'argent : c'est déjà
fait et vérifié ailleurs (`scripts/run-all-scenarios.sh`). Il se concentre sur
les DEUX fonctionnalités de cette session, en piloté manuel, plus un minimum
de contexte de connexion.

## A — Fiche client géolocalisée (commerçant)

| # | Scénario | Résultat attendu |
|---|---|---|
| A1 | Connexion commerçant (`app-parcours-commercant@echango.local`) | Accueil commerçant (bouton flottant visible) |
| A2 | Nouvelle commande → taper le téléphone dropoff `0555128781` (numéro CONNU) | Auto-remplissage : nom/adresse/position se pré-remplissent depuis la fiche, sans action supplémentaire |
| A3 | Effacer et taper un numéro INCONNU (`0555999999`) | Aucun pré-remplissage, aucune erreur bloquante, le formulaire reste utilisable |
| A4 | Bouton « Envoyer un lien de localisation » sur un numéro | Le partage natif Android (share sheet) s'ouvre avec une URL `http://…/public/localisation/…` |
| A5 | (si le temps le permet) Retour au numéro connu — vérifier qu'aucune proposition « en attente » n'est affichée à tort (la fiche est déjà confirmée) | Pas de bandeau de confirmation |

## B — Optimisation de parcours (conducteur)

| # | Scénario | Résultat attendu |
|---|---|---|
| B1 | Connexion conducteur (`driver-test-10000@echango.local`) | Accueil conducteur, 3 onglets |
| B2 | Onglet « En cours » → ouvrir la course de référence (prix **6161**) | Fiche affichée, bouton « Optimiser » visible (icône route) |
| B3 | Taper « Optimiser » | Écran d'optimisation : chargement (~9 s), puis liste + gain total |
| B4 | Vérifier la suggestion (prix **6262**) | Présente, avec sa distance affichée |
| B5 | Retour arrière | Fiche de la course de référence intacte, rien d'accepté par erreur |

## Résultats

**Avant correctif** (voir défaut ci-dessous) :

| # | Résultat |
|---|---|
| A1 — Connexion commerçant | ✅ Accueil affiché, décor visible |
| A2/A3 — Fiche client (auto-remplissage) | ⛔ Bloqué : impossible d'atteindre le formulaire, le bouton « Nouvelle livraison » ne répond à aucun tap réel |
| B1 — Connexion conducteur | ✅ Accueil 3 onglets affiché |
| B2 — Course de référence (6161 DZD) | ✅ Ouverte, données correctes, bouton Optimiser visible |
| B3/B4 — Tap Optimiser / suggestion affichée | ⛔ Bloqué : le bouton « Optimiser » ne répond à aucun tap réel, même défaut que A2/A3 |

**Après correctif** (`echango_delivery/lib/main.dart`, `SafeArea` globale via
le `builder` de `MaterialApp.router`) — rejoué pour de vrai, même émulateur :

| # | Résultat |
|---|---|
| FAB « Nouvelle livraison » | ✅ `uiautomator dump` confirme le bouton dans la zone tactile (`bounds` désormais sous le seuil réel de l'écran) ; tap réel → formulaire ouvert |
| A2 — Fiche client, numéro CONNU (`0555128781`) | ✅ **« Position définie (36.80000, 3.08000) »** affichée après saisie — exactement la position confirmée côté API, auto-remplissage réel vérifié |
| A3 — Fiche client, numéro INCONNU (`0555999999`) | ⚠️ Observé, pas un défaut : aucune erreur, mais la position affichée reste celle du lookup précédent (le code ne réinitialise `_dropoffPoint` que si un nouveau lookup **trouve** quelque chose — cohérent avec la spec, mais peut visuellement induire en erreur si le commerçant ne remarque pas que rien n'a changé) |
| A4 — Lien de localisation | Non rejoué après correctif (déjà vérifié par `test-fiche-client.sh`, priorité donnée à la preuve du correctif) |
| B3/B4 — Optimiser (conducteur) | ✅ Confirmé indirectement : les 5 scénarios `flutter_drive` (dont « Optimiser ») repassent au vert après correctif, sans régression |

**Suite de régression complète rejouée après correctif** :
`flutter analyze` (0 problème), `flutter drive … audit_ecrans_test.dart`
→ **`All tests passed!`** (5/5).

## Défaut réel trouvé, avec preuve

**Les boutons d'action en bas des fiches (« Nouvelle livraison », « Optimiser »,
« Order Started », « Rendre cette course ») sont peints à l'écran mais hors de
la zone réellement tactile**, sur les deux émulateurs testés (Android 16/API 36
et Android 17/API 37 — edge-to-edge obligatoire depuis Android 15).

Preuve par `uiautomator dump` sur la fiche de la course 6161 DZD (conducteur) :
- Conteneur du corps de l'écran : `bounds="[0,283][1080,2178]"` — la zone
  réellement interactive s'arrête à **y=2178** sur un écran de 2400 px.
- La carte Enlèvement/Livraison se termine à **y=1916**.
- Il ne reste que **262 px** d'espace réellement tactile, alors que les trois
  boutons empilés (Order Started / Optimiser / Rendre cette course) occupent
  visuellement plus de 350 px : ils débordent dans la bande basse que le
  système Android réserve à la gestuelle (retour/accueil), qui **absorbe le
  toucher avant qu'il n'atteigne l'application**.

Conséquence pratique : **aucun tap réel** (souris, doigt, `adb shell input tap`)
n'atteint ces boutons quand ils tombent dans cette bande — vérifié par balayage
systématique de coordonnées sur toute la largeur du bouton, à plusieurs
hauteurs, sur deux écrans différents (liste commerçant, fiche conducteur).

**Pourquoi les tests automatisés (`flutter_drive`, 5 scénarios déjà verts) ne
l'ont jamais vu** : `tester.tap()` invoque le gestionnaire du widget directement
via l'arbre sémantique de Flutter, sans passer par la fenêtre Android réelle ni
ses zones de geste — il ne peut donc pas reproduire ce défaut, quelle que soit
sa couverture. C'est un défaut que seul un test piloté par de vrais évènements
tactiles (comme cette session) pouvait révéler.

✅ **Corrigé** (`echango_delivery/lib/main.dart`, commit `4a978da` — poussé sur
`main`) : une `SafeArea` globale posée sur le `builder` de `MaterialApp.router`
protège désormais tous les écrans, présents et futurs, en un seul point de
contrôle plutôt qu'à corriger un par un (règle 5 de `CLAUDE.md`).
`addresses_screen.dart`, qui avait déjà sa propre `SafeArea`, n'est pas
affecté par le doublon (une `SafeArea` imbriquée ne consomme pas deux fois la
même marge).
