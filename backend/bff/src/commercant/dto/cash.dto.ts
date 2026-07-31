import { IsIn, IsNumber, IsOptional, IsString, Matches, Max, MaxLength, Min } from 'class-validator';
import { COLLECTION_DISCREPANCY_REASONS } from '../../cash/cash.constants';
import { Type } from 'class-transformer';
import { FLEETBASE_ID_PATTERN } from '../../common/pipes/fleetbase-id.pipe';

/**
 * Remise déclarée par le commerçant : « j'ai reçu X de ce transporteur ».
 *
 * Le sens de déclaration n'est pas imposé — celui qui a son téléphone en main
 * au moment où l'argent change de mains n'est pas toujours le même. Quel que
 * soit le déclarant, c'est l'autre partie qui confirme.
 */
export class MerchantRemittanceDto {
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'driverId invalide' })
  driverId: string;

  @Type(() => Number)
  @IsNumber()
  @Min(1)
  @Max(5000000)
  amount: number;
}


/**
 * Régularisation : « ce transporteur a bien encaissé X sur cette livraison ».
 *
 * Sert le cas d'une course clôturée hors application — depuis la console
 * Fleetbase — qui ne laisse aucun encaissement au registre.
 *
 * ⚠️ Cette déclaration n'établit rien à elle seule : elle attend la
 * confirmation du transporteur, faute de quoi un commerçant pourrait inventer
 * une créance sur quelqu'un d'autre.
 */
export class DeclareMissingCollectionDto {
  @Type(() => Number)
  @IsNumber()
  @Min(0)
  @Max(500000)
  collectedAmount: number;

  /**
   * Uuid Fleetbase du transporteur, obligatoire uniquement quand la livraison
   * n'en porte aucun — cas réel, observé sur une course livrée. Ignoré sinon :
   * si la course en désigne un, c'est lui qui fait foi, et accepter une autre
   * désignation permettrait d'imputer un encaissement à un tiers.
   *
   * L'uuid **Fleetbase** et non l'identifiant du compte Echango : c'est
   * l'annuaire que le commerçant consulte (`/transporteurs/recherche`), et
   * c'est déjà la clé qu'utilise `AddFavouriteDto`.
   */
  @IsOptional()
  @IsString()
  @Matches(FLEETBASE_ID_PATTERN, { message: 'fleetbaseDriverUuid invalide' })
  fleetbaseDriverUuid?: string;

  /** Exigé par le service dès que le montant diffère de celui annoncé. */
  @IsOptional()
  @IsIn(COLLECTION_DISCREPANCY_REASONS as unknown as string[])
  discrepancyReason?: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  notes?: string;
}
