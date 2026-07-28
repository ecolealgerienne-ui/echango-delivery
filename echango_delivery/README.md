# Echango Delivery — application

Application Flutter unique servant les trois profils de la plateforme :
**transporteur**, **commerçant**, et plus tard **gestionnaire de flotte**.

## Pourquoi une seule app (décision 28/07/2026)

C'est un seul produit : un commerçant et un transporteur participent à la même
livraison. Deux applications distinctes découpaient artificiellement ce que
l'utilisateur perçoit comme un tout, et dupliquaient tout le socle — client
HTTP, authentification, thème, modèles.

**Le profil n'est pas demandé à la connexion** : `POST /auth/login` le résout
depuis l'email, seul le serveur sachant dans quelle table le compte existe. Le
`type` renvoyé fait autorité pour la navigation.

**Coût assumé** : les permissions Android du profil transporteur
(géolocalisation en tâche de fond, service au premier plan, notifications) sont
déclarées pour tout le monde, y compris un commerçant qui ne fera jamais de
livraison. Elles ne sont *demandées* qu'à l'usage, mais apparaîtront sur une
fiche Play Store. Le découpage `screens/transporteur/` et `screens/commercant/`
existe pour que la séparation en deux binaires reste peu coûteuse si cette
contrainte devenait bloquante.

## Structure

```
lib/
├── config/          # api_config, dev_accounts, firebase_options
├── errors/          # codes d'erreur et AppException
├── models/          # order.dart (transporteur), merchant_order.dart
├── services/        # bff_api_client (3 profils), notification, location
├── state/           # auth_state (rôle), order_state, merchant_order_state
├── navigation/      # routeur, redirections par rôle
├── screens/
│   ├── auth/        # connexion, inscription commerçant
│   ├── transporteur/
│   └── commercant/
└── main.dart
```

## Premier lancement

Le dépôt ne contient que `lib/` — le scaffolding de plateforme se génère :

```bash
cd echango_delivery
flutter create . --platforms=android --org com.echango
flutter pub get
flutter analyze
flutter run
```

- **Adresse du BFF** : `10.0.2.2:3001` par défaut (émulateur Android).
  Surcharge : `flutter run --dart-define=BFF_BASE_URL=http://192.168.1.20:3001`
- **HTTP en clair** : ajouter `android:usesCleartextTraffic="true"` sur la
  balise `<application>` du manifeste. À retirer avant distribution.
- **Firebase est optionnel** : l'initialisation est encadrée, l'app démarre
  sans. Conséquence : pas de notification, rafraîchissement par interrogation
  périodique du BFF à la place.

### Permissions Android — obligatoire pour le profil transporteur

`android/` est régénéré par `flutter create` et **n'est pas versionné** : ces
lignes sont à remettre après chaque régénération, au-dessus de `<application>`
dans `android/app/src/main/AndroidManifest.xml`.

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<!-- Suivi de position écran éteint : le service au premier plan maintient le
     processus vivant. Sans le `foregroundServiceType`, Android 14+ refuse de
     démarrer le service et le suivi s'arrête à la première mise en veille. -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
<uses-permission android:name="android.permission.WAKE_LOCK" />
```

et, à l'intérieur de `<application>` :

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="location"
    android:exported="false" />
```

Sans les permissions de localisation, `Geolocator.requestPermission()` échoue
**sans dialogue** : la bascule « en ligne » refuse de s'activer et affiche le
message d'autorisation, ce qui ressemble à un refus de l'utilisateur alors que
le système n'a jamais posé la question.

**Limite restante** : `ACCESS_BACKGROUND_LOCATION` n'est pas demandée. Le
service au premier plan couvre le cas courant — app en arrière plan, écran
éteint — mais pas un suivi après fermeture complète de l'application. C'est
volontaire : cette permission déclenche un examen manuel sur le Play Store, et
un transporteur qui ferme l'app a de bonnes raisons d'être considéré hors
service.

**Optimisations constructeur** : Xiaomi, Huawei et Samsung coupent les services
au bout de quelques minutes malgré tout. L'app demande l'exemption
(`requestIgnoreBatteryOptimization`), mais son refus ne bloque pas — à vérifier
sur les appareils réels du pilote.

**Comptes de test** (debug uniquement, jamais versionnés). Le `role` ne sert
qu'à l'icône du raccourci — c'est le serveur qui résout le profil :

```bash
flutter run --dart-define=DEV_ACCOUNTS='[
  {"label":"Transporteur","email":"driver-test-10000@echango.local","password":"motdepasse123"},
  {"label":"Boulangerie","email":"commercant-test-15880@echango.local","password":"motdepasse123","role":"merchant"}
]'
```

## État

| Profil | Serveur | Client |
|---|---|---|
| Transporteur | ✅ validé en réel | ✅ validé en usage réel |
| Commerçant | ✅ validé en réel | ⚠️ jamais exécuté |
| Gestionnaire de flotte | partiel | ❌ non commencé |

## Capture photo

Branchée sur les deux besoins (`widgets/photo_field.dart`, partagé pour que les
deux écrans ne divergent pas) :

- **Preuve de livraison** — une étape que le serveur marque `require_pod`
  ouvre une feuille de capture, et n'est appliquée qu'après envoi réussi de la
  photo. Refuser la capture annule l'étape : envoyer sans preuve
  contournerait la règle que le serveur vient d'énoncer.
- **Échec de livraison** — photo facultative. L'imposer pousserait à
  photographier n'importe quoi pour débloquer l'écran, alors qu'un
  destinataire absent n'a rien à montrer.

Redimensionnement et compression sont faits côté natif par `image_picker`
(1600 px, qualité 70). La limite du serveur est vérifiée **avant** l'envoi :
au-delà, la requête partirait pour revenir en 400 après avoir consommé la
connexion mobile du transporteur.

`image_picker` délègue à l'appareil photo du système par intent, donc aucune
permission `CAMERA` n'est nécessaire par défaut. Attention toutefois : si un
autre plugin déclare `CAMERA` dans le manifeste, Android exige alors la
demande à l'exécution — l'ajout d'une dépendance peut donc casser la capture
sans qu'on touche à ce code.

## Présence du transporteur

Trois mécanismes qui n'ont de sens que combinés, regroupés dans
`state/driver_presence_state.dart` :

| | Rôle | Sans lui |
|---|---|---|
| Bascule en ligne | déclare le driver disponible dans Fleetbase | aucune course ne lui est diffusée |
| Suivi de position | alimente le dispatch géospatial | en ligne mais invisible : le dispatch choisit par proximité |
| Push + interrogation | rafraîchit la liste des courses | la course arrive, l'écran ne bouge pas |

La présence suit la **session**, pas un écran : elle démarre après connexion ou
restauration de session, et s'arrête à la déconnexion — y compris si le driver
n'a jamais ouvert le tableau de bord. Le passage hors ligne a lieu **avant**
l'invalidation du jeton (`AuthState.onBeforeLogout`), sans quoi l'appel partirait
sans authentification et le driver resterait éligible à des courses.

Le push est un **déclencheur**, jamais une source de données : son contenu n'est
pas affiché, il provoque une relecture auprès du BFF. L'interrogation périodique
(45 s, au premier plan et en ligne uniquement) couvre les cas où il n'arrive
pas — Firebase non configuré, permission refusée, message perdu.

Le parcours de connexion par téléphone/OTP a été **retiré** : ses endpoints
n'existent pas côté BFF, l'écran ne pouvait qu'échouer. Il reste au périmètre
spec (`docs/specs_app_transporteur.md` §2), à réintroduire avec son serveur.
