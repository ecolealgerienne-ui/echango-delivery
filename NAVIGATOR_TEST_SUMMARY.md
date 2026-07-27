# Navigator Test Session — 27 juillet 2026

**Objectif** : Fermer la question ouverte #3 du CLAUDE.md — **Navigator est-il réellement adaptable et fonctionnel pour Echango ?**

---

## Pourquoi ce test maintenant ?

- **Architecture retenue (27/07/2026)** : utiliser Navigator (app officielle Fleetbase, React Native) plutôt que de développer une app transporteur custom
- **Jamais testé en pratique** — c'est la dernière vraie inconnue technique avant de démarrer le développement des deux interfaces custom (commerçant + petite flotte)
- **Validation prioritaire** : que Navigator fonctionne réellement avec l'Organization Fleetbase locale, que le rebrand soit simple, et que les notifications soient bien reçues (dispatch adhoc + assignation ciblée)

---

## À faire côté utilisateur (toi)

**Document complet** : `docs/setup_navigator_test.md`

**Résumé rapide des étapes** :

1. **Installer les prérequis** (une fois) :
   - Node.js v16+, Yarn, React Native CLI, Xcode 12+ ou Android Studio
   - Clés API : Mapbox, Google Maps

2. **Récupérer la clé API Fleetbase** :
   - Accède à `http://localhost:4200` (console Fleetbase local)
   - Va dans **Developers → API Keys**
   - Copie la clé pour l'Organization "Echango Delivery"

3. **Cloner, installer et configurer Navigator** :
   ```bash
   git clone https://github.com/fleetbase/navigator-app.git && cd navigator-app
   yarn install
   # Ajoute la clé API Fleetbase + Mapbox + Google Maps dans la config (app.json ou .env)
   ```

4. **Builder et lancer** (iOS ou Android) :
   ```bash
   npx react-native run-ios   # ou run-android
   ```

5. **Tests précis à faire** :
   - [ ] Navigator s'ouvre sans crash
   - [ ] Connexion du driver "Toto" réussie
   - [ ] **Commande adhoc créée → Navigator la reçoit en temps réel** (le test critique)
   - [ ] Assignation ciblée : pareil
   - [ ] Rebrand simple : nom + logo + couleur principale

6. **Partage les résultats** :
   - Capture d'écran de Navigator (écran de login, dashboard, commande reçue)
   - Logs d'erreur si problème
   - Temps total du setup/test
   - Avis : trop compliqué ? Trop simple ? Surprises ?

---

## Ce que Claude fera côté repo

Une fois tes résultats :
- Documenter les découvertes dans `docs/`
- Mettre à jour **CLAUDE.md** (fermer question ouverte #3)
- Préparer les prochaines étapes (début du développement Flutter pour les interfaces custom)

---

## Questions clés à trancher

1. **Installation et compilation** : réussit sans erreur ?
2. **Connexion driver** : login fonctionne ?
3. **Dispatch adhoc** : Navigator reçoit la notification **en temps réel** ? (le test définitif)
4. **Rebrand** : changé en 30 min ou plus compliqué que prévu ?
5. **Stabilité** : l'app crash, reste stable, acceptable pour un MVP ?

---

**Commande : lance le guide du §2 (`docs/setup_navigator_test.md`), teste étape par étape, et partage les résultats ici. On itère sur chaque découverte.**
