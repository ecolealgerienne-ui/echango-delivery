/**
 * Motifs d'écart entre le montant annoncé et le montant perçu.
 *
 * ── Pourquoi un fichier de constantes, et non le service ─────────────────────
 *
 * Les DTO en ont besoin pour valider, et un DTO qui importe un service tire
 * derrière lui Prisma, la configuration et les notifications — pour une simple
 * liste de chaînes. C'est ce qui a fait tomber le démarrage le 29/07 : le
 * graphe d'import des DTO passait par `cash.service`, et une évaluation
 * anticipée a suffi à le casser. Une constante partagée n'a pas de dépendance,
 * donc pas de cycle possible.
 *
 * Liste fermée, comme les motifs de refus et d'échec : un champ libre ne se
 * compte pas, et c'est justement le comptage qui remplace l'enquête au dépôt.
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
