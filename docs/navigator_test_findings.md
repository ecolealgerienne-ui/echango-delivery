# Navigator Test Findings — 27 juillet 2026

**Session** : Test d'installation et compilation de Fleetbase Navigator (React Native)  
**Objectif** : Valider la question ouverte #3 du CLAUDE.md — Navigator est-il vraiment adaptable ?  
**Résultat** : ❌ **BLOQUANT** — obstacles sérieux découverts, Navigator n'est pas prêt pour MVP sans fork/maintenance lourde

---

## Résumé exécutif

| Critère | Résultat | Impact |
|---------|----------|--------|
| Installation | ❌ Erreurs de dépendance multiples | Bloquant |
| Compilation (Android) | ❌ Codegen failure systématique | Bloquant |
| Compilation (branche legacy) | ❌ Même erreur codegen | Structural |
| Crash au startup | ❌ Hermes engine error documenté | Bloquant |
| Documentation | ⚠️ Incomplète (tokens manquants) | Sérieux |
| Support/maintenance | ⚠️ 9 issues actives, pas de pattern clair | Risque |

---

## Obstacles identifiés

### 1. Erreur de dépendance React Native

**Symptôme initial**
```
npm error code ERESOLVE
npm error ERESOLVE unable to resolve dependency tree
npm error Found: react@19.2.7
npm error Could not resolve dependency: peer react@"^17 || ^18" from react-native-fast-image@8.6.3
```

**Contexte** : Navigator utilise React Native 0.86.0 (beta, très récent) qui requiert React 19, mais la majorité des dépendances veulent React 18.

**Workaround tenté** : Downgrade React Native vers 0.76.0 (LTS) — partiellement efficace, mais découvert ensuite que c'est symptomatique d'un problème plus profond.

---

### 2. Erreur de codegen (BLOQUANT)

**Symptôme**
```
Error: Unsupported type for param "type". Found: UnionTypeAnnotation
    at translatePrimitiveJSTypeToCpp (GenerateModuleH.js:242:17)
```

**Contexte** : La tâche Gradle `:react-native-camera-roll_camera-roll:generateCodegenArtifactsFromSchema` échoue. Le générateur de code de React Native n'a pas de support natif pour les `UnionTypeAnnotation` utilisées par `react-native-camera-roll`.

**Reproductibilité** :
- ✅ Reproduit sur branche principale (React Native 0.86)
- ✅ Reproduit sur branche legacy (React Native 0.76 après downgrade)
- ✅ Implique que le problème est **structural au projet**, pas local à l'env utilisateur

**Solutions tentées** :
- ❌ `npm install --legacy-peer-deps` : Installe les dépendances mais le build échoue quand même
- ❌ Downgrade React Native : Même erreur sur branche legacy
- ❌ Nettoyage node_modules complet : Même erreur

---

### 3. Crash au startup (documenté sur d'autres OS)

**Recherche GitHub** : Issue #101 du repo Navigator
- **OS testé** : Arch Linux (pas juste Windows)
- **React Native** : 0.78.0
- **Erreur** : Crash immédiat avec Hermes engine error, même après build réussi
- **Excerpt de l'issue** :
  ```
  After following the installation guide and building the app successfully, 
  it crashes immediately on startup with a Hermes engine error.
  
  These were not mentioned in the installation guide but are required:
  - TRANSISTORSOFT_LICENSE_KEY=temp-dev-key
  - FACEBOOK_APP_ID=123456789
  - FACEBOOK_CLIENT_TOKEN=temp-token
  ```

**Implication** : Même si on résolvait l'erreur codegen, le crash au startup reste un problème connu et non résolu.

---

### 4. Documentation incomplète

**Découvert lors du test** :
- Les tokens `TRANSISTORSOFT_LICENSE_KEY`, `FACEBOOK_APP_ID`, `FACEBOOK_CLIENT_TOKEN` ne sont pas documentés dans le README officiel
- Nécessaires pour fonctionner (issue #101)
- Utilisateurs doivent trouver ces secrets par essais/erreurs ou dans les issues GitHub

---

### 5. Support/maintenance incertain

**Résultats de recherche GitHub** : 9 issues actives liées à codegen/camera-roll/Android

**Pattern observé** :
- Issues ouvertes (2025-07-27), pas une résolution claire en vue
- Workarounds suggérés par les utilisateurs plutôt que des fixes officiels
- Documentation n'a pas été mise à jour pour refléter les problèmes connus

---

## Chronologie du test

| Étape | Commande | Résultat | Durée |
|-------|----------|----------|-------|
| 1. Installation npm | `npm install` | ❌ Conflit React 19/18 | 2 min |
| 2. Downgrade React 18 | `npm install react@18` | ⚠️ Installe mais build échoue | 5 min |
| 3. Build Android (main) | `npx react-native run-android` | ❌ Codegen error | 13 min |
| 4. Downgrade RN 0.76 | `npm install react-native@0.76` | ⚠️ Dépendances cassées | 3 min |
| 5. Clean + reinstall | `rm -r node_modules && npm install` | ⚠️ Même problèmes | 5 min |
| 6. Build legacy branch | `cd legacy && npx react-native run-android` | ❌ Codegen error | 10 min |
| 7. Research GitHub | Issues, docs, patterns | ⚠️ 9 issues actifs, crash documenté | 2 min |
| **TOTAL** | | | ~40 min |

---

## Questions soulevées

1. **Est-ce que Navigator fonctionne réellement sur Windows/Android ?**
   - Réponse : Pas clairement. Les obstacles codegen/crash/docs incomplète suggèrent que c'est un chemin peu testé/maintenu.

2. **Est-ce que c'est un problème local ou systémique ?**
   - Réponse : **Systémique**. Même erreur sur branche legacy + issue #101 sur autre OS (Arch Linux) = c'est du projet, pas du setup utilisateur.

3. **Peut-on y remédier avec des patches/forks ?**
   - Réponse : Techniquement oui, mais : forker Navigator = maintenance longue terme, synchronisation avec upstream difficile (versions divergent rapidement). Coût non justifié pour un MVP.

4. **Pourquoi la documentation ne mentionne pas ces problèmes ?**
   - Réponse : Probablement parce que Navigator est surtout testé/utilisé sur iOS (Xcode sur Mac), moins sur Android/Windows. Documentation reflète l'usage principal, pas les cas d'usage alternatifs.

---

## Recommandations

### Option A — **Construire une app transporteur custom en Flutter** (recommandé)

**Avantages** :
- ✅ Contrôle complet sur le code et les dépendances
- ✅ Stack cohérent avec Echango Order (déjà Flutter pour préparateur)
- ✅ Maintenance claire et maîtrisée
- ✅ Pas de dépendance à Navigator/Fleetbase instable

**Inconvénients** :
- ❌ Effort de développement supplémentaire (~2-3 semaines estimé pour v1)
- ❌ Refaire certaines briques : géolocalisation, notifications push, UI

**Estimation** : ~10-15 jours dev pour MVP (écran login + liste commandes + position map + actions basiques)

---

### Option B — **Forker + patcher Navigator**

**Avantages** :
- ✅ Réutilise du code officiel Fleetbase
- ✅ Certaines briques déjà faites (géolocalisation, notifications)

**Inconvénients** :
- ❌ Maintenance à long terme = coût de synchronisation avec upstream
- ❌ Navigator très actif en version (0.86 beta) = breaking changes fréquentes
- ❌ Patches persistants sur les mêmes problèmes codegen/crash
- ❌ Risque d'un projet "deux vitesses" (fork diverge, upstream trop instable)

**Estimation** : 1-2 jours patch initial + ~2 jours/mois de maintenance

---

### Option C — **Utiliser console Fleetbase pour les transporteurs**

**Avantages** :
- ✅ Zéro dev supplémentaire

**Inconvénients** :
- ❌ Console Fleetbase trop complexe (même analyse qu'on a faite pour commerçants au mois dernier)
- ❌ Pas conçue pour des utilisateurs mobiles
- ❌ Déjà rejeté par le projet pour les commerçants pour exactement cette raison

---

## Décision recommandée

**Option A — Flutter custom** est la meilleure option pour Echango Delivery :
1. Cohérence avec le stack existant (Echango Order)
2. Maintenance claire et maîtrisée
3. Adaptabilité/rebranding facile (déjà une app custom)
4. Pas de dépendance à un tiers en instabilité

**Action** :
- Valider cette recommandation auprès de l'équipe produit
- Planifier le développement de l'app transporteur Flutter
- Réutiliser des patterns de géolocalisation/notifications depuis Echango Order si possible

---

## Prochaines étapes

- [x] Tester Navigator (27/07/2026)
- [ ] Décider entre Option A/B/C
- [ ] Planifier développement app transporteur Flutter (Option A)
- [ ] Ou : fork + plan de maintenance (Option B)
- [ ] Mettre à jour CLAUDE.md avec la décision finale
