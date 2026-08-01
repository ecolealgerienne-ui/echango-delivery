import { IsNumber, IsPositive, IsString, MaxLength, MinLength } from 'class-validator';

/**
 * Déclaration d'une remise par une entreprise de transport.
 *
 * ── Pourquoi `counterpartyId` et non `merchantId` ──────────────────────────
 *
 * Une entreprise fait face à **deux** contreparties, dans les deux sens : elle
 * reçoit les espèces de ses conducteurs, et elle les reverse aux commerçants.
 * Nommer le champ `merchantId` aurait forcé le premier cas dans un mot qui le
 * décrit mal — et c'est exactement le défaut qui a rendu la chaîne interne
 * inexprimable au départ (`docs/specs_facilitateur.md` §7.3).
 *
 * Les routes transporteur et commerçant gardent leurs noms d'origine, gelés par
 * le contrôle de référence ; celle-ci est neuve et n'a aucune raison d'hériter
 * d'un vocabulaire à deux acteurs.
 */
export class FleetRemittanceDto {
  @IsString()
  @MinLength(1)
  @MaxLength(64)
  counterpartyId: string;

  @IsNumber()
  @IsPositive()
  amount: number;
}
