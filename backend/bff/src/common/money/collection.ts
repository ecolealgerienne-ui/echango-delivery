import { badRequest } from '../errors/http-errors';

/**
 * L'encaissement à la porte : ce que le transporteur déclare avoir perçu.
 *
 * ── Ce que ce module est, et ce qu'il n'est plus ────────────────────────────
 *
 * Un **fait de livraison**, au même titre que la photo de preuve — pas une
 * écriture comptable. La plateforme enregistre ce qui s'est passé à la porte
 * et le rend lisible ; elle ne tient aucun solde, ne suit aucune dette et ne
 * réclame aucune remise. Tenir des soldes est de la trésorerie, et détenir des
 * fonds pour compte de tiers est une activité réglementée qu'un agrégateur
 * n'exerce pas (décision produit du 03/08/2026, motif complet dans
 * `docs/registre_caisse_precis.md`).
 *
 * Le registre qui faisait tout cela a existé, a tourné contre un vrai
 * Fleetbase, et est figé sous le tag `registre-caisse-v1`.
 *
 * ── Pourquoi la validation vit ici plutôt que dans le service ───────────────
 *
 * Elle est la seule partie de l'ancien registre qui portait une règle et non
 * une écriture. Isolée, elle n'importe ni Prisma ni la configuration : elle
 * s'éprouve donc directement, sans décor, ce que la version précédente ne
 * permettait pas (elle était une méthode privée d'un service de 1 968 lignes,
 * et n'avait aucun test propre).
 */

/**
 * Motifs d'écart entre le montant annoncé et le montant perçu.
 *
 * Liste fermée, comme les motifs de refus et d'échec : un champ libre ne se
 * compte pas, et c'est le comptage qui remplace l'enquête au dépôt.
 *
 * Ce que chacun désigne est un fait constaté à la porte, pas une appréciation :
 * « le client n'avait pas la somme » se vérifie, « le client était de mauvaise
 * foi » ne se vérifie pas.
 */
export const COLLECTION_DISCREPANCY_REASONS = [
  /** Le destinataire n'avait pas la totalité. */
  'somme_incomplete',
  /** Le destinataire refuse de payer, colis repris ou laissé. */
  'refus_de_payer',
  /** Ni le transporteur ni le client n'avaient de monnaie. */
  'pas_de_monnaie',
  /** Le montant annoncé ne correspondait pas à ce qui avait été convenu. */
  'montant_conteste',
  'autre',
] as const;

export type CollectionDiscrepancyReason = (typeof COLLECTION_DISCREPANCY_REASONS)[number];

/**
 * Le montant déclaré est-il recevable au regard de ce qui était annoncé ?
 *
 * Rend le montant arrondi au centime, ou refuse. Les trois refus sont des
 * codes, jamais des messages nus (règle 3) : l'application choisit sa
 * traduction, y compris en arabe.
 *
 * ⚠️ **Zéro est une valeur légitime.** Un client qui refuse de payer est un
 * fait à enregistrer, pas une erreur de saisie — c'est même le fait que la
 * déclaration existe pour capturer. Le refus porte sur le négatif, qui ne
 * décrit rien de réel.
 */
export function assertCollectedAmount(
  collectedAmount: number,
  expectedAmount: number,
  discrepancyReason: string | null | undefined,
  currency: string,
): number {
  const collected = Math.round(collectedAmount * 100) / 100;

  if (!Number.isFinite(collected) || collected < 0) {
    badRequest('cash.amount_negative', 'Le montant encaissé ne peut pas être négatif');
  }

  if (collected > expectedAmount) {
    // Un transporteur qui perçoit plus que dû n'est pas un cas à absorber en
    // silence : soit le montant annoncé était faux, soit la déclaration l'est.
    // Les deux appellent une correction humaine.
    badRequest(
      'cash.amount_exceeds_expected',
      `Montant supérieur à ce qui était annoncé (${expectedAmount} ${currency}). ` +
        'Contactez Echango si le montant à encaisser était incorrect.',
    );
  }

  if (collected !== expectedAmount && !discrepancyReason) {
    badRequest(
      'cash.discrepancy_reason_required',
      'Un écart entre le montant annoncé et le montant perçu exige un motif',
    );
  }

  return collected;
}
