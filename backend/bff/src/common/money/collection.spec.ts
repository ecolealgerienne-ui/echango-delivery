import { HttpException } from '@nestjs/common';

import { COLLECTION_DISCREPANCY_REASONS, assertCollectedAmount } from './collection';

/**
 * La déclaration d'encaissement à la porte.
 *
 * ── Pourquoi ces cas n'existaient pas avant ─────────────────────────────────
 *
 * Cette règle était une méthode privée du registre de caisse, donc atteignable
 * seulement à travers Prisma, la configuration et les notifications. Elle
 * n'avait aucun test propre : les seuls qui la traversaient passaient par des
 * scénarios shell contre un vrai Fleetbase, où un refus se lit dans un code
 * HTTP et non dans une règle. Sortie du service, elle s'éprouve directement.
 *
 * ⚠️ Autant de cas qui doivent **refuser** que de cas qui doivent passer
 * (règle 8) : un validateur qu'on n'a jamais vu dire non n'a montré que sa
 * capacité à dire oui.
 */
describe('le montant encaissé déclaré', () => {
  const refus = (fn: () => unknown): string => {
    try {
      fn();
    } catch (error) {
      if (error instanceof HttpException) {
        return (error.getResponse() as any)?.code ?? '(sans code)';
      }
      return `(pas une HttpException : ${error})`;
    }
    return '(aucun refus)';
  };

  describe('ce qui passe', () => {
    it('le montant exact, sans motif', () => {
      expect(assertCollectedAmount(2727, 2727, null, 'DZD')).toBe(2727);
    });

    it('un montant inférieur AVEC motif', () => {
      expect(assertCollectedAmount(2700, 2727, 'somme_incomplete', 'DZD')).toBe(2700);
    });

    it('ZÉRO avec motif — un client qui refuse de payer est un fait', () => {
      // Le cas que la déclaration existe pour capturer. Le refuser rendrait la
      // livraison inclôturable et pousserait le transporteur à mentir sur le
      // montant pour s'en sortir.
      expect(assertCollectedAmount(0, 2727, 'refus_de_payer', 'DZD')).toBe(0);
    });

    it('arrondit au centime', () => {
      expect(assertCollectedAmount(2726.999, 2727, 'autre', 'DZD')).toBe(2727);
    });

    it('une course sans encaissement attendu, déclarée à zéro', () => {
      expect(assertCollectedAmount(0, 0, null, 'DZD')).toBe(0);
    });
  });

  describe('ce qui DOIT être refusé', () => {
    it('un montant négatif', () => {
      expect(refus(() => assertCollectedAmount(-1, 2727, 'autre', 'DZD'))).toBe(
        'cash.amount_negative',
      );
    });

    it('un montant qui n’est pas un nombre', () => {
      // `Number('abc')` donne NaN, qui échoue toutes les comparaisons — donc
      // passerait les deux premiers contrôles sans le test de finitude, et
      // serait écrit tel quel sur la commande.
      expect(refus(() => assertCollectedAmount(NaN, 2727, 'autre', 'DZD'))).toBe(
        'cash.amount_negative',
      );
    });

    it('plus que ce qui était annoncé', () => {
      expect(refus(() => assertCollectedAmount(3000, 2727, 'autre', 'DZD'))).toBe(
        'cash.amount_exceeds_expected',
      );
    });

    it('un écart SANS motif', () => {
      expect(refus(() => assertCollectedAmount(2700, 2727, null, 'DZD'))).toBe(
        'cash.discrepancy_reason_required',
      );
    });

    it('zéro sans motif — l’écart total est un écart comme un autre', () => {
      expect(refus(() => assertCollectedAmount(0, 2727, undefined, 'DZD'))).toBe(
        'cash.discrepancy_reason_required',
      );
    });

    it('un motif vide ne vaut pas un motif', () => {
      expect(refus(() => assertCollectedAmount(2700, 2727, '', 'DZD'))).toBe(
        'cash.discrepancy_reason_required',
      );
    });
  });

  it('nomme la devise servie, jamais une devise en dur', () => {
    // Le message est lu par un humain qui décide s'il conteste. Une devise
    // codée en dur y aurait dit « USD » à un transporteur algérien — c'est le
    // défaut corrigé le 02/08/2026, sur un autre chemin.
    let message = '';
    try {
      assertCollectedAmount(3000, 2727, 'autre', 'DZD');
    } catch (error) {
      const body = (error as HttpException).getResponse() as Record<string, any>;
      message = body?.message ?? '';
    }
    expect(message).toContain('2727 DZD');
  });

  it('la liste des motifs est fermée et sans doublon', () => {
    // Un champ libre ne se compte pas ; un doublon fait diverger le DTO qui
    // valide et l'application qui traduit.
    expect(new Set(COLLECTION_DISCREPANCY_REASONS).size).toBe(
      COLLECTION_DISCREPANCY_REASONS.length,
    );
    expect(COLLECTION_DISCREPANCY_REASONS).toContain('refus_de_payer');
  });
});
