/**
 * Ce qu'une course « libre » veut dire, pour les deux populations à la fois.
 *
 * ── Pourquoi ce test, et ce qu'il aurait attrapé ──────────────────────────
 *
 * Les deux prédicats de disponibilité — `isClaimable` côté entreprise,
 * `isClaimableAdhoc` côté transporteur — étaient identiques **caractère pour
 * caractère**, et on l'avait vérifié. Mais on avait vérifié qu'ils s'accordaient
 * entre eux, pas qu'ils avaient raison : tous deux excluaient `canceled` et
 * **pas `completed`**.
 *
 * Résultat constaté à l'écran le 31/07/2026 : une course avec le statut
 * « Livrée » figurait dans « Courses libres », avec un bouton « Prendre cette
 * course ». Terminer une course n'efface pas `adhoc`, donc rien d'autre ne
 * l'excluait.
 *
 * La leçon est celle qui revient : **deux copies d'accord ne prouvent rien**.
 * D'où la définition unique testée ici, et la reproduction du prédicat complet
 * pour couvrir la règle et non seulement la constante.
 */

import {
  isOrderClaimable as isClaimable,
  isTerminalOrderStatus,
  TERMINAL_ORDER_STATUSES,
} from './order-status';

// ⚠️ Ce fichier contenait une **troisième copie** du prédicat, « reproduction
// fidèle » pour contourner la dépendance à Prisma des deux services. Un test
// qui recopie ce qu'il vérifie ne vérifie que lui-même : il serait resté vert
// pendant que les vrais prédicats divergeaient. Depuis l'extraction dans
// `isOrderClaimable`, il importe celui que le code exécute.

describe('les statuts qui mettent fin à une course', () => {
  it('reconnaît les DEUX orthographes de Fleetbase', () => {
    // `canceled` et `cancelled` circulent tous deux selon les chemins amont.
    // N'en reconnaître qu'une laissait une course annulée passer pour vivante.
    expect(isTerminalOrderStatus('canceled')).toBe(true);
    expect(isTerminalOrderStatus('cancelled')).toBe(true);
    expect(isTerminalOrderStatus('completed')).toBe(true);
  });

  it('répond NON sur un statut absent ou inconnu', () => {
    // Bon côté de l'erreur pour un prédicat de disponibilité : une course dont
    // on ignore l'état ne doit pas devenir invisible.
    expect(isTerminalOrderStatus(undefined)).toBe(false);
    expect(isTerminalOrderStatus(null)).toBe(false);
    expect(isTerminalOrderStatus('preparing')).toBe(false);
    expect(isTerminalOrderStatus(42)).toBe(false);
  });
});

describe('une course terminée n’est jamais réclamable', () => {
  const free: any = { adhoc: true, driver_assigned_uuid: null, facilitator_uuid: null };

  it('exclut une course livrée — le défaut vu à l’écran', () => {
    expect(isClaimable({ ...free, status: 'completed' })).toBe(false);
  });

  it('exclut une course annulée, quelle que soit l’orthographe', () => {
    for (const status of ['canceled', 'cancelled']) {
      expect(isClaimable({ ...free, status })).toBe(false);
    }
  });

  it('couvre tous les statuts terminaux, y compris ceux ajoutés plus tard', () => {
    // Ce test ne teste pas une liste figée : il parcourt la constante. Un statut
    // terminal ajouté à la source est donc automatiquement couvert, et ne peut
    // pas rester réclamable par oubli.
    for (const status of TERMINAL_ORDER_STATUSES) {
      expect(isClaimable({ ...free, status })).toBe(false);
    }
  });
});

describe('ce qui reste réclamable', () => {
  it('une course diffusée, sans conducteur ni entreprise', () => {
    expect(
      isClaimable({ adhoc: true, status: 'dispatched' }),
    ).toBe(true);
  });

  it('mais pas si elle est retirée de la diffusion', () => {
    expect(isClaimable({ adhoc: false, status: 'dispatched' })).toBe(false);
  });

  it('ni si quelqu’un s’en occupe déjà', () => {
    expect(
      isClaimable({ adhoc: true, status: 'dispatched', driver_assigned_uuid: 'd1' }),
    ).toBe(false);
    expect(
      isClaimable({ adhoc: true, status: 'dispatched', facilitator_uuid: 'v1' }),
    ).toBe(false);
  });

  // ⚠️ Le cas qui manquait, et qui s'est produit en réel (02/08/2026).
  //
  // Une course **démarrée mais sans conducteur assigné** passait le prédicat :
  // elle est `adhoc`, elle n'a pas de conducteur, elle n'est pas terminale.
  // L'onglet « Opportunités » l'offrait donc avec un bouton « Accepter », et
  // Fleetbase refusait — `400 Order has already started`. Le transporteur
  // recevait un message d'erreur brut là où il croyait prendre du travail.
  it('ni si elle a déjà commencé, même sans conducteur assigné', () => {
    expect(isClaimable({ adhoc: true, status: 'started' })).toBe(false);
    expect(isClaimable({ adhoc: true, status: 'enroute' })).toBe(false);
    expect(isClaimable({ adhoc: true, status: 'driver_enroute' })).toBe(false);
  });

  // Le biais du fichier est conservé, et il est délibéré : un statut que nous
  // ne connaissons pas ne doit pas faire **disparaître** du travail en silence.
  // Mieux vaut une course offerte puis refusée qu'une course jamais montrée.
  it('mais un statut inconnu reste offert — l’absence ne doit pas cacher', () => {
    expect(isClaimable({ adhoc: true, status: 'un_statut_que_fleetbase_inventera' }))
      .toBe(true);
  });
});
