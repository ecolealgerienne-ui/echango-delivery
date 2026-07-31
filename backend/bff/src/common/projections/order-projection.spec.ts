/**
 * Ce que le BFF retire d'une course **non réclamée**, et ce qu'il garde.
 *
 * ── Pourquoi ces tests-là existent ─────────────────────────────────────────
 *
 * La règle a changé le 31/07/2026 : on masquait l'adresse de livraison, on ne
 * masque plus que l'identité du destinataire. Une règle de confidentialité qui
 * change est exactement le moment où un champ passe à travers — le motif de
 * défaut le plus répété de ce projet est « on retire ce qu'on a pensé à
 * retirer », et il ne se voit pas à l'écran : la fuite est sur le réseau.
 *
 * Ces tests fixent donc les DEUX moitiés de la règle. Ne vérifier que ce qui
 * disparaît laisserait la porte ouverte à une expurgation qui redeviendrait trop
 * large sans que rien ne le dise — c'est précisément ce qui s'est produit, et
 * qui a donné huit lignes titrées « Destinataire » sans critère de décision.
 */

import { projectOrderForDriver, projectOrderForFleet } from './order.projection';

const order = (): any => ({
  uuid: 'ord-1',
  public_id: 'order_abc',
  status: 'created',
  adhoc: true,
  notes: 'Fragile',
  distance: 4200,
  customer_uuid: 'vendor-marchand',
  facilitator_uuid: null,
  driver_assigned_uuid: null,
  meta: {
    price: 650,
    currency: 'DZD',
    cod_amount: 1950,
    instructions: 'Sonner au 3e, porte gauche',
    dropoff_notes: 'Bâtiment B, 2e étage',
    vehicle_type: 'moto',
  },
  payload: {
    pickup: {
      uuid: 'place-pickup',
      name: 'Boulangerie du centre',
      address: '12 rue Didouche Mourad, Alger',
      contact_name: 'Le gérant',
      contact_phone: '0555000111',
      location: { type: 'Point', coordinates: [3.05, 36.75] },
    },
    dropoff: {
      uuid: 'place-dropoff',
      name: 'Mme Benali',
      address: '8 rue des Frères Bouadou, Bir Mourad Raïs',
      street1: '8 rue des Frères Bouadou',
      city: 'Bir Mourad Raïs',
      postal_code: '16000',
      phone: '0661223344',
      contact_name: 'Mme Benali',
      contact_phone: '0661223344',
      location: { type: 'Point', coordinates: [3.04, 36.73] },
    },
  },
});

describe.each([
  ['transporteur', projectOrderForDriver],
  ['entreprise', (o: any, opts: any) => projectOrderForFleet(o, {}, opts)],
])('course non réclamée, vue par un %s', (_persona, project) => {
  const dropoff = () => (project(order(), { unclaimed: true }) as any).payload.dropoff;

  it("retire ce qui identifie le destinataire, et rien d'autre", () => {
    const place = dropoff();

    for (const field of ['name', 'phone', 'contact_name', 'contact_phone']) {
      expect(place).not.toHaveProperty(field);
    }
  });

  it('ne laisse pas le nom ressortir par `address`', () => {
    // ⚠️ Le défaut qui a failli passer. `Place.address` n'est pas une colonne :
    // c'est un accesseur qui recompose « nom, rue, commune, code postal ». Sur
    // le chemin de création de l'app, le lieu de livraison n'a QUE son nom —
    // `address` valait donc exactement le nom du destinataire, au-dessus d'un
    // bandeau promettant de ne pas le donner.
    const place = projectOrderForFleet(
      {
        payload: {
          dropoff: { uuid: 'p', name: 'Mme Benali', address: 'Mme Benali' },
        },
      },
      {},
      { unclaimed: true },
    ) as any;

    expect(JSON.stringify(place.payload.dropoff)).not.toContain('Benali');
    // Rien de structuré à servir ⇒ pas d'adresse inventée. L'adresse réelle est
    // dans `meta.dropoff_notes`, et la porte dans `location`.
    expect(place.payload.dropoff.address).toBeUndefined();
  });

  it('ne répète pas la wilaya quand elle porte le nom de la commune', () => {
    // Alger, Oran, Constantine, Annaba : `city` et `province` valent la même
    // chaîne, et l'adresse se terminait par sa propre fin.
    const place = projectOrderForFleet(
      {
        payload: {
          dropoff: {
            uuid: 'p',
            name: 'Toto',
            street1: 'Cité 1er Novembre',
            city: 'Alger',
            postal_code: '16000',
            province: 'Alger',
          },
        },
      },
      {},
      { unclaimed: true },
    ) as any;

    expect(place.payload.dropoff.address).toBe('Cité 1er Novembre, Alger, 16000');
  });

  it("garde l'adresse, qui est le critère de décision", () => {
    const place = dropoff();

    expect(place.address).toContain('rue des Frères Bouadou');
    expect(place.address).not.toContain('Benali');
    expect(place.street1).toBe('8 rue des Frères Bouadou');
    expect(place.city).toBe('Bir Mourad Raïs');
    // Sans coordonnées, pas d'itinéraire — donc pas de détour estimable, donc
    // aucun moyen de décider si la course vaut le déplacement.
    expect(place.location).toEqual({ type: 'Point', coordinates: [3.04, 36.73] });
  });

  it('garde les montants et les précisions d’accès', () => {
    const projected = project(order(), { unclaimed: true }) as any;

    expect(projected.meta.price).toBe(650);
    expect(projected.meta.cod_amount).toBe(1950);
    expect(projected.meta.instructions).toBe('Sonner au 3e, porte gauche');
    expect(projected.meta.dropoff_notes).toBe('Bâtiment B, 2e étage');
  });

  it('annonce le masquage, pour qu’une absence ne passe pas pour une panne', () => {
    expect((project(order(), { unclaimed: true }) as any).redacted).toBe(true);
    expect((project(order(), { unclaimed: false }) as any).redacted).toBeUndefined();
  });

  it('ne nomme aucun rattachement — donc aucun commerçant', () => {
    const projected = project(order(), { unclaimed: true }) as any;

    // La cartographie commerciale du réseau se construit en rafraîchissant une
    // liste : un identifiant de commerçant par opportunité suffit.
    expect(projected.customer_uuid).toBeUndefined();
    expect(projected.facilitator_uuid).toBeUndefined();
    expect(projected.driver_assigned_uuid).toBeUndefined();
  });

  it("sert l'enlèvement en entier — c'est un commerce, pas un domicile", () => {
    const pickup = (project(order(), { unclaimed: true }) as any).payload.pickup;

    expect(pickup.name).toBe('Boulangerie du centre');
    expect(pickup.contact_phone).toBe('0555000111');
  });

  it('rend le contact dès que la course est engagée', () => {
    const place = (project(order(), { unclaimed: false }) as any).payload.dropoff;

    expect(place.name).toBe('Mme Benali');
    expect(place.contact_phone).toBe('0661223344');
  });
});

describe('les deux populations voient la même chose', () => {
  it('sert le même niveau de détail à un indépendant et à une entreprise', () => {
    const driver = projectOrderForDriver(order(), { unclaimed: true }) as any;
    const fleet = projectOrderForFleet(order(), {}, { unclaimed: true }) as any;

    // Elles réclament la même course et décident de la même chose : deux
    // niveaux de détail seraient le « second vocabulaire » que la règle 1 du
    // projet interdit, et le moins-disant deviendrait le défaut qu'on ne
    // comprend pas. `driver_assigned` est la seule différence légitime — une
    // entreprise réaffecte, un indépendant non.
    expect(driver.payload).toEqual(fleet.payload);
    expect(driver.meta).toEqual(fleet.meta);
    expect(driver.redacted).toBe(fleet.redacted);
  });
});
