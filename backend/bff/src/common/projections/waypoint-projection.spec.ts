/**
 * Ce que le BFF sert d'une **tournée** (`payload.waypoints[]`), et ce qu'il
 * retire arrêt par arrêt (spec §4).
 *
 * Même règle qu'une course 1→1 : l'enlèvement est un commerce et passe en
 * entier ; un arrêt de livraison non engagé perd l'identité de son destinataire
 * — nom et téléphone —, jamais son adresse ni sa position. La nouveauté est que
 * la règle s'applique **par arrêt** : une tournée diffusée ne doit trahir aucun
 * des N destinataires.
 */

import { projectOrderForDriver, projectOrderForFleet } from './order.projection';

const tournee = (): any => ({
  uuid: 'ord-t1',
  public_id: 'order_tournee',
  status: 'created',
  adhoc: false,
  meta: { price: 3000, currency: 'DZD', is_tournee: true, stop_count: 3 },
  payload: {
    pickup: null,
    dropoff: null,
    // Forme d'une **requête interne** (`/int/v1`, celle du BFF) : les waypoints
    // portent `uuid`/`public_id` ; les colis portent `destination_uuid`.
    waypoints: [
      {
        id: 42,
        uuid: 'place_pick',
        public_id: 'place_ABC',
        name: 'Entrepôt Est',
        type: 'pickup',
        status: 'created',
        complete: false,
        order: 0,
        street1: 'Zone industrielle',
        city: 'Alger',
        province: 'Alger',
        phone: '021000000',
        location: { type: 'Point', coordinates: [3.1, 36.75] },
        // Champs bruts hors liste d'autorisation — ne doivent pas sortir.
        waypoint_public_id: 'waypoint_xyz',
        customer_uuid: 'contact_leak',
        security_access_code: 'B1742',
        customer: { name: 'Client interne', phone: '0770000000' },
      },
      {
        id: 43,
        uuid: 'place_d1',
        public_id: 'place_D1',
        name: 'Mme Yasmine',
        type: 'dropoff',
        status: 'created',
        complete: false,
        order: 1,
        street1: '4 rue des Oliviers',
        city: 'Blida',
        province: 'Blida',
        postal_code: '09000',
        phone: '0661112233',
        location: { type: 'Point', coordinates: [2.83, 36.47] },
        customer: { name: 'Mme Yasmine', phone: '0661112233' },
      },
      {
        id: 44,
        uuid: 'place_d2',
        public_id: 'place_D2',
        name: 'M. Karim',
        type: 'dropoff',
        status: 'created',
        complete: false,
        order: 2,
        street1: '17 lot Bounab',
        city: 'Tipaza',
        province: 'Tipaza',
        phone: '0770445566',
        location: { type: 'Point', coordinates: [2.44, 36.59] },
      },
    ],
    entities: [
      {
        id: 7,
        uuid: 'entity_1_uuid',
        public_id: 'entity_1',
        name: 'Colis A',
        description: 'Documents',
        destination_uuid: 'place_d1',
        type: 'entity',
        meta: { stop_index: 1 },
        customer_uuid: 'leak-me',
        payload_uuid: 'leak-payload',
      },
      {
        id: 8,
        uuid: 'entity_2_uuid',
        public_id: 'entity_2',
        name: 'Colis B',
        destination_uuid: 'place_d2',
        type: 'entity',
        meta: { stop_index: 2 },
      },
    ],
  },
});

describe('tournée non réclamée', () => {
  const project = (o: any) => projectOrderForDriver(o, { unclaimed: true }) as any;

  it('sert les arrêts sous forme de liste ordonnée', () => {
    const wps = project(tournee()).payload.waypoints;
    expect(wps).toHaveLength(3);
    expect(wps.map((w: any) => w.order)).toEqual([0, 1, 2]);
    expect(wps.map((w: any) => w.type)).toEqual(['pickup', 'dropoff', 'dropoff']);
  });

  it('retire nom et téléphone des arrêts de LIVRAISON, garde leur adresse', () => {
    const [, d1] = project(tournee()).payload.waypoints;
    expect(d1).not.toHaveProperty('name');
    expect(d1).not.toHaveProperty('phone');
    expect(d1.address).toContain('rue des Oliviers');
    expect(d1.location).toEqual({ type: 'Point', coordinates: [2.83, 36.47] });
    expect(d1.status).toBe('created');
    expect(d1.order).toBe(1);
  });

  it("sert l'arrêt d'ENLÈVEMENT en entier — c'est un commerce", () => {
    const [pickup] = project(tournee()).payload.waypoints;
    expect(pickup.name).toBe('Entrepôt Est');
    expect(pickup.phone).toBe('021000000');
  });

  it('garde l’uuid de l’arrêt (rattachement des colis, mise à jour d’activité)', () => {
    const [, d1] = project(tournee()).payload.waypoints;
    expect(d1.uuid).toBe('place_d1');
  });

  it('projette l’arrêt en cours quand Fleetbase le suit', () => {
    const withCurrent = tournee();
    withCurrent.payload.current_waypoint_uuid = 'place_d1';
    expect(project(withCurrent).payload.current_waypoint_uuid).toBe('place_d1');
    // Absent quand Fleetbase ne le pose pas (tournée pas démarrée).
    expect(project(tournee()).payload).not.toHaveProperty('current_waypoint_uuid');
  });

  it('ne laisse fuir aucun champ brut de waypoint', () => {
    const json = JSON.stringify(project(tournee()).payload.waypoints);
    expect(json).not.toContain('waypoint_xyz');
    expect(json).not.toContain('security_access_code');
    expect(json).not.toContain('Client interne');
    expect(json).not.toContain('contact_leak');
  });

  it('projette les colis avec leur arrêt de destination, sans identité', () => {
    const entities = project(tournee()).payload.entities;
    expect(entities).toHaveLength(2);
    expect(entities[0]).toMatchObject({
      name: 'Colis A',
      description: 'Documents',
      destination_uuid: 'place_d1',
    });
    expect(entities[0].meta.stop_index).toBe(1);
    expect(entities[0]).not.toHaveProperty('customer_uuid');
    expect(entities[0]).not.toHaveProperty('payload_uuid');
  });
});

describe('tournée engagée', () => {
  it('rend le contact de chaque arrêt une fois la course prise', () => {
    const wps = (projectOrderForDriver(tournee(), { unclaimed: false }) as any)
      .payload.waypoints;
    expect(wps[1].name).toBe('Mme Yasmine');
    expect(wps[1].phone).toBe('0661112233');
  });
});

describe('parité des deux populations sur une tournée', () => {
  it('sert le même payload à un indépendant et à une entreprise', () => {
    const driver = projectOrderForDriver(tournee(), { unclaimed: true }) as any;
    const fleet = projectOrderForFleet(tournee(), {}, { unclaimed: true }) as any;
    // Règle 1 : deux niveaux de détail pour la même tournée libre seraient le
    // « second vocabulaire » interdit.
    expect(driver.payload).toEqual(fleet.payload);
  });
});
