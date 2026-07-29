# Paiement à la livraison — étude et proposition (29 juillet 2026)

## 1. Pourquoi ce document existe

Le paiement à la livraison domine le commerce en ligne algérien. Notre produit ne le gère pas du tout, et l'a écarté par omission plutôt que par décision : le modèle implicite d'Echango Delivery est celui d'une course déjà payée, transposé d'Uber Direct — c'est-à-dire d'un marché où la carte bancaire est la norme.

Ce document répond à trois questions : comment font ceux qui opèrent déjà sur ce modèle, **ce que l'application y apporte réellement**, et ce qu'il faudrait trancher chez nous avant d'écrire une ligne de code.

**Aucun code n'est écrit à ce stade, et c'est délibéré** — voir §8.

## 2. Ce que c'est, et pourquoi ce n'est pas un champ « montant »

Vu du formulaire, le paiement à la livraison ressemble à une case à cocher et un nombre. Vu du système, c'est une **chaîne de garde d'argent liquide** entre trois parties, dont une seule est notre client :

```
commerçant → [colis] → transporteur → [colis] → destinataire
destinataire → [espèces] → transporteur → [espèces] → commerçant
```

Le second flux est celui qui pose tous les problèmes. Il court à contresens du premier, il transite par quelqu'un qui n'est ni l'expéditeur ni le destinataire, et il n'a pas de trace naturelle. Tout ce qui suit découle de là.

Trois questions structurent n'importe quelle mise en œuvre :

1. **Qui détient l'argent, et combien de temps ?**
2. **Comment sait-on ce qui a été réellement encaissé** — par opposition à ce qui aurait dû l'être ?
3. **Qui supporte la perte** quand l'écart apparaît ?

## 3. Comment font les autres

### 3.1 Trois modèles, pas un

| Modèle | Qui encaisse | Qui détient | Reversement | Exemples |
|---|---|---|---|---|
| **Transporteur intégré** | Le livreur, salarié ou affilié | La société, via ses agences | Cycle fixe, 3 à 7 jours | Yalidine, ZR Express, Noest, Maystro (Algérie) ; Bosta, Mylerz (Égypte) |
| **Plateforme à solde coursier** | Le coursier indépendant | Le coursier lui-même | Compensé sur ses gains | DoorDash (paiement en espèces) |
| **Agrégateur** | Personne — il oriente vers un transporteur | Aucun | Sans objet | Ecotrack (Algérie) |

Le premier est le modèle dominant en Algérie et en Égypte. Le deuxième est le seul conçu pour un **réseau de coursiers indépendants**, ce qui est notre cas. Le troisième dit quelque chose d'utile : on peut servir ce marché sans jamais toucher l'argent.

### 3.2 Le modèle intégré, tel qu'il tourne

C'est le plus documenté, et le plus instructif sur les points de friction.

**Au moment de la livraison**, le livreur encaisse le montant exact, marque la commande livrée, et rapporte les espèces en fin de tournée face au manifeste. Les écarts déclenchent un signalement automatique.

**Le rapprochement** se fait au dépôt : un agent ou un caissier confronte, ligne à ligne, ce que le livreur ramène à ce que le système attendait. Fait manuellement, il prend **3 à 5 jours ouvrés**, laisse jusqu'à **15 % des encaissements quotidiens en suspens non vérifié**, et les tableurs manuels y introduisent **3 à 5 % d'erreurs**.

**Le reversement au commerçant** suit un cycle annoncé : 3 à 5 jours ouvrés après confirmation de livraison chez Bosta, 5 à 7 chez Mylerz, virement hebdomadaire ou mensuel chez les transporteurs algériens.

**Le chiffre qui compte pour le commerçant** n'est aucun de ceux-là pris isolément, mais leur somme — le *cycle effectif* : « si votre transporteur met 5 jours à livrer et 5 jours à reverser, vous financez 10 jours de stock et de publicité avant de voir la trésorerie ». C'est la métrique par laquelle un commerçant choisit son transporteur, avant même le prix.

**Le marché algérien** ajoute deux notions absentes des comparables occidentaux, visibles dans les API des transporteurs locaux : le champ qui porte le montant à encaisser (`Total` chez ZR Express/Procolis) est distinct du prix du transport, et un indicateur de **mode de remise** (`TypeLivraison`) distingue la livraison à domicile du retrait en agence (*stop-desk*), moins chère et à taux d'échec bien plus faible.

### 3.3 Le modèle à solde coursier

DoorDash, pour ses commandes payées en espèces, ne fait transiter aucun argent : **le coursier garde le liquide encaissé, et le montant est déduit de son versement hebdomadaire**. Un solde négatif suspend l'attribution de nouvelles commandes en espèces jusqu'à régularisation.

C'est le seul des trois modèles qui fonctionne avec des **prestataires indépendants sans dépôt**. Le mécanisme de garde n'est pas un coffre, c'est une **compensation sur créance** : la plateforme ne détient pas l'argent, elle détient une dette qu'elle peut retenir. Et le plafond de solde n'est pas un contrôle comptable, c'est le seul instrument de limitation du risque.

## 4. L'apport de l'application — la vraie question

Le paiement à la livraison a existé longtemps sans logiciel : un manifeste papier, une sacoche, un rapprochement le soir. L'application n'a donc d'intérêt que si elle règle des problèmes que le papier ne règle pas. Il y en a cinq, et ils sont tous des **problèmes d'information, pas de manipulation d'argent**.

### 4.1 Elle dit au transporteur le bon montant, au bon moment

L'erreur la plus fréquente et la moins spectaculaire : encaisser le mauvais montant. Le montant est décidé par le commerçant, transite par un intermédiaire, et se lit au moment le plus défavorable — devant une porte, sous la pluie, avec un client pressé. L'afficher sur l'écran de la course, au moment de la remise, supprime la classe entière.

### 4.2 Elle transforme un geste en enregistrement

« Livré » et « encaissé X » deviennent **une seule déclaration**, horodatée, géolocalisée, accompagnée de la preuve photo qui existe déjà. Sans l'application, ces deux faits vivent dans deux systèmes — le suivi de livraison et le manifeste papier — et personne ne les rapproche avant le dépôt.

C'est ici que notre chaîne de preuve déjà construite devient un actif : le mécanisme de photo, validé de bout en bout le 28/07, n'a plus qu'à porter une information de plus.

### 4.3 Elle fait apparaître l'écart à la porte, pas cinq jours plus tard

Le client n'a que la moitié de la somme, refuse le colis, ou paie et conteste. Sur papier, l'écart se découvre au rapprochement, quand plus personne ne se souvient de rien — d'où les 3 à 5 % d'erreurs et les 15 % en suspens cités plus haut. Dans l'application, le transporteur déclare l'écart **au moment où il le constate**, avec un motif choisi dans une liste fermée — exactement le mécanisme du refus motivé mis en place le 29/07, appliqué à l'argent.

Le rapprochement cesse alors d'être une enquête pour devenir une lecture.

### 4.4 Elle donne au commerçant la seule métrique qui l'intéresse

« Combien me doit-on, et depuis quand ? » Aucun de nos écrans ne peut y répondre aujourd'hui. C'est pourtant la question par laquelle un commerçant juge un transporteur — le *cycle effectif* de §3.2 — et elle se calcule entièrement à partir de données que nous aurions déjà.

### 4.5 Elle borne le risque sans coffre-fort

Le plafond de solde de DoorDash n'est réalisable que parce qu'un système sait, en continu, combien chaque coursier détient. C'est **une capacité purement logicielle qui remplace une contrainte physique** : là où un transporteur intégré limite son risque par des agences et des dépôts quotidiens, une plateforme le limite en cessant de proposer des courses encaissées à quelqu'un qui doit déjà trop.

Pour un réseau de transporteurs indépendants sans dépôt, **c'est le seul instrument de contrôle disponible**. Il n'existe pas sans application.

## 5. Ce qui change pour nous, et que les comparables ne disent pas

Notre position n'est celle d'aucun des trois modèles :

- **Nous n'avons ni agences ni dépôts.** Le rapprochement de fin de tournée face à un caissier n'existe pas et n'existera pas — c'est toute l'infrastructure de Yalidine, et elle est la raison de leur cycle de reversement.
- **Nos transporteurs sont indépendants**, sans lien de subordination. On ne leur impose pas un passage quotidien.
- **Mais, contrairement à DoorDash, nous ne payons pas encore les transporteurs.** Le mécanisme de compensation sur créance — retenir sur le versement — suppose un versement. Aujourd'hui, la rémunération est un montant proposé par le commerçant, et rien dans le système ne verse quoi que ce soit.
- **En revanche, nous avons quelque chose qu'ils n'ont pas** : les transporteurs favoris. Une relation répétée entre un commerçant et un transporteur qu'il connaît change entièrement le profil de risque d'une remise d'espèces — et fournit l'occasion naturelle de la remise, à l'enlèvement suivant.

## 6. Trois voies possibles, et celle que je recommande

### Voie A — Echango encaisse et reverse (modèle Yalidine)

Le transporteur remet à Echango, Echango reverse au commerçant sur un cycle annoncé.

**Contre** : il faut des points de remise physiques, une trésorerie pour avancer les reversements, et surtout — détenir des fonds pour le compte de tiers engage un statut réglementaire. Sur un marché où nous n'avons pas encore livré une seule course, c'est construire l'infrastructure d'un transporteur intégré alors qu'on est une place de marché.

### Voie B — Le transporteur remet directement au commerçant, l'application tient le registre ⭐

Le transporteur encaisse et **conserve** les espèces. L'application tient, en continu, ce qu'il doit à chaque commerçant. La remise est physique — au prochain enlèvement, ce qui arrive naturellement entre un commerçant et son transporteur favori — et **les deux parties la confirment dans l'application**, ce qui la solde.

Echango ne touche jamais l'argent. Son apport est le registre : montant attendu, montant encaissé, écart motivé, dette courante, remises confirmées.

**Pour** : c'est la seule voie compatible avec un réseau sans dépôt ; elle évite d'emblée la question du statut de détenteur de fonds ; elle s'appuie sur les favoris, qui existent déjà ; et le cycle de reversement devient le plus court du marché — la remise a lieu au prochain enlèvement, pas sous cinq jours.

**Contre, et il est réel** : le risque de non-remise est porté par le commerçant, pas par la plateforme. Un transporteur peut disparaître avec les espèces. Trois garde-fous, tous logiciels :

1. **Un plafond de dette par transporteur** — au-delà, il ne reçoit plus de courses encaissées. Le mécanisme DoorDash, transposé.
2. ~~**Les courses encaissées réservées aux favoris**~~ — **écarté le 29/07/2026, après implémentation.** Le raisonnement supposait un pool anonyme. Il ne l'est pas : les transporteurs sont **sélectionnés et provisionnés par Echango**, sur invitation nominative, et aucun ne s'inscrit de lui-même. Le contrôle a donc déjà eu lieu à l'entrée du réseau ; le refaire commerçant par commerçant ne protégeait de rien et interdisait l'encaissement à tout commerçant sans favori — c'est-à-dire à tout nouveau commerçant. La sélection à l'entrée **est** le garde-fou, et elle est plus forte qu'une liste par commerçant.
3. **La trace** : chaque encaissement horodaté, géolocalisé, avec photo. Elle ne récupère pas l'argent, mais elle change ce qu'un litige coûte à établir.

### Voie C — Ne rien faire, et le dire

Le commerçant s'arrange hors de l'application. C'est la situation actuelle, à ceci près qu'elle n'est écrite nulle part et que personne ne l'a choisie.

À retenir seulement si la Voie B est jugée trop risquée — mais alors il faut l'assumer explicitement, et accepter de n'adresser que le commerce déjà payé.

**Ma recommandation : la Voie B**, avec démarrage restreint aux favoris. Elle fait de l'application ce qu'elle sait être — un registre de confiance entre deux parties qui n'ont autrement que du papier — sans lui faire porter un rôle d'établissement financier que rien ne justifie à ce stade.

## 7. Ce que la Voie B suppose, en pratique

Esquisse, pas spécification — chaque point ci-dessous est à valider avant d'être écrit.

**Sur la commande** : un montant à encaisser, **distinct de la rémunération du transporteur**. Les confondre serait l'erreur fondatrice : l'un est ce que le destinataire doit au commerçant, l'autre ce que le commerçant doit au transporteur. Ils ne circulent pas dans le même sens.

**Sur l'encaissement** : le montant réellement perçu, qui n'est pas toujours celui attendu. Un écart exige un motif — refus du colis, somme incomplète, client sans monnaie — dans une liste fermée, comme les motifs de refus et d'échec déjà en place.

**Sur la dette** : un solde par couple transporteur ↔ commerçant, alimenté par les encaissements et soldé par les remises. C'est lui qui répond aux deux questions qui comptent : « combien me doit-on ? » et « puis-je encore confier une course encaissée à celui-là ? »

**Sur la remise** : une confirmation **par les deux parties**. Une remise déclarée d'un seul côté n'est pas une preuve, c'est une affirmation — et c'est précisément le moment où le registre doit être incontestable.

**Ce qui existe déjà et sert** : la chaîne de preuve photo, les motifs en liste fermée, les favoris, la piste d'audit, les notifications. **Ce qui n'existe pas** : tout le reste, et notamment le versement au transporteur, qui n'a jamais été construit.

## 8. Pourquoi je n'écris rien maintenant

Une mise en œuvre partielle serait **pire que l'absence**. Si un commerçant peut cocher « paiement à la livraison » et saisir un montant, il en conclura que le système gère l'encaissement. Il confiera de l'argent réel à cette croyance. S'il n'y a derrière ni registre, ni plafond, ni remise confirmée, la fonctionnalité aura créé exactement le risque qu'elle avait l'air de couvrir.

C'est la version argent du défaut que le projet a rencontré plusieurs fois cette semaine : une valeur affichée qui laisse croire à une capacité qui n'existe pas.

## 9. À trancher avant d'écrire

1. **Quelle voie** (§6) — c'est la décision dont tout le reste dépend.
2. **Qui supporte la perte** en cas de non-remise : le commerçant, le transporteur, Echango, ou un partage ? Sans réponse écrite, la réponse de fait sera « le premier qui se plaint ».
3. **Le plafond de dette** : un montant, et ce qui se passe quand il est atteint.
4. **Les frais de livraison** sont-ils encaissés en même temps que la marchandise, comme le font les transporteurs algériens, ou réglés à part ? Cela change qui doit quoi à qui.
5. **Le retrait en agence** (*stop-desk*) a-t-il un sens pour nous ? Il n'a pas d'équivalent dans notre modèle, mais c'est l'option la moins chère et la plus fiable du marché local.
6. **Vérification juridique** : détenir ou faire transiter des fonds pour compte de tiers en Algérie relève d'un cadre réglementaire que je ne connais pas et que je ne prétendrai pas connaître. La Voie B est conçue pour l'éviter — **cela reste à confirmer par un juriste**, au même titre que la question de licence AGPL déjà différée.

---

## Sources

- [Bosta et e& Égypte — intégration paiement, rapprochement et règlement dans les flux marchands](https://thenextafrica.com/bosta-and-e-egypt-collaborate-to-transform-merchant-operations/)
- [Égypte — marché du paiement à la livraison, cycles de reversement Bosta et Mylerz](https://easysellapp.com/blogs/wiki/egypt-ecommerce-cod-market-entry-shopify-2026)
- [Rapprochement du paiement à la livraison — délais, taux d'erreur, trésorerie en suspens](https://www.shiprexnow.com/blog/how-to-automate-cod-reconciliation-driver-payouts-ksa-uae/)
- [Gestion du paiement à la livraison — suivi, contrôle et sécurisation](https://roboost.ai/blog/cash-on-delivery-management-how-to-track-control-and-secure-cod-operations)
- [Validation du paiement et rapprochement livreur au retour de tournée](https://eliteextra.com/payment-validation/)
- [Exploitation du paiement à la livraison à l'échelle](https://trackify.net/cod-fulfillment-operations-guide-2026/)
- [DoorDash — commandes en espèces, solde coursier et suspension](https://www.ridesharingdriver.com/cash-on-delivery-doordash/)
- [Transporteurs algériens — comparatif Yalidine, ZR Express, Noest](https://dz-ecom.com/en/blog/yalidine-vs-zr-express-vs-noest-comparatif-2026)
- [Sociétés de livraison en Algérie pour le paiement à la livraison](https://codrocket.com/fr/blog/best-delivery-companies-algeria-2026)
- [API unifiée des transporteurs algériens — champs de colis](https://dzbuild.com/fr/blog/api-livraison-gratuite-algerie-dzship)
- [CourierDZ — client PHP multi-transporteurs algériens](https://github.com/PiteurStudio/CourierDZ)
- [Défis du dernier kilomètre et paiement à la livraison au MENA](https://codrocket.com/blog/last-mile-delivery-challenges-mena-solutions)
