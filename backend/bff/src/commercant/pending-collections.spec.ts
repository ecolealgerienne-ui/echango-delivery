import { projectOrderForMerchant } from '../common/projections/order.projection';

/**
 * Ce que « en attente d'encaissement » lit sur une commande.
 *
 * Le calcul lui-même vit dans `CommerçantService.pendingCollections()` et
 * dépend de Prisma et de Fleetbase. Ce qui se teste ici sans les deux, c'est la
 * seule chose qui a réellement failli : **la projection sert-elle les champs
 * que la lecture consomme ?**
 *
 * La projection est une liste d'autorisation. Un champ absent ne lève rien : il
 * arrive `undefined`, et le montant attendu devient 0 ou le transporteur
 * « inconnu » — silencieusement. C'est le mode d'échec récurrent du projet,
 * et il ne se voit qu'à l'écran.
 */
describe('pendingCollections — les champs lus existent bien', () => {
  // Forme relevée sur une vraie commande Fleetbase (int/v1), réduite aux
  // champs que la lecture consomme.
  const live = {
    uuid: 'ord-1',
    status: 'dispatched',
    scheduled_at: '2026-07-31T09:00:00Z',
    meta: { cod_amount: 1950, price: 650 },
    driver_assigned: { uuid: 'drv-1', name: 'Driver Bob1', phone: '+213555' },
    payload: {
      pickup: { uuid: 'p1', name: 'Boulangerie' },
      dropoff: { uuid: 'p2', name: 'Client Test' },
    },
  };

  const projected: any = projectOrderForMerchant(live, { bff_order_id: 'cms7' });

  it('sert le montant à encaisser', () => {
    expect(Number(projected.meta?.cod_amount)).toBe(1950);
  });

  it('sert le statut, qui décide de l\'inclusion', () => {
    expect(projected.status).toBe('dispatched');
  });

  it('sert le nom du transporteur — sans lui, « en cours » ne se distingue pas de « personne ne l\'a prise »', () => {
    expect(projected.driver_assigned?.name).toBe('Driver Bob1');
  });

  it('sert le nom du point de livraison, seul repère pour reconnaître la course', () => {
    expect(projected.payload?.dropoff?.name).toBe('Client Test');
  });

  it('sert scheduled_at et l\'identifiant local', () => {
    expect(projected.scheduled_at).toBe('2026-07-31T09:00:00Z');
    expect(projected.bff_order_id).toBe('cms7');
  });

  it('ne laisse pas fuiter l\'uuid du transporteur au commerçant', () => {
    // Garde de régression : la projection commerçant retire délibérément
    // l'identifiant technique (revue M10). L'écran d'encaissement n'en a pas
    // besoin, et l'ajouter « parce qu'il est là » rouvrirait la fuite.
    expect(projected.driver_assigned?.uuid).toBeUndefined();
  });

  it('un montant à encaisser absent vaut zéro, jamais NaN', () => {
    const sans: any = projectOrderForMerchant({ ...live, meta: {} });
    expect(Number(sans.meta?.cod_amount) > 0).toBe(false);
  });
});
