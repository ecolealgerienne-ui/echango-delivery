# Synthèse croisée — revue du 28/07/2026

Trois rapports indépendants (architecture, sécurité, métier — voir README.md).
Cette synthèse classe par convergence : un constat trouvé par plusieurs agents
par des chemins indépendants est plus fiable qu'un constat isolé.

## Constats convergents (2 à 3 rapports, chemins indépendants)

1. **Secret JWT par défaut, en trois exemplaires** (archi #1, sécu C1). Trois
   valeurs de repli différentes selon le fichier ; celle du docker-compose est
   versionnée. Sans `JWT_SECRET` posé sur le VPS : forgeage de jeton trivial,
   toute l'isolation tombe. En prime, signature et vérification utilisent des
   `JwtService` différents — sans la variable, 100 % des requêtes partent en 401.

2. **Les chaînes app ne sont branchées nulle part** (métier #1, archi #6/#7/#8).
   Toggle en ligne, suivi GPS de fond, enregistrement du jeton FCM, capture
   photo : tout est validé côté serveur, rien n'est appelé par l'UI. Les tests
   passaient parce que les *scripts* faisaient le travail de l'app. Un vrai
   livreur n'apparaîtrait jamais disponible — pilote impossible tel quel.

3. **Plafond silencieux à 100 commandes** (archi #2, note sécu). `getAllOrders()`
   est appelé sans pagination par `resolveOrder`, `listOrders` (transporteur) et
   `mergeWithFleetbase` (commerçant). À la 101e commande de l'organisation :
   404 sur des commandes légitimement assignées, commandes marquées `missing`.
   Casse le produit la première semaine, pas dans un an. Ironie : seul le module
   `flotte` pagine correctement.

4. **Pas de limitation de débit sur /auth** (archi #12, sécu E5), aggravé par le
   triple bcrypt de `loginUnified` (amplificateur CPU).

5. **Photos base64 : cassées ET non bornées** (archi #4, sécu M11). La limite
   Express par défaut (100 ko) rejette toute vraie photo de téléphone — le test
   au vert utilisait un PNG 1×1 et ne pouvait pas le voir. Et le jour où on
   relève la limite, rien ne borne la charge. Les deux bornes doivent être
   posées ensemble.

6. **Garde de rôle absent du module commerçant** (archi #10, sécu E4). Seul des
   trois contrôleurs à ne pas vérifier `req.user.type`. Protégé aujourd'hui par
   la non-collision des cuid — une propriété du schéma, pas un contrôle.

7. **Annulation : trois défauts empilés** (archi #3, archi #15, métier #4).
   (a) `cancelOrder`/`getOrderTracking` cherchent le cuid local alors que l'app
   envoie l'uuid Fleetbase → 404 systématique, le suivi échoue *silencieusement* ;
   (b) une fois (a) corrigé, le garde de transition lit `Order.status` local figé
   à 'pending' → une commande terminée passerait le garde ; (c) aucun garde-fou
   métier ni notification au transporteur pour une annulation en cours de route.
   Les trois se corrigent au même endroit, dans cet ordre.

## Constats majeurs isolés (un seul rapport, vérifiés sur pièces)

- **Sécu C2 — prise de contrôle d'un compte transporteur** : `POST
  /auth/transporteur/register` est public et ne demande aucune preuve de
  possession. Chaîne complète : un commerçant lit `driver_assigned_uuid` sur sa
  propre commande (objet Fleetbase brut relayé), s'enregistre dessus, devient ce
  transporteur. Le vrai driver ne peut plus s'inscrire. Contredit la décision de
  provisioning manuel déjà actée.
- **Sécu E3/M8 — injection de chemin vers Fleetbase** : `subjectId`,
  `waypointUuid` (transporteur) et `orderId` (flotte) sont interpolés dans les
  URLs sans validation. `subjectId="../../ORDER_X/cancel"` détourne le token de
  service vers une route arbitraire — le contrôle d'appartenance porte sur un
  identifiant, la requête part vers un autre.
- **Sécu E6 — inscription commerçant ouverte, email jamais vérifié**
  (`emailVerified: true` codé en dur). Pollution du pool de dispatch par de
  fausses commandes = vrais transporteurs envoyés à de fausses adresses.
- **Sécu M9 — renseignement concurrentiel** : tout transporteur authentifié voit
  TOUTES les commandes adhoc de l'organisation (adresses, téléphones,
  instructions) sans filtre de proximité ni de diffusion.
- **Métier #2 — coordonnées par défaut d'Alger** : toute adresse saisie librement
  atterrit au même point GPS fictif, pickup ET dropoff. Le dispatch géospatial
  cherche des drivers autour d'un point qui n'est pas la boutique, sans erreur
  visible.
- **Métier #3 — maillon opérateur sans outillage** : rien ne signale une commande
  en attente ; tenable à 10/jour avec un opérateur dédié, pas au-delà.
- **Archi #5 — positions non paginées** : la carte flotte télécharge tout
  l'historique (≈8 600 lignes/driver/jour). Correction : dernière position par
  driver stockée au passage dans le BFF.
- **Archi #13 — healthcheck Docker sur une route inexistante** : conteneur
  `unhealthy` en permanence, redémarrage en boucle possible selon l'orchestrateur.
- **Métier #9 — route `/flotte` jamais déclarée** dans GoRouter alors que
  `UserRole.flotte.homePath` y renvoie : un compte flotte qui se connecte tombe
  sur une route inconnue.

## Corrections d'affirmations faites plus tôt dans la session

À consigner, dans l'esprit du journal :

- **« Les échecs de loginUnified sont indiscernables » était faux.** Le message
  est uniforme, mais trois oracles subsistent : le 409 de l'inscription, les
  messages différenciés des logins par persona, et surtout le **temps de
  réponse** (bcrypt seulement si la ligne existe : ~100 ms vs ~5 ms). Le
  commentaire dans le code décrit une propriété que le code n'a pas.
- **Le soupçon sur le module `flotte` était infondé** : c'est le seul module qui
  pagine correctement, et son anti-IDOR est au niveau des deux autres. Sa seule
  faiblesse propre est l'injection M8.
- **`fleetbaseCustomerUuid` ne sert à rien** : créé à l'inscription (avec un
  User Fleetbase connectable, `create_login: false` manquant — contraire à la
  décision de minimisation des credentials), puis jamais lu : les commandes
  utilisent le Vendor. Et « encrypted at rest » dans le schéma est un commentaire
  sans implémentation.

## Liste priorisée unique

### P0 — avant tout déploiement VPS
1. Secret JWT : supprimer les trois replis, valider au boot (≥32 car.), un seul
   point de config (archi #1 / sécu C1)
2. Fermer `POST /auth/transporteur/register` (invitation à usage unique ou
   création par opérateur) et trancher l'inscription commerçant (sécu C2 + E6)
3. Valider tout identifiant interpolé : `@IsUUID`/`@Matches` + `encodeURIComponent`
   sur subjectId, waypointUuid, orderId flotte (sécu E3 + M8)
4. `@nestjs/throttler` sur /auth (5 tentatives / 15 min / IP+email) (E5, archi #12)
5. Limite de corps explicite + bornes DTO photos (`@ArrayMaxSize`, `@MaxLength`)
   (archi #4 / sécu M11)
6. Garde de rôle sur le contrôleur commerçant + `POST /auth/device-token`
   (archi #10 / sécu E4) — idéalement un `@Persona()` partagé
7. Réparer annulation/suivi commerçant : `resolveOwnedOrder()` commun, garde de
   transition sur le statut Fleetbase live, garde-fou après `started` (archi #3
   + #15, métier #4)
8. Déploiement : route `/health` réelle, `NODE_ENV` non codé en dur, TLS devant
   le BFF, stratégie de migrations Prisma (migrations/ est gitignoré et vide),
   `FLEETBASE_PROOF_DISK/BUCKET` (déjà tracé §7.8)
9. Chemin à coût constant dans loginUnified (hash factice) + messages uniformes
   partout (sécu M7)

### P1 — avant un pilote avec de vrais utilisateurs
10. Câbler les chaînes app : toggle en ligne, `startBackgroundTracking()` à la
    connexion, jeton FCM posté au login + `onTokenRefresh`, polling REST de
    secours (métier #1, archi #6/#7)
11. Capture photo (image_picker) : POD + échec de livraison (métier #6, archi #8)
12. Supprimer le plafond 100 : lecture unitaire dans `resolveOrder`, pagination
    mutualisée pour les listes, petit cache mémoire (archi #2)
13. Dernière position par driver stockée dans le BFF, carte servie depuis là
    (archi #5)
14. Adresses du pilote : interdire la saisie libre sans carte, pré-saisir les
    vraies coordonnées (métier #2)
15. Trancher le dispatch : `adhoc: true` à la création, ou opérateur outillé
    (métier #3)
16. Prix/délai minimal affiché, même forfaitaire (métier #5)
17. Adhoc : restreindre les champs avant acceptation (aperçu sans adresse
    exacte), filtre de proximité (sécu M9)
18. Route/écran `/flotte` ou blocage propre du rôle à la connexion (métier #9)
19. Mises à jour optimistes : supprimer, recharger comme `applyActivity`
    (archi #9)
20. Navigation externe Google Maps/Waze (`url_launcher`) — peu coûteux, fort
    impact quotidien (métier #7)

### P2 — ensuite
21. Projection explicite par persona des objets Fleetbase (sécu M10 — referme
    structurellement C2/M9)
22. Révocation de session (`tokenVersion`) (sécu M12)
23. AuditLog réellement écrit sur les refus anti-IDOR (sécu F14)
24. Fusion des désérialiseurs Dart dupliqués, déjà divergents (archi #14)
25. Nettoyage schéma Prisma (champs morts, `create_login: false`, commentaire
    chiffrement) (archi #11/#15)
26. Rollback/compensation sur l'inscription commerçant (Vendor orphelin)
    (archi #11)
27. UX attente commerçant (retry adhoc invisible), fraîcheur de position
    (métier #10/#11)

## Lecture d'ensemble

Les trois rapports convergent sur le même diagnostic : **le serveur est en
avance sur l'app, et la couture entre les deux n'a jamais été tirée**. Le
travail Fleetbase (anti-IDOR, machine à états, push, purge des jetons) est
solide et documenté — mais push, GPS et photo n'ont aucun appelant côté
Flutter, et deux plafonds d'échelle (100 commandes, positions intégrales)
cassent le produit dès la première semaine d'usage réel. Côté sécurité, le
modèle est bien raisonné mais trois portes contournent tout le reste : le
secret JWT par défaut, l'inscription transporteur publique, et l'injection de
chemin vers le token de service. Aucun de ces correctifs n'est un chantier :
P0 entier se mesure en heures, pas en semaines.
