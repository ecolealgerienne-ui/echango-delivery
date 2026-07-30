import { projectOrderForMerchant } from '../common/projections/order.projection';
import { EXPECTS_CASH_AT_DOOR } from './cash-expectation';

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

/**
 * Quels statuts comptent comme « argent attendu à une porte ».
 *
 * ── Ce que ce test répare ───────────────────────────────────────────────────
 *
 * La première version filtrait « tout sauf terminé et annulé », et comptait
 * donc les **brouillons** : constaté à l'écran, deux commandes jamais publiées
 * annoncées comme 2400 DZD à encaisser. Un brouillon n'engage personne — il
 * peut être supprimé, modifié, jamais publié.
 *
 * La règle testée ici n'est pas « exclure created » mais **la fermeture de la
 * liste** : un statut inconnu ne compte pas. C'est le seul énoncé qui protège
 * du prochain statut qu'on ne connaît pas encore.
 */
describe('les statuts qui comptent', () => {
  // Importée, jamais recopiée : une liste de statuts dupliquée dans un test
  // passe au vert en décrivant une règle que le code n'applique plus.
  const counts = (status: string) => EXPECTS_CASH_AT_DOOR.includes(status);

  it('ne compte PAS un brouillon : rien n\'a été publié, personne n\'ira à aucune porte', () => {
    expect(counts('created')).toBe(false);
  });

  it('compte une course publiée, même sans transporteur : elle est diffusée et engagée', () => {
    expect(counts('dispatched')).toBe(true);
  });

  it('compte une course démarrée ou en route', () => {
    expect(counts('started')).toBe(true);
    expect(counts('enroute')).toBe(true);
  });

  it('ne compte pas une course terminée — son argent est au registre — ni annulée', () => {
    expect(counts('completed')).toBe(false);
    expect(counts('canceled')).toBe(false);
    expect(counts('cancelled')).toBe(false);
  });

  it('ne compte pas un statut inconnu, et c\'est le sens d\'échec voulu', () => {
    // Oublier un montant réel se voit dans la liste des livraisons ; en
    // annoncer un imaginaire ne se voit nulle part.
    expect(counts('on_hold')).toBe(false);
    expect(counts('')).toBe(false);
  });

  it('`completed` n\'est pas « attendu », il est traité à part', () => {
    // Une livraison terminée n'attend plus rien à une porte. Si son
    // encaissement manque, c'est une **anomalie**, servie dans `unrecorded` —
    // la ranger avec l'attendu masquerait qu'elle appelle un appel
    // téléphonique et non de la patience.
    expect(counts('completed')).toBe(false);
  });
});
