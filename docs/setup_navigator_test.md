# Setup et test Navigator — guide pratique

**Date** : 27 juillet 2026 — Question ouverte #3 du CLAUDE.md  
**Objectif** : Installer l'app officielle Fleetbase Navigator (React Native) en local, la configurer avec l'Organization "Echango Delivery", et valider :
1. Installation sans erreur + rebrand simple
2. Connexion d'un driver réel
3. Réception d'une commande adhoc (dispatch notifié réellement)
4. Réception d'une assignation ciblée

**Contrainte** : tout ça se fait côté utilisateur (WSL/Docker local pour Fleetbase), pas dans le sandbox Claude Code. Navigator compile/s'exécute sur simulateur iOS/Android ou sur device physique.

---

## Prérequis absolus

Ces prérequis sont demandés officiellement par le README de Navigator (`fleetbase/navigator-app`). À vérifier/installer avant de commencer :

- **Node.js** v16+ (vérifier : `node --version`)
- **Yarn** ou **npm** (vérifier : `yarn --version` ou `npm --version`)
- **React Native CLI** (`npm install -g react-native-cli`)
- **Xcode 12+** (pour iOS ; `xcode-select --install` pour les outils de ligne de commande seuls) OU **Android Studio + SDK** (pour Android)
- **Mapbox API key** (gratuit, à créer sur https://account.mapbox.com/)
- **Google Maps API key** (gratuit, créer sur Google Cloud Console et activer "Maps SDK for Android/iOS")
- **Fleetbase API key** pour l'Organization "Echango Delivery" (à récupérer depuis la console Fleetbase locale, voir §1.2 ci-dessous)

---

## 1. Récupérer la clé API Fleetbase

Navigator a besoin d'UNE clé API Fleetbase — une seule par build, une seule Organization possible par installation.

### 1.1 Accès à la console Fleetbase locale

- URL : **`http://localhost:4200`** (défaut)
- Login avec l'admin account créé lors de l'installation (`scripts/setup-local.sh`)

### 1.2 Récupérer la clé API

**Dans la console Fleetbase local** (une fois connecté en tant qu'admin) :

1. Navigue vers **Developers** (onglet en haut à droite)
2. Clique sur **API Keys**
3. Cherche la clé d'accès correspondant à l'Organization **"Echango Delivery"**
   - Sinon, clique sur **+ Create API Key**
   - Scénario normal : une seule Organization, une seule clé par Admin, déjà créée
4. **Copie la valeur** de la clé (une longue chaîne, ex. `flb_...`)
5. Sauvegarde-la en sécurité (partage-la avec Claude via la conversation, jamais sur un dépôt public)

---

## 2. Cloner et installer Navigator

### 2.1 Clone du repo

```bash
git clone https://github.com/fleetbase/navigator-app.git
cd navigator-app
```

### 2.2 Installation des dépendances

```bash
yarn install
# ou npm install si tu préfères npm
```

### 2.3 Configuration — clé API Fleetbase

Cherche le fichier de configuration (probablement `app.json` ou `.env.example` ou un fichier de config spécifique à Navigator).

**Commande pour localiser les fichiers de config** :
```bash
find . -maxdepth 2 -name "*.json" -o -name ".env*" -o -name "*config*" | grep -v node_modules
```

Une fois localisé, **ajoute/modifie** la clé API avec celle du §1.2 :
```
FLEETBASE_API_KEY=<la clé copiée>
```

**Alternative possible** (à vérifier dans le README exact de Navigator) : injection lors du build ou du start, via une variable d'environnement.

### 2.4 Configuration — clés Mapbox et Google Maps

Cherche les fichiers contenant `MAPBOX` ou `GOOGLE_MAPS` (probablement `app.json`, `.env`, ou un dossier `config/`).

Ajoute tes clés :
```
MAPBOX_API_KEY=<ton mapbox key>
GOOGLE_MAPS_API_KEY=<ta google maps key>
```

---

## 3. Construire et lancer l'app

### 3.1 Pour iOS (simulateur)

```bash
npx react-native run-ios
```

Cela va :
- Builder le projet Xcode
- Lancer le simulateur iOS par défaut
- Installer et lancer l'app

**La première fois, c'est lent (~3-5 min).** Sois patient.

### 3.2 Pour Android (simulateur)

```bash
npx react-native run-android
```

Prérequis supplémentaires :
- Un device/émulateur Android en cours d'exécution (`adb devices` pour vérifier)
- Android SDK configuré

### 3.3 Démarrer le Metro bundler (si tu lances l'app manuellement)

Dans un terminal séparé (reste actif lors du dev) :
```bash
npx react-native start
```

---

## 4. Tester la connexion d'un driver

### 4.1 Identifiants du driver "Toto"

Selon `docs/journal_exploration_fleetbase.md` §7.5 et `docs/specs_echango_delivery.md`, un driver de test "Toto" a été créé manuellement lors des tests.

**Avant de lancer le test : vérifier que ce driver a des identifiants de connexion** (impossible de se connecter sans email/mot de passe valides).

### 4.1.1 Vérifier/créer les identifiants du driver via la console Fleetbase

1. **Console Fleetbase** : `http://localhost:4200` → Fleet-Ops → Drivers
2. Cherche le driver **"Toto"**
3. Clique sur son profil
4. Vérifie qu'il a un **email** (ex. `toto@echango.local`) et une **adresse email vérifiée**
5. **Si le mot de passe n'est pas défini**, il faut le créer via `tinker` (Laravel REPL) :

```bash
# Accès au conteneur de l'application Fleetbase (côté utilisateur, depuis là où tourne docker-compose)
docker compose exec -T application php artisan tinker

# À l'intérieur de tinker :
$driver = \Fleetbase\FleetOps\Models\Driver::where('name', 'Toto')->first();
$driver->user->forceFill(['password' => 'test1234'])->save();
# (Remplace 'test1234' par un mot de passe réel ; Fleetbase hashera automatiquement via le mutator)
exit()
```

### 4.2 Lancer l'app Navigator et se connecter

1. L'app Navigator s'ouvre sur un écran de **login**
2. **Email** : `toto@echango.local` (ou l'email du driver, quel qu'il soit)
3. **Password** : le mot de passe défini en 4.1.1
4. Clique sur **Login**

**Résultat attendu** : l'app affiche un tableau de bord du driver (liste de commandes assignées, carte avec position, etc.)

**Si ça ne marche pas** : consulte les logs Fleetbase ou la console de l'app (DevTools React Native) pour voir le message d'erreur exact.

---

## 5. Tester la réception d'une commande adhoc

C'est le test le plus important : valider que la boucle complète (création de commande → dispatch adhoc → notification au driver → affichage dans Navigator) fonctionne réellement.

### 5.1 Préparer le driver "Toto" en ligne

**Dans la console Fleetbase** :

1. **Fleet-Ops** → **Drivers**
2. Clique sur le driver "Toto"
3. Cherche le flag/switch **`Online`** ou **`Status`**
4. Mets-le à **`Online`** (ou l'équivalent actif, selon la version)
5. **Géolocalisation** : assure-toi que le driver a une `location` (coordonnées GPS) définie
   - Test/debug : cherche la colonne `location` dans la table `drivers` (doit être un JSON avec lat/lon, pas null)
   - Si null, il faut la définir manuellement : tinker, `$driver->location = ['lat' => 48.8566, 'lng' => 2.3522]; $driver->save();` (exemple : Paris)

### 5.2 Création d'une commande adhoc

**Dans la console Fleetbase** :

1. **Fleet-Ops** → **Orders** (ou "Ordres")
2. Clique sur **+ Create Order** (ou l'équivalent)
3. Remplis le formulaire de base :
   - **Pickup** (prise en charge) : sélectionne ou crée une Place (adresse) — ex. "Bureau Echango" (ou n'importe quelle adresse)
   - **Dropoff** (dépose) : une autre Place — ex. "Client Test"
   - **Facilitator** (responsable) : peut être un Vendor ou vide, pas critique pour ce test
4. **Les points clés du test adhoc** :
   - **Dispatcher Type** ou **Assignment** : **laisse vide** ou cherche un toggle "Adhoc"
   - **Status** : créé en tant que "created", pas encore dispatched
5. Clique sur **Create Order**

### 5.3 Dispatcher la commande (adhoc)

Une fois créée, la commande apparaît dans la liste.

1. Clique sur la commande pour l'ouvrir
2. **Cherche un bouton "Dispatch"** ou **"Send Order"** ou une action bulk "Dispatch Orders"
3. Déclenche le dispatch
   - Regardes les logs Fleetbase (`docker compose logs queue` ou `docker compose logs application`) pour voir si des erreurs apparaissent
   - Attends quelques secondes (la queue traite le dispatch)

### 5.4 Vérifier que Navigator reçoit la notification

**C'est LE test crucial** : si tu es connecté dans Navigator en tant que "Toto" (driver) ET que tu es en ligne, **la commande doit apparaître dans l'app**.

**Checklist du test** :
- [ ] Navigator est ouvert, "Toto" connecté, statut "Online" dans l'app
- [ ] Commande adhoc créée et dispatchée depuis la console (§5.2-5.3)
- [ ] **La commande apparaît instantanément dans la liste "Pending Orders" ou "New Orders" de Navigator**
- [ ] Une **notification sonore/visuelle** a-t-elle été reçue par le simulateur/device ? (À vérifier dans les logs de l'app, notifications système du device, etc.)

**Si ça fonctionne** : 🎉 Question ouverte #3 partiellement fermée — Navigator peut bien recevoir des commandes adhoc.

**Si ça ne fonctionne pas** :
- Consulte les logs Fleetbase : `docker compose logs application -f` et `docker compose logs queue -f` pour vérifier que le dispatch s'est déclenché sans erreur
- Vérifie que le driver a vraiment une `location` non-null (§5.1)
- Affiche les logs de l'app Navigator (console React Native DevTools) pour vérifier que l'app essaie de se connecter au WebSocket/FCM/APN de Fleetbase

---

## 6. Tester l'assignation ciblée d'un driver

Complément du test adhoc : confirmer que Navigator reçoit correctement une assignation ciblée (pas juste du broadcast).

### 6.1 Créer une commande avec assignation ciblée

**Dans la console Fleetbase** :

1. **Fleet-Ops** → **+ Create Order**
2. Remplis le formulaire (pickup/dropoff) comme en §5.2
3. **Cherche le champ "Assign Driver"** ou **"Driver"** et **assigne "Toto" directement**
4. Crée la commande (elle devrait être en statut "created" + `driver_assigned_uuid = <uuid de Toto>`)

### 6.2 Vérifier que Navigator le reçoit

**Checklist** :
- [ ] Navigator affiche la commande **dans l'app** (même si "Toto" n'était pas filtré par le broadcast adhoc, l'assignation ciblée doit la rendre visible)
- [ ] La commande est marquée comme "assignée à moi" ou "Assigned", pas juste "potential"

**Résultat attendu** : la commande doit apparaître avec un statut clair qui indique que c'est pour ce driver spécifiquement.

---

## 7. Rebrand de Navigator (nom, logo, couleurs)

Navigator est configuré pour être rebranding-friendly (app officielle Fleetbase, pas un fork personnalisé).

### 7.1 Où trouver les fichiers de branding

Cherche dans l'arborescence :
- **`app.json`** (config générale React Native, souvent le `name`, `displayName` de l'app)
- **`assets/` ou `src/assets/`** (images du logo, icônes)
- **`src/styles/` ou `theme/`** (couleurs, variables de style)
- **`ios/` et `android/`** (config iOS/Android spécifique : app name, icon, splash screen)

### 7.2 Changements simples (identifiés comme non-bloquants)

1. **Nom de l'app** (`displayName` dans `app.json`):
   ```json
   "displayName": "Echango Delivery"
   ```

2. **Logo/Icon** :
   - Remplace les fichiers PNG/assets du logo par ceux d'Echango (résolutions : 1024x1024 minimum pour iOS, 192x192 pour Android selon les standard)
   - Voir la doc React Native Native : https://reactnative.dev/docs/images

3. **Couleurs principales** :
   - Cherche les fichiers de style/thème
   - Remplace les couleurs Fleetbase par celles d'Echango
   - Test : relance le build (`npm run ios` / `npm run android`)

**Important** : après changement du logo/icône ou du nom, il faut **rebuilder** l'app — le bundle JavaScript seul ne suffit pas pour ces changements natifs.

### 7.3 Estimation de complexité

**Prédiction** : changements simples, <30 min de travail (logo + nom + 2-3 couleurs principales). Validé par observation du repo `fleetbase/navigator-app` — c'est une app officielle moderne, pas un legacy spaghetti. Si le rebrand prend beaucoup plus longtemps (>1h), c'est probablement un signal que Navigator n'est pas adaptable comme prévu.

---

## 8. Checklist de validation — à remplir au fur et à mesure

Tiens-nous au courant des résultats avec cette checklist :

### Installation et lancement
- [ ] Prérequis installés (Node, Yarn, React Native CLI, Xcode/Android Studio)
- [ ] Clé API Fleetbase récupérée
- [ ] Navigator cloné et `yarn install` sans erreur
- [ ] Build iOS/Android réussi
- [ ] App lance sans crash

### Connexion driver
- [ ] Driver "Toto" a des identifiants de connexion valides (email/password)
- [ ] Navigator : login "Toto" réussi
- [ ] L'app affiche le dashboard du driver

### Test adhoc
- [ ] Commande adhoc créée (console Fleetbase)
- [ ] Dispatch déclenché sans erreur (logs Fleetbase)
- [ ] **Navigator reçoit la commande en temps réel** ← le test critique
- [ ] Notification reçue par l'app (audio/visuelle)

### Test assignation ciblée
- [ ] Commande créée avec "Toto" assigné directement
- [ ] Navigator reçoit la commande et la marque "assignée à moi"

### Rebrand
- [ ] Nom changé en "Echango Delivery"
- [ ] Logo remplacé
- [ ] Couleurs adaptées (au moins la couleur principale)
- [ ] Rebuild sans erreur
- [ ] App relancée, rebrand visible

---

## Prochaines étapes (une fois ce guide exécuté)

Une fois que tu as testé tout ce qui précède, partage les résultats + captures d'écran dans la conversation. Je documenterai les découvertes dans :
- **CLAUDE.md** (question ouverte #3 « Navigator adaptable ? »)
- **docs/specs_echango_delivery.md** (mise à jour de la section "Prochaines étapes" avec la validation Navigator)

Si tout fonctionne, on peut envisager de commencer le développement des deux interfaces custom (commerçant + petite flotte) en Flutter.

Si des problèmes sérieux apparaissent (Navigator ne reçoit pas les notifications, rebrand impossible, crash à la connexion...), on documentera ça comme une vraie limite à contourner.

---

**Appelle quand tu as des résultats — on itérera sur chaque découverte au fur et à mesure.**
