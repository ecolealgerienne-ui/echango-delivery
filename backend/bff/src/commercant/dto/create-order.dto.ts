import {
  IsString,
  IsNumber,
  IsOptional,
  IsArray,
  IsInt,
  IsISO8601,
  IsIn,
  IsBoolean,
  ValidateNested,
  ArrayMaxSize,
  MaxLength,
  Min,
  Max,
} from 'class-validator';
import { Type } from 'class-transformer';

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
   * Solliciter d'abord les transporteurs favoris du commerçant.
   *
   * Le repli sur le pool commun est automatique si aucun favori n'est
   * disponible : c'est ce qui préserve l'effet réseau (voir DriverFavourite).
   */
  @IsOptional()
  @IsBoolean()
  preferFavourites?: boolean;

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
   * est laissé au commerçant : c'est sa relation commerciale, pas la nôtre. Le
   * registre enregistre ce qu'il déclare.
   *
   * Absent = livraison sans encaissement, le cas ordinaire.
   */
  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  @Min(1, { message: 'Un encaissement de 0 est une livraison sans encaissement : laissez le champ vide' })
  @Max(500000)
  codAmount?: number;
}

export class OrderItemDto {
  @IsString()
  @MaxLength(200)
  description: string;

  @IsNumber()
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

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  page?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  limit?: number;
}
