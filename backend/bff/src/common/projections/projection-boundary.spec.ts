/**
 * Ce qui sort d'une route ne doit JAMAIS être une commande Fleetbase brute.
 *
 * ── Pourquoi ce fichier existe (03/08/2026) ─────────────────────────────────
 *
 * `order-projection.spec.ts` vérifiait déjà que le catalogue des champs
 * personnalisés et la liste d'autorisation s'accordent — et il était vert
 * pendant que `attachFailures()` servait la commande brute au transporteur,
 * `meta.declines[]` compris (uuid Fleetbase, motif, notes libres et **prix
 * offert** de chaque transporteur ayant refusé la course).
 *
 * Les deux listes étaient d'accord. **Personne n'appelait ni l'une ni l'autre
 * sur ce chemin.** C'est la règle 8 dans sa forme la plus coûteuse : un
 * contrôle qui n'a jamais eu l'occasion de refuser, parce qu'il regardait à
 * côté de l'endroit où la donnée passe.
 *
 * Ce banc part donc de l'objet BRUT et interroge le résultat, sans rien savoir
 * de la mécanique. Il ne peut pas être satisfait par deux listes cohérentes.
 *
 * ⚠️ Il ne remplace pas les scénarios : il vérifie la FORME de ce qui sort,
 * pas qu'une route l'appelle. Le jour où un nouveau chemin oublie de projeter,
 * ce fichier restera vert — c'est sa limite, et elle est dite ici plutôt que
 * découverte plus tard.
 */
import {
  projectOrderForDriver,
  projectOrderForMerchant,
  projectOrderForFleet,
} from './order.projection';

/**
 * Une commande telle que Fleetbase la sert vraiment, avec tout ce qui ne doit
 * pas sortir. Les valeurs sont reconnaissables : un test qui échoue doit dire
 * *quoi* a fui, pas seulement qu'il a fui.
 */
const COMMANDE_BRUTE = {
  uuid: 'ord_uuid',
  public_id: 'order_abc',
  status: 'completed',
  proof_url: 'https://fleetbase.interne/storage/preuve-SECRETE.jpg',
  // ⚠️ Ces trois-là sont des RATTACHEMENTS, pas des interdits : ils sortent
  // délibérément vers le transporteur **assigné** (il a besoin du sien) et vers
  // l'entreprise (elle réaffecte). Ils sont retirés d'une course libre et du
  // commerçant. Le test dédié plus bas l'exige dans les deux sens — sans quoi
  // « aucune fuite » serait aussi satisfait par une projection qui les retire
  // partout, et l'app perdrait de quoi fonctionner sans que rien ne le dise.
  driver_assigned_uuid: 'driver_LIEN',
  customer_uuid: 'contact_LIEN',
  facilitator_uuid: 'vendor_LIEN',
  company_uuid: 'company_UUID_A_NE_PAS_SORTIR',
  custom_field_values: [{ value: 'BRUT_A_NE_PAS_SORTIR' }],
  driver_assigned: {
    name: 'Karim B.',
    phone: '+213700000000',
    photo_url: 'https://photo',
    uuid: 'driver_LIEN',
    user: { email: 'karim@example.com' },
  },
  meta: {
    price: 500,
    cod_amount: 2500,
    declines: [
      {
        driver_uuid: 'driver_UUID_CONCURRENT',
        reason: 'trop_loin',
        notes: 'NOTE_LIBRE_D_UN_CONCURRENT',
        offered_price: 450,
      },
    ],
    delivery_failures: [
      {
        id: 'f1',
        reason: 'client_absent',
        proof_url: 'https://fleetbase.interne/storage/preuve-SECRETE.jpg',
        reported_at: '2026-08-03T10:00:00Z',
      },
    ],
  },
  payload: {
    pickup: { address: '12 rue X', name: 'Boulangerie', phone: '+213600000000' },
    dropoff: { address: '5 rue Y', name: 'Client', phone: '+213611111111' },
  },
};

/** Tout ce qui, apparaissant n'importe où dans la réponse, est une fuite. */
const INTERDITS = [
  'A_NE_PAS_SORTIR',
  'NOTE_LIBRE_D_UN_CONCURRENT',
  'driver_UUID_CONCURRENT',
  'preuve-SECRETE',
  'karim@example.com',
];

/**
 * Cherche une aiguille dans la réponse SÉRIALISÉE.
 *
 * ⚠️ Volontairement bête : parcourir les clés attendues reviendrait à
 * réécrire la liste d'autorisation dans le test, donc à vérifier qu'elle
 * s'accorde avec elle-même — exactement le défaut qui a laissé passer la fuite.
 * Un `JSON.stringify` ne présume de rien, y compris d'un champ imbriqué à un
 * niveau que personne n'avait prévu.
 */
function fuites(projection: any): string[] {
  const texte = JSON.stringify(projection ?? null);
  return INTERDITS.filter((aiguille) => texte.includes(aiguille));
}

describe('la frontière de projection', () => {
  const personas: Array<[string, (o: any) => any]> = [
    ['transporteur', (o) => projectOrderForDriver(o)],
    ['transporteur (course libre)', (o) => projectOrderForDriver(o, { unclaimed: true })],
    ['commerçant', (o) => projectOrderForMerchant(o)],
    ['entreprise', (o) => projectOrderForFleet(o)],
  ];

  it.each(personas)('ne laisse rien fuir vers le %s', (_nom, projeter) => {
    expect(fuites(projeter(COMMANDE_BRUTE))).toEqual([]);
  });

  /**
   * ⚠️ **Le banc doit prouver qu'il sait refuser** (règle 8). Sans ce cas, un
   * `fuites()` cassé — une aiguille mal orthographiée, un `stringify` qui
   * échoue — rendrait `[]` pour tout le monde et le fichier serait vert en ne
   * regardant rien.
   *
   * C'est exactement la panne qu'on répare : un contrôle vert par aveuglement.
   */
  it('REFUSE la commande brute — sinon il ne regarde rien', () => {
    const sansProjection = fuites(COMMANDE_BRUTE);

    expect(sansProjection.length).toBeGreaterThan(0);
    expect(sansProjection).toContain('NOTE_LIBRE_D_UN_CONCURRENT');
    expect(sansProjection).toContain('preuve-SECRETE');
  });

  /**
   * Le pendant utile : ce que la projection doit CONSERVER. Une projection qui
   * rendrait `{}` passerait tous les tests ci-dessus.
   */
  it('conserve ce dont chaque application a besoin', () => {
    const transporteur: any = projectOrderForDriver(COMMANDE_BRUTE);
    expect(transporteur.meta.cod_amount).toBe(2500);
    expect(transporteur.meta.price).toBe(500);

    const commercant: any = projectOrderForMerchant(COMMANDE_BRUTE);
    expect(commercant.driver_assigned.name).toBe('Karim B.');
    expect(commercant.driver_assigned.phone).toBe('+213700000000');
    expect(commercant.status).toBe('completed');
  });

  /**
   * Les rattachements suivent l'ENGAGEMENT, pas le persona.
   *
   * ⚠️ Ce test existe parce que le précédent ne suffit pas : une projection qui
   * retirerait `driver_assigned_uuid` **partout** ne laisserait rien fuir et
   * casserait quand même la réaffectation côté entreprise, en silence. « Ne
   * fuit pas » et « sert ce qu'il faut » sont deux questions.
   */
  it('expose les rattachements à qui en a besoin, et à personne d’autre', () => {
    const assigne: any = projectOrderForDriver(COMMANDE_BRUTE);
    const libre: any = projectOrderForDriver(COMMANDE_BRUTE, { unclaimed: true });
    const entreprise: any = projectOrderForFleet(COMMANDE_BRUTE);
    const commercant: any = projectOrderForMerchant(COMMANDE_BRUTE);

    // Le transporteur qui tient la course a le sien ; l'entreprise réaffecte.
    expect(assigne.driver_assigned_uuid).toBe('driver_LIEN');
    expect(entreprise.driver_assigned_uuid).toBe('driver_LIEN');

    // Une course libre n'en donne aucun (défaut D5) ; le commerçant reçoit le
    // NOM de son transporteur, jamais son identifiant Fleetbase.
    expect(libre.driver_assigned_uuid).toBeUndefined();
    expect(libre.customer_uuid).toBeUndefined();
    expect(commercant.driver_assigned_uuid).toBeUndefined();
  });
});
