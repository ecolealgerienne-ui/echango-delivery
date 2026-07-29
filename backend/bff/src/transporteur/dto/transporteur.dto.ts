import {
  IsString,
  Matches,
  IsOptional,
  IsBoolean,
  IsNumber,
  IsArray,
  IsIn,
  IsObject,
  ArrayMinSize,
  ArrayMaxSize,
  MaxLength,
  Min,
  Max,
  ValidateNested,
} from 'class-validator';
import { Type } from 'class-transformer';
import { COLLECTION_DISCREPANCY_REASONS } from '../../cash/cash.service';


/**
 * Identifiants Fleetbase acceptés : uuid (8-4-4-4-12) ou public_id
 * (`order_xxx`, `driver_xxx`, `place_xxx`…). Aucun des deux ne contient de
 * slash, de point ou d'espace.
 *
 * Cette contrainte n'est pas cosmétique : ces valeurs finissent interpolées
 * dans une URL Fleetbase appelée avec le token de service. Sans elle,
 * `"../../ORDER_X/cancel"` détournait la requête vers une autre commande
 * (revue E3). Le client HTTP ré-encode aussi les segments — deux barrières,
 * pour qu'un futur appelant qui oublierait l'une ne rouvre pas la faille.
 */
export const FLEETBASE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;

export class UpdatePositionDto {
  @Type(() => Number)
  @IsNumber()
  latitude: number;

  @Type(() => Number)
  @IsNumber()
  longitude: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  altitude?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  heading?: number;

  @IsOptional()
  @Type(() => Number)
  @IsNumber()
  speed?: number;
}

export class ToggleOnlineDto {
  // Always explicit. Fleetbase's toggle-online will flip the current value if
  // `online` is omitted, which would desync on a retried request.
  @IsBoolean()
  online: boolean;
}

export class UpdateActivityDto {
  // A full Activity object taken from the order config, not a status string —
  // that is what POST /v1/orders/{id}/update-activity validates against.
  @IsObject()
  activity: Record<string, any>;

  @IsOptional()
  @IsString()
  proof?: string;

  /**
   * Déclaration d'encaissement, exigée quand l'activité est terminale et que la
   * livraison est payée à la réception.
   *
   * Portée ici et non sur une route séparée parce que **c'est ce chemin que
   * l'application emprunte réellement** pour clôturer : elle suit les
   * transitions proposées par le serveur. Une garde posée sur le seul
   * `POST /terminer` aurait été décorative.
   */
  @IsOptional()
  @ValidateNested()
  @Type(() => CashCollectionDto)
  cash?: CashCollectionDto;
}

/**
 * Short, delivery-specific list from docs/specs_app_transporteur.md §4.3 —
 * deliberately not Navigator's 9 generic fleet-ops incident categories.
 * Marked there as "to validate with the business side", so treat this as a
 * starting point rather than settled.
 */
export const DELIVERY_FAILURE_REASONS = [
  'client_absent',
  'adresse_introuvable',
  'colis_refuse',
  'colis_endommage',
  'acces_impossible',
  'autre',
] as const;

/**
 * ~7 Mo de base64 ≈ 5 Mo d'image — au-delà, la borne HTTP de main.ts
 * (MAX_REQUEST_BODY) rendrait un 413 opaque. Refuser ici donne une erreur de
 * validation lisible, et empêche de garder en mémoire une charge non bornée.
 */
export const MAX_PHOTO_BASE64_LENGTH = 7_000_000;

export class ReportDeliveryFailureDto {
  @IsIn(DELIVERY_FAILURE_REASONS as unknown as string[])
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  notes?: string;

  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, {
    message: 'waypointUuid doit être un identifiant Fleetbase valide',
  })
  waypointUuid?: string;

  // Base64-encoded image. The Fleetbase capture-photo controller accepts
  // base64 strings as well as multipart uploads, which keeps this a plain
  // JSON endpoint.
  @IsOptional()
  @IsString()
  @MaxLength(MAX_PHOTO_BASE64_LENGTH, {
    message: 'Photo trop volumineuse (5 Mo maximum)',
  })
  photo?: string;
}

/**
 * Motifs de refus d'une course.
 *
 * ── Pourquoi cette liste-là ─────────────────────────────────────────────────
 *
 * Chaque entrée désigne un **paramètre de la course** que la plateforme peut
 * corriger, pas un état d'humeur. C'est ce qui la rend exploitable : un
 * « prix_insuffisant » récurrent sur les trajets longs dit quelque chose du
 * barème à écrire, un « creneau_impossible » massif à 18 h dit quelque chose
 * de la couverture du réseau.
 *
 * `indisponible` est la soupape : sans elle, un transporteur qui refuse
 * simplement parce qu'il finit sa journée choisirait un motif au hasard, et
 * empoisonnerait les quatre autres. Une catégorie « aucune information » qu'on
 * sait ignorer vaut mieux qu'une donnée fausse qu'on croit lire.
 */
export const DECLINE_REASONS = [
  'prix_insuffisant',
  'trop_loin',
  'vehicule_inadapte',
  'creneau_impossible',
  'colis_inadapte',
  'indisponible',
  'autre',
] as const;

export class DeclineOrderDto {
  @IsIn(DECLINE_REASONS as unknown as string[])
  reason: string;

  @IsOptional()
  @IsString()
  @MaxLength(1000)
  notes?: string;
}

/**
 * Déclaration d'encaissement, jointe à la clôture d'une livraison payée à la
 * réception.
 *
 * Le montant est **obligatoire** sur une course encaissée : `completeOrder` la
 * refuse sans lui. En faire une étape séparée garantirait qu'elle soit oubliée,
 * et un encaissement non déclaré est exactement ce que le registre existe pour
 * empêcher.
 */
export class CashCollectionDto {
  /** Ce qui a réellement été perçu. Zéro est une valeur légitime : un client
   *  qui refuse de payer est un fait à enregistrer. */
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  @Max(500000)
  collectedAmount: number;

  /** Obligatoire dès que le montant diffère de celui annoncé — contrôlé côté
   *  service, qui seul connaît le montant attendu. */
  @IsOptional()
  @IsIn(COLLECTION_DISCREPANCY_REASONS as unknown as string[])
  discrepancyReason?: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  notes?: string;
}

/** Déclaration d'une remise d'espèces à un commerçant. */
export class DeclareRemittanceDto {
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'merchantId invalide' })
  merchantId: string;

  @Type(() => Number)
  @IsNumber()
  @Min(1)
  @Max(5000000)
  amount: number;
}

export class DisputeRemittanceDto {
  @IsOptional()
  @IsString()
  @MaxLength(500)
  reason?: string;
}

export class CapturePhotoDto {
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(5)
  @IsString({ each: true })
  @MaxLength(MAX_PHOTO_BASE64_LENGTH, {
    each: true,
    message: 'Photo trop volumineuse (5 Mo maximum)',
  })
  photos: string[];

  @IsOptional()
  @IsString()
  @MaxLength(255)
  remarks?: string;

  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, {
    message: 'subjectId doit être un identifiant Fleetbase valide',
  })
  subjectId?: string;
}

export class ListDriverOrdersQueryDto {
  @IsOptional()
  @IsString()
  status?: string;

  @IsOptional()
  @IsIn(['assigned', 'adhoc', 'history'])
  type?: string;
}

/**
 * Catégorie de véhicule déclarée par le transporteur.
 *
 * Retirer la déclaration (valeur absente) le rend à nouveau éligible à toutes
 * les courses, plutôt que de le coincer dans une catégorie définitive.
 */
export class UpdateVehicleTypeDto {
  @IsOptional()
  @IsIn(['moto', 'voiture', 'utilitaire'])
  vehicleType?: string;
}
