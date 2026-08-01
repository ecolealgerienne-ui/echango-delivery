# Plan d'exécution — revue du 1er août 2026

Huit lots, ordonnés par **ce qu'ils protègent**, pas par difficulté. Chacun porte le
contrôle qui le débloque : un lot dont on ne sait pas dire qu'il a réussi n'est pas fait.

Contrainte qui prime, reprise du plan de migration : **contrat constant**. Les projections
restent le contrat avec l'application ; un lot qui change ce que l'app reçoit le dit
explicitement et le prouve.

---

## Lot 1 — Le registre dit la vérité (C2, M1, M3, M4, M5, M6, M8, M10, M11)

Le plus grave du relevé, et le seul où une erreur se compte en dinars.

| # | Correction |
|---|---|
| C2 | `resolveFacilitatorId` du module commerçant délègue au module transporteur — **une seule** résolution, celle qui connaît le repli plateforme |
| M1 | Le plafond cesse de lire `debtBetween` : nouvelle mesure `cashHeldBy`, qui compte le **perçu moins le retenu moins le remis**, jamais la rémunération due |
| M3 | `pickAvailableFavourite` interroge la jambe que la course portera réellement (plateforme si provisionnée), plus celle qui est structurellement vide |
| M4 | La reprise idempotente exige `declaredBy === 'driver'` — une ligne du commerçant n'est plus traversée en silence |
| M5 | Une déclaration **contestée** n'est plus un enregistrement : elle réapparaît dans « non enregistré », et le conducteur peut déclarer la sienne |
| M6 | `net_amount` et le détail se recomposent en solde — les rémunérations sans encaissement y figurent |
| M8 | Un seul `assertCashCeiling`, partagé, qui hydrate lui-même et rend toujours les chiffres |
| M10 | `facilitatorId` passe de `SetNull` à `Restrict`, comme les deux autres parties |
| M11 | Le message de refus nomme la contrepartie réelle |

**Contrôle** : `test-parcours-argent.sh` et `test-parcours-argent-flotte.sh` passent **à
l'identique** — c'est ce qui prouve le contrat constant. Plus un cas neuf : une course
prépayée ne doit pas desserrer le plafond.

## Lot 2 — L'entreprise voit ce sur quoi elle décide (C1, F3)

Hydratation des listes **après** pagination, par lecture unitaire des seules commandes
affichées. Mesuré : aucun filtre multi-sujets n'existe (`subject_uuid[]` n'en retient
qu'un, la virgule rend 0), donc pas de lecture groupée possible.

**Contrôle** : un appel réel aux deux listes du profil entreprise montre `price` et
`cod_amount` non nuls.

## Lot 3 — Aucune absence affirmée sans l'avoir vérifiée (C3, D5, D6, D7, D8)

Règle 10, quatre écrans. Chaque liste qui échoue pose son drapeau et l'écran distingue
« vide » de « je n'ai pas pu savoir ».

**Contrôle** : plus aucun `catchError`/`catch (_)` muet devant une liste dans `lib/state/`.

## Lot 4 — Sécurité (S1, S2, S3, S4)

`active` devient vérifiable et écrit ; `trust proxy` posé avec sa liste de confiance ;
`limit`/`page` bornés ; la garde de clôture lit le flux plutôt qu'un littéral.

**Contrôle** : bornes éprouvées par appel réel (`?limit=-1`, `?limit=1000000`).

## Lot 5 — Les plafonds silencieux de Fleetbase (F1, F2, F4, F6, F7, F8)

Toute lecture de collection pagine ou dit pourquoi elle n'en a pas besoin.

**Contrôle** : aucun appel de collection sans `limit` explicite dans le client.

## Lot 6 — Ce qui n'a pas d'appelant (A2..A8, M9)

Supprimer ou brancher — jamais laisser à mi-chemin. Et corriger les **quatre affirmations
fausses** de la documentation, qui coûtent plus que les manques qu'elles décrivent.

**Contrôle** : `check_error_codes.dart` compare désormais le registre Dart au registre
TypeScript, avec ses cas de refus.

## Lot 7 — Ce que l'utilisateur voit (D1, D2, D3, D4, D9)

**Contrôle** : `flutter analyze`, `flutter test`, parité FR/AR.

## Lot 8 — L'inscription transporteur et entreprise (A1)

Le plus gros, et le dernier : deux parcours d'écran pour des routes qui existent, sont
testées, et sont inatteignables.

**Contrôle** : un compte de chaque type créé depuis l'application.
