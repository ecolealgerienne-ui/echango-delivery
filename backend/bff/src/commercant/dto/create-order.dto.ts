import { ArrayMaxSize, IsArray, IsBoolean, IsISO8601, IsIn, IsInt, IsNumber, IsOptional, IsString, Matches, Max, MaxLength, Min, ValidateNested } from 'class-validator';
import { Type } from 'class-transformer';

import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';

/**
 * Catégories de véhicule.
 *
 * Liste fermée et volontairement courte : elle sert à écarter l'inadapté, pas
 * à décrire un parc. Trois entrées suffisent à trancher « ça tient sur une
 * moto » de « il faut un coffre » et de « il faut un hayon ».
 */
export const VEHICLE_TYPES = ['moto', 'voiture', 'utilitaire'] as const;

/**
 * Niveau de preuve exigé à la livraison.
 *
 * `photo` est le seul validé de bout en bout côté transporteur (journal §11.1).
 * `signature` reste à construire — déclaré ici pour que le contrat n'ait pas à
 * changer quand il arrivera, mais l'app ne le propose pas encore.
 */
export const POD_METHODS = ['aucune', 'photo', 'signature'] as const;

export class CreateOrderDto {
  @IsString()
  pickupLocationName: string;

  @IsNumber()
  pickupLatitude: number;

  @IsNumber()
  pickupLongitude: number;

  /**
   * Commune et quartier, tels que le géocodage inverse les a rendus.
   *
   * ⚠️ **L'application les avait et les jetait.** `MapPickerScreen` renvoie un
   * `PickedLocation` complet — quartier, commune, wilaya, code postal — et le
   * formulaire n'en gardait que le libellé, qui partait dans les *précisions*.
   * Le `Place` créé n'avait donc **que son nom et un point** : pas une seule
   * colonne d'adresse structurée.
   *
   * Conséquence, mesurée à l'écran le 31/07/2026 : sur une course non
   * réclamée, `projectPlace(…, 'anonymous')` recompose l'adresse à partir des
   * seules colonnes structurées — il n'y en avait aucune, donc l'entreprise
   * lisait `order_1sn4fzn6e2` en titre de ligne, quatre lignes sur cinq. Le
   * masquage fonctionnait ; il ne restait simplement rien à masquer.
   *
   * Commune et quartier, et rien de plus : c'est ce qui permet de juger un
   * détour sans désigner une porte.
   */
  @IsOptional()
  @IsString()
  @MaxLength(120)
  pickupCity?: string;

  /**
   * Wilaya de l'enlèvement.
   *
   * ── Pourquoi elle manquait, et ce que ça bloquait (02/08/2026) ──────────
   *
   * Le géocodage inverse l'extrait (`state`/`region` → `province`,
   * `common/geocoding`), le carnet d'adresses la conserve (`SaveAddressDto`),
   * et la projection la **sert déjà** au transporteur — mais elle n'était
   * transportée nulle part entre les deux : ce DTO n'avait que commune et
   * quartier. **La wilaya se perdait donc entre le carnet et la course.**
   *
   * C'est la donnée sur laquelle repose la décision produit du 02/08/2026 —
   * « le transporteur choisit ce qu'il voit, wilaya d'abord » : sans elle, un
   * filtre par wilaya n'a rien sur quoi filtrer.
   *
   * ⚠️ Facultative ici comme au carnet, et c'est délibéré : elle vient du
   * géocodage, jamais d'une saisie. L'exiger ferait échouer la création d'une
   * course pour une raison que le commerçant ne comprendrait pas — il tape une
   * rue, pas une wilaya. C'est au **filtre** de ne pas cacher une course dont
   * la wilaya est inconnue, pas à la création de la refuser.
   */
  @IsOptional()
  @IsString()
  @MaxLength(120)
  pickupProvince?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  pickupNeighborhood?: string;

  @IsString()
  pickupContactName: string;

  @IsString()
  pickupContactPhone: string;

  @IsOptional()
  @IsString()
  pickupNotes?: string;

  @IsString()
  dropoffLocationName: string;

  @IsNumber()
  dropoffLatitude: number;

  @IsNumber()
  dropoffLongitude: number;

  /** Voir [pickupCity]. */
  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffCity?: string;

  /** Wilaya de la livraison. Même motif que [pickupProvince]. */
  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffProvince?: string;

  @IsOptional()
  @IsString()
  @MaxLength(120)
  dropoffNeighborhood?: string;

  @IsString()
  dropoffContactName: string;

  @IsString()
  dropoffContactPhone: string;

  @IsOptional()
  @IsString()
  dropoffNotes?: string;

  /**
   * Contenu du colis. Ce qui permet au transporteur de refuser en connaissance
   * de cause — et ce qui tranche un litige.
   */
  @IsOptional()
  @IsArray()
  @ArrayMaxSize(20)
  @ValidateNested({ each: true })
  @Type(() => OrderItemDto)
  items?: OrderItemDto[];

  @IsOptional()
  @IsString()
  deliveryInstructions?: string;

  /**
   * Livraison programmée, au format ISO 8601.
   *
   * Une boulangerie sait la veille qu'elle livre à 8 h. C'est ce qui distingue
   * un outil professionnel d'un service à la demande, et ça lisse la charge du
   * réseau au lieu de la concentrer sur les pics.
   */
  @IsOptional()
  @IsISO8601()
  scheduledAt?: string;

  /** Catégorie minimale de véhicule requise. */
  @IsOptional()
  @IsIn(VEHICLE_TYPES as unknown as string[])
  vehicleType?: string;

  /** Niveau de preuve exigé à la livraison. */
  @IsOptional()
  @IsIn(POD_METHODS as unknown as string[])
  podMethod?: string;

  /**
   * Confier la course à **un favori nommé** — un conducteur ou une entreprise.
   *
   * ── Deux modes explicites, plus de repli automatique (03/08/2026) ──────────
   *
   * Absent → **diffusion large** au pool réseau. Présent → **ciblé** : la course
   * est confiée à ce favori, **en ligne ou non**, et l'attend (invisible au
   * pool). Décision produit assumée : un favori hors-ligne fait attendre la
   * course plutôt que de la diffuser, et le commerçant peut la **rediriger**
   * tant que personne ne l'a prise (`docs/plan_ciblage_favori.md`).
   *
   * ⚠️ A remplacé le booléen `preferFavourites` (« n'importe quel favori en
   * ligne, sinon diffusion »). Le *kind* (driver/fleet) n'est PAS pris ici : il
   * se **résout depuis la liste de favoris** du commerçant — seule source qui
   * dit aussi que l'uuid EST bien un favori (on ne cible pas un inconnu).
   */
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'targetFavouriteUuid invalide' })
  targetFavouriteUuid?: string;

  /**
   * Rémunération proposée au transporteur, dans la devise de l'organisation.
   *
   * ── Pourquoi le commerçant le saisit plutôt qu'un barème ────────────────────
   *
   * La tarification n'est pas tranchée (Priorité 3 du plan d'action), et
   * inventer un barème serait une décision produit prise par défaut. Laisser le
   * commerçant proposer résout le vrai problème — un transporteur qui ignore ce
   * que rapporte une course ne peut pas décider de la prendre — sans préempter
   * la question : le marché ajuste, et les montants observés au pilote
   * informeront le barème plutôt que l'inverse.
   *
   * Borné pour attraper la faute de frappe, pas pour encadrer un tarif :
   * 500 000 est absurde pour une course urbaine, et un zéro de trop est
   * l'erreur de saisie la plus courante.
   */
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  @Max(500000)
  price?: number;

  /**
   * Somme que le destinataire remettra au transporteur à la livraison.
   *
   * ⚠️ **À ne jamais confondre avec `price`.** Celui-ci est ce que le
   * commerçant doit au transporteur ; celui-là ce que le destinataire doit au
   * commerçant. Ils circulent en sens inverse, et les additionner ou les
   * substituer serait l'erreur fondatrice du mécanisme
   * (`docs/specs_paiement_livraison.md` §7).
   *
   * Ce qu'il recouvre — marchandise seule, ou marchandise plus frais de port —
   * est laissé au commerçant (`codIncludesDelivery`), et ce choix ne concerne
   * que ce qu'il demande à son propre client : **le règlement entre lui et le
   * transporteur est le même dans les deux cas**, celui-ci retenant sa
   * rémunération sur les espèces.
   *
   * Absent = livraison sans encaissement, le cas ordinaire.
   */
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1, { message: 'Un encaissement de 0 est une livraison sans encaissement : laissez le champ vide' })
  @Max(500000)
  codAmount?: number;

  /**
   * Le montant à encaisser couvre-t-il aussi les frais de livraison ?
   *
   * ⚠️ **Ne change rien au règlement.** Le transporteur retient sa rémunération
   * sur les espèces dans les deux cas, et la dette vaut toujours
   * `perçu − rémunération`. Ce drapeau sert au commerçant, pour reconstituer son
   * chiffre d'affaires : marchandise = encaissé − livraison si les frais sont
   * dedans, encaissé tout court sinon.
   */
  @IsOptional()
  @IsBoolean()
  codIncludesDelivery?: boolean;

  /**
   * Enregistre la commande sans la diffuser (décision produit, 30/07/2026).
   *
   * Chez Fleetbase, un brouillon n'est rien de plus qu'une commande créée
   * sans `adhoc` ni `driver_assigned_uuid` : personne n'est sollicité tant
   * qu'elle n'est pas publiée (`POST /commandes/:id/publier`). Aucun statut
   * dédié n'existe côté Fleetbase pour ça — l'absence des deux champs de
   * dispatch EST le brouillon, rien n'est stocké de plus.
   */
  @IsOptional()
  @IsBoolean()
  draft?: boolean;
}

export class OrderItemDto {
  /**
   * Ce que contient le colis.
   *
   * ⚠️ **Facultative depuis le 02/08/2026, et c'est la correction d'un défaut
   * bloquant sur le chemin principal du commerçant.**
   *
   * Elle était exigée (`@IsString()` sans `@IsOptional()`) pendant que le
   * formulaire la traitait comme facultative : ni étoile, ni entrée dans sa
   * liste `missing`. Et comme le champ « Nombre de colis » est pré-rempli à
   * `1`, le formulaire considère **toujours** qu'il a des détails de colis à
   * transmettre — il envoyait donc **toujours** un `items[0]`, en omettant la
   * description quand elle était vide.
   *
   * Résultat : **toute course créée sans décrire le contenu était refusée**,
   * sur un « Certaines informations saisies sont invalides » qui ne nommait
   * aucun champ. Aucun des sept scénarios de `scripts/` ne pouvait le voir —
   * ils composent leur corps de requête à la main. Il a fallu le premier
   * parcours joué **dans l'application** (`integration_test/`) pour le trouver.
   *
   * Pourquoi assouplir le serveur plutôt que durcir le formulaire : la
   * correction du 01/08/2026 (revue D3) a explicitement voulu qu'un colis
   * **fragile**, compté ou pesé voyage même sans description — exiger une
   * description reviendrait sur cette décision. Le service se contente de
   * recopier `items` dans `meta`, donc rien en aval n'en dépend.
   *
   * ⚠️ **`quantity` porte la même exposition, en plus étroit** : elle reste
   * exigée, et le formulaire l'omet quand la saisie n'est pas lisible. Le champ
   * étant pré-rempli, le cas ne s'ouvre que si le commerçant le vide en cochant
   * « fragile ». Laissé tel quel faute d'être observé — à reprendre si ça sort.
   */
  @IsOptional()
  @IsString()
  @MaxLength(200)
  description?: string;

  /**
   * Nombre de colis.
   *
   * ⚠️ `@IsInt()` et `@Min(1)` ajoutés le 31/07/2026, en même temps que le
   * champ apparaissait enfin dans le formulaire commerçant — qui envoyait
   * `quantity: 1` en dur depuis l'origine. Tant que la seule valeur possible
   * était `1`, `@IsNumber()` suffisait ; dès qu'un humain saisit le nombre,
   * `0`, `-2` et `1.5` deviennent des entrées plausibles, et un colis se
   * compte en entiers positifs. `@Max` borne une saisie erronée à la frappe
   * plutôt qu'une exigence métier — personne ne confie mille colis à une moto.
   */
  @IsInt()
  @Min(1)
  @Max(999)
  quantity: number;

  /** Poids en kilogrammes. */
  @IsOptional()
  @IsNumber()
  weight?: number;

  /** Signale un contenu qui impose des précautions de transport. */
  @IsOptional()
  @IsBoolean()
  fragile?: boolean;
}

export class ListOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string; // 'pending', 'active', 'completed', 'failed', 'cancelled'

  /**
   * ⚠️ **Bornées dans les deux sens.** Sans `@Min`, `?limit=-1` fait basculer
   * Prisma en « les N derniers » ; sans `@Max`, `?limit=1000000` charge et
   * projette tout l'historique, depuis un simple compte valide, et
   * l'amplification pénalise ensuite tout le monde via le plafond global de
   * débit (revue du 01/08/2026, S3).
   *
   * 100 est le plafond que Fleetbase applique de son côté : au-delà, la page
   * demandée n'existe de toute façon pas.
   */
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}
