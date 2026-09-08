import { OrderCreationHelpers, TourneeInput } from './order-creation.helpers';
import { PricingService } from '../pricing/pricing.service';

/**
 * `buildTourneeMeta` — la part **pure** de la création d'une tournée (spec §4).
 *
 * Ce qui est éprouvé ici : un seul prix pour toute la route, un encaissement
 * **cumulé** aux fins du plafond de dette, le détail par arrêt conservé à part,
 * et la wilaya figée sur les deux extrémités. La création Fleetbase elle-même
 * (waypoints/entities, compensation) est couverte par le banc
 * `scripts/test-tournee-creation.sh`.
 */
const config = { get: (): undefined => undefined } as any;
const pricing = new PricingService(config);
const helpers = new OrderCreationHelpers(pricing, {} as any, {} as any);

const stop = (over: Partial<TourneeInput['stops'][number]> = {}) => ({
  placeUuid: over.placeUuid ?? 'place_x',
  type: over.type ?? 'dropoff',
  latitude: over.latitude ?? 36.75,
  longitude: over.longitude ?? 3.06,
  province: over.province,
  items: over.items,
  codAmount: over.codAmount,
  createdPlaceUuid: over.createdPlaceUuid,
  notes: over.notes,
});

const baseInput = (over: Partial<TourneeInput> = {}): TourneeInput => ({
  customerUuid: 'vendor_1',
  customerType: 'vendor',
  price: 3000,
  stops: over.stops ?? [
    stop({ placeUuid: 'p_pick', type: 'pickup', province: 'Alger' }),
    stop({ placeUuid: 'p_d1', province: 'Blida', codAmount: 1200 }),
    stop({ placeUuid: 'p_d2', province: 'Tipaza', codAmount: 800 }),
  ],
  ...over,
});

describe('buildTourneeMeta', () => {
  it('pose un seul prix pour toute la tournée', () => {
    const meta = helpers.buildTourneeMeta(baseInput())!;
    expect(meta.price).toBe(3000);
    expect(meta.is_tournee).toBe(true);
    expect(meta.stop_count).toBe(3);
  });

  it('cumule les encaissements des arrêts pour le plafond de dette', () => {
    const meta = helpers.buildTourneeMeta(baseInput())!;
    // `cod_amount` (champ personnalisé durable) = la somme, lue par le plafond.
    expect(meta.cod_amount).toBe(2000);
    expect(meta.cod_goods_amount).toBe(2000);
    // `cod_includes_delivery` vrai : rien n'est ajouté à la porte, le prix de
    // la tournée est réglé à part par le demandeur.
    expect(meta.cod_includes_delivery).toBe(true);
  });

  it('conserve le détail des encaissements par arrêt', () => {
    const meta = helpers.buildTourneeMeta(baseInput())!;
    expect(meta.stop_cod_amounts).toEqual([
      { place_uuid: 'p_d1', amount: 1200 },
      { place_uuid: 'p_d2', amount: 800 },
    ]);
  });

  it('n’écrit aucun bloc d’encaissement quand aucun arrêt n’en porte', () => {
    const meta = helpers.buildTourneeMeta(
      baseInput({
        stops: [
          stop({ placeUuid: 'a', type: 'pickup' }),
          stop({ placeUuid: 'b' }),
        ],
      }),
    )!;
    expect(meta.cod_amount).toBeUndefined();
    expect(meta.stop_cod_amounts).toBeUndefined();
  });

  it('fige la wilaya sur le premier et le dernier arrêt', () => {
    const meta = helpers.buildTourneeMeta(baseInput())!;
    expect(meta.pickup_province).toBe('Alger');
    expect(meta.dropoff_province).toBe('Tipaza');
  });
});

describe('createTournee — refus de forme', () => {
  it('refuse une tournée de moins de deux arrêts', async () => {
    await expect(
      helpers.createTournee(
        baseInput({ stops: [stop({ type: 'pickup' })] }),
      ),
    ).rejects.toMatchObject({ response: { code: 'tournee.invalid_shape' } });
  });

  it('refuse une tournée sans aucun enlèvement', async () => {
    await expect(
      helpers.createTournee(
        baseInput({
          stops: [stop({ placeUuid: 'a' }), stop({ placeUuid: 'b' })],
        }),
      ),
    ).rejects.toMatchObject({ response: { code: 'tournee.invalid_shape' } });
  });
});
