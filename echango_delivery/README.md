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
  sans. Conséquence : pas de notification, rafraîchissement manuel.

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

**Limite connue** : la capture photo n'est pas branchée. Les étapes marquées
`require_pod` partent sans preuve — le serveur les accepte, la preuve manque au
dossier.

Le parcours de connexion par téléphone/OTP a été **retiré** : ses endpoints
n'existent pas côté BFF, l'écran ne pouvait qu'échouer. Il reste au périmètre
spec (`docs/specs_app_transporteur.md` §2), à réintroduire avec son serveur.
