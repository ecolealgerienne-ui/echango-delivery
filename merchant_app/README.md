# Echango Commerçant

Application Flutter destinée aux commerçants (boulangerie, pharmacie,
fleuriste…) pour demander un transporteur et suivre leurs livraisons.

C'est la deuxième des trois interfaces prévues (`CLAUDE.md` § Architecture),
après l'app transporteur `driver_app/`.

## État au 28/07/2026

| Fonctionnalité | Serveur | Client |
|---|---|---|
| Inscription / connexion commerçant | ✅ validé en réel | ✅ écrit |
| Création d'une demande de livraison | ✅ validé en réel | ✅ écrit |
| Liste et détail des livraisons | ✅ validé en réel | ✅ écrit |
| Suivi | ✅ endpoint existant | ✅ écrit |
| Annulation | ✅ endpoint existant | ✅ écrit |
| Carnet d'adresses | ✅ validé en réel | ✅ écrit |

Le serveur est couvert par `scripts/test-commercant-module.sh` (à la racine du
repo), qui sert aussi à remplir la base de commandes réelles.

**Le client n'a jamais été compilé ni exécuté** — écrit sans toolchain Flutter
disponible. `flutter analyze` est le premier vrai test.

## Décisions de périmètre (28/07/2026)

- **Application mobile d'abord**, web ensuite. Le code Flutter reste portable :
  aucune dépendance native n'a été introduite (ni géolocalisation, ni push, ni
  carte), ce qui garde la cible web ouverte sans réécriture.
- **Adresses saisies en texte**, avec carnet d'adresses réutilisable. La
  sélection sur carte viendra plus tard. Conséquence assumée : les coordonnées
  proviennent d'une adresse enregistrée ou d'un repli au centre-ville, jamais
  d'un géocodage. Suffisant pour un dispatch géospatial approximatif, à
  reprendre avec la carte.

## Premier lancement

Le projet ne contient que `lib/` — aucun dossier `android/`, comme
`driver_app/` à sa création.

```bash
cd merchant_app
flutter create . --platforms=android --org com.echango
flutter pub get
flutter analyze
flutter run
```

Puis, comme pour `driver_app` :

- **Adresse du BFF** : `10.0.2.2:3001` par défaut (émulateur Android).
  Surcharge : `flutter run --dart-define=BFF_BASE_URL=http://192.168.1.20:3001`
- **HTTP en clair** : ajouter `android:usesCleartextTraffic="true"` sur la
  balise `<application>` du manifeste. À retirer avant distribution.

**Comptes de test** (debug uniquement, jamais versionnés) :

```bash
flutter run --dart-define=DEV_ACCOUNTS='[{"label":"Boulangerie","email":"<email>","password":"motdepasse123"}]'
```

L'email utilisé est créé par `./scripts/test-commercant-module.sh`, qui
l'affiche en fin d'exécution.

## Ce que le commerçant ne voit pas

Une demande créée **n'est pas dispatchée automatiquement** : un opérateur
Echango la diffuse depuis la console Fleetbase. L'écran de création le dit
explicitement, sinon l'absence de transporteur passerait pour une panne.

C'est une règle métier, pas une limite technique — si le dispatch automatique
est souhaité, il se décide côté produit (`docs/specs_echango_delivery.md` §6).
