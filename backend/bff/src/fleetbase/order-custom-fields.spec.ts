import {
  FLEETBASE_OWNED_ORDER_KEYS,
  ORDER_CUSTOM_FIELDS,
  customFieldName,
  encodeCustomFieldValue,
  readOrderCustomFields,
} from './order-custom-fields';
import { effectiveOrderMeta } from '../common/projections/order.projection';

/**
 * L'aller-retour complet, simulé : ce que le BFF envoie, ce que Fleetbase
 * stocke, ce que le BFF relit.
 *
 * ── Pourquoi ce test existe ────────────────────────────────────────────────
 *
 * Le cast `CustomValue` de Fleetbase ne traite spécialement que `object` et
 * `array` ; **tout le reste est stocké en chaîne**. Un prix part en `650` et
 * revient en `"650"`. Rien ne lève d'erreur : c'est le désérialiseur Dart
 * (`as num?`) qui le lit `null`, six écrans plus loin, et le prix disparaît de
 * la fiche sans que personne sache pourquoi.
 *
 * Le piège du booléen est pire : `false` revient en `"false"`, qui est *vrai*
 * en JavaScript. Une préférence désactivée se relirait activée.
 *
 * Ce test rejoue la traversée au lieu de la supposer.
 */
const simulateFleetbaseRoundTrip = (meta: Record<string, any>) => {
  const rows: any[] = [];

  for (const definition of ORDER_CUSTOM_FIELDS) {
    const raw = meta[definition.key];
    if (raw === undefined) continue;

    const encoded = encodeCustomFieldValue(definition, raw);

    // ── Ce que fait RÉELLEMENT Fleetbase, bug compris ────────────────────
    //
    // `syncCustomFieldValues()` remplit `value` AVANT `value_type`, donc
    // `CustomValue::set()` ne voit pas encore le type et se rabat sur
    // `'text'` : il renvoie la valeur telle quelle, sans jamais l'encoder.
    //
    // La première version de ce test simulait le cast « comme il devrait
    // fonctionner » — elle passait au vert, et la première vraie commande a
    // échoué en base sur une colonne nommée `0`. Simuler le comportement
    // souhaité plutôt que le comportement réel, c'est écrire un test qui
    // valide l'hypothèse au lieu de l'éprouver.
    if (typeof encoded.value !== 'string') {
      throw new Error(
        `encodeCustomFieldValue doit toujours rendre une chaîne : `
          + `${definition.key} a rendu ${typeof encoded.value}. `
          + `Un tableau serait fusionné dans les attributs du modèle Laravel.`,
      );
    }

    const stored = encoded.value;

    // `CustomValue::get()`, lui, voit bien `value_type` puisqu'il vient de la
    // base : il désérialise pour `array`/`object`, laisse le reste en chaîne.
    const isJson = encoded.value_type === 'array' || encoded.value_type === 'object';
    const returned = isJson ? JSON.parse(stored) : stored;

    rows.push({
      custom_field: { name: customFieldName(definition.key) },
      value: returned,
    });
  }

  return rows;
};

describe('champs personnalisés de commande', () => {
  const meta = {
    price: 650,
    currency: 'DZD',
    price_source: 'merchant',
    cod_amount: 1950,
    cod_goods_amount: 1300,
    cod_currency: 'DZD',
    cod_includes_delivery: false,
    vehicle_type: 'car',
    prefer_favourites: true,
    instructions: 'Sonner au 3e',
    pickup_notes: 'Rue A',
    dropoff_notes: 'Rue B',
    items: [{ description: 'colis', quantity: 1, weight: 25, fragile: true }],
    pricing_inputs: { distance: 3200 },
  };

  it('rend les montants en nombres, pas en chaînes', () => {
    const read = readOrderCustomFields({ custom_field_values: simulateFleetbaseRoundTrip(meta) });

    expect(typeof read.price).toBe('number');
    expect(read.price).toBe(650);
    expect(read.cod_amount).toBe(1950);
    expect(read.cod_goods_amount).toBe(1300);
  });

  it('rend `false` et non la chaîne « false »', () => {
    const read = readOrderCustomFields({ custom_field_values: simulateFleetbaseRoundTrip(meta) });

    expect(read.cod_includes_delivery).toBe(false);
    expect(read.prefer_favourites).toBe(true);
  });

  it('rend le colis en liste exploitable', () => {
    const read = readOrderCustomFields({ custom_field_values: simulateFleetbaseRoundTrip(meta) });

    expect(Array.isArray(read.items)).toBe(true);
    expect(read.items[0].weight).toBe(25);
    expect(read.items[0].fragile).toBe(true);
  });

  it('survit à l\'effacement de `meta` par la console', () => {
    // Exactement ce qui a été constaté sur `order_3iwkyblqqr` : `meta` réduit
    // au drapeau de la ressource allégée.
    const order = {
      custom_field_values: simulateFleetbaseRoundTrip(meta),
      meta: { _index_resource: true },
    };

    const effective = effectiveOrderMeta(order, null);

    expect(effective?.cod_amount).toBe(1950);
    expect(effective?.price).toBe(650);
  });

  it('ne relaie jamais le drapeau interne `_index_resource`', () => {
    // Même sans spécification locale : la version initiale ne nettoyait que la
    // branche de fusion, et le drapeau ressortait sur toute commande ancienne.
    expect(effectiveOrderMeta({ meta: { _index_resource: true } }, null)).toEqual({});
    expect(effectiveOrderMeta({ meta: { _index_resource: true } }, { price: 1 })?.price).toBe(1);
  });

  it('laisse une correction faite en console primer sur la copie locale', () => {
    const effective = effectiveOrderMeta(
      { custom_field_values: [{ custom_field: { name: 'price' }, value: '900' }], meta: {} },
      { price: 650, pricing_inputs: { distance: 3200 } },
    );

    expect(effective?.price).toBe(900);
    // Hors catalogue : reste servi par la copie locale.
    expect(effective?.pricing_inputs?.distance).toBe(3200);
  });

  it('retombe sur la copie locale quand rien n\'a survécu en amont', () => {
    const effective = effectiveOrderMeta({ meta: { _index_resource: true } }, { cod_amount: 1200 });

    expect(effective?.cod_amount).toBe(1200);
  });

  it('survit à un double encodage, si l\'amont corrige son ordre d\'affectation', () => {
    // Le jour où `syncCustomFieldValues()` remplira `value_type` en premier,
    // le cast ré-encodera la chaîne que nous envoyons déjà encodée. Le
    // contournement ne doit pas devenir un piège à ce moment-là.
    const doublyEncoded = JSON.stringify(JSON.stringify([{ description: 'colis', weight: 25 }]));
    const read = readOrderCustomFields({
      custom_field_values: [{ custom_field: { name: 'items' }, value: JSON.parse(doublyEncoded) }],
    });

    expect(Array.isArray(read.items)).toBe(true);
    expect(read.items[0].weight).toBe(25);
  });

  it('sait lire les valeurs insérées à plat par `withCustomFields()`', () => {
    const read = readOrderCustomFields({ price: '777', cod_amount: '1500' });

    expect(read.price).toBe(777);
    expect(read.cod_amount).toBe(1500);
  });

  it('ignore une clé hors catalogue, même présente en amont', () => {
    // Liste d'autorisation : un champ ajouté à la main dans la console ne se
    // retrouve pas servi aux applications sans que personne l'ait décidé.
    const read = readOrderCustomFields({
      custom_field_values: [{ custom_field: { name: 'marge-interne' }, value: '42' }],
    });

    expect(read['marge_interne']).toBeUndefined();
  });
});

/**
 * Les noms que Fleetbase sert déjà sur une commande.
 *
 * ── Pourquoi cette liste est épinglée ici ──────────────────────────────────
 *
 * Un champ personnalisé qui porte un nom déjà utilisé par Fleetbase ne produit
 * **aucune erreur** : le repli « à plat » de `readOrderCustomFields` lit la
 * valeur de Fleetbase, et comme les champs personnalisés sont fusionnés en
 * dernier, cette valeur **l'emporte** sur la nôtre.
 *
 * Constaté le 02/08/2026 sur `currency` : `Order` a une colonne du même nom,
 * dont le défaut est `USD`. La fiche servait `DZD`, la liste servait `USD`,
 * et chaque couche prise séparément disait `DZD`. Aucune relecture ne pouvait
 * le montrer — il a fallu comparer deux routes pour la même commande.
 *
 * ── D'où viennent ces noms ─────────────────────────────────────────────────
 *
 * Relevés le 03/08/2026 dans le source de `fleetops-api` tel qu'il tourne dans
 * le conteneur, pas de mémoire :
 *
 *   Http/Resources/v1/Order.php        (fiche)  — 52 clés
 *   Http/Resources/v1/Index/Order.php  (liste)  — 38 clés
 *
 * ⚠️ **À reprendre à chaque montée de version de Fleetbase.** Une clé ajoutée
 * en amont ne casse rien immédiatement : elle attend qu'on lui donne le même
 * nom. La liste étant épinglée et non déduite de la donnée examinée, ce test
 * ne peut pas se rendre vert tout seul en perdant sa cible — c'est le défaut
 * qu'avait la première version du banc de refus HTTP.
 */
const FLEETBASE_ORDER_KEYS = [
  'adhoc', 'adhoc_distance', 'barcode', 'comments', 'company_uuid', 'created_at',
  'currency', 'customer', 'customer_type', 'customer_uuid', 'dispatched',
  'dispatched_at', 'distance', 'driver_assigned', 'driver_assigned_uuid', 'eta',
  'facilitator', 'facilitator_type', 'facilitator_uuid', 'files',
  'has_driver_assigned', 'id', 'internal_id', 'is_scheduled', 'latest_status',
  'latest_status_code', 'meta', 'notes', 'order_config', 'order_config_uuid',
  'payload', 'payload_uuid', 'pod_method', 'pod_required', 'public_id',
  'purchase_rate', 'purchase_rate_uuid', 'qr_code', 'route_uuid', 'scheduled_at',
  'started', 'started_at', 'status', 'time', 'tracker_data', 'tracking',
  'tracking_number', 'tracking_number_uuid', 'tracking_statuses',
  'transaction_amount', 'transaction_uuid', 'type', 'updated_at', 'uuid',
  'vehicle_assigned', 'vehicle_assigned_uuid',
];

describe('collision de noms avec Fleetbase', () => {
  it('aucune clé du catalogue ne porte un nom que Fleetbase sert déjà', () => {
    const collisions = ORDER_CUSTOM_FIELDS.map((f) => f.key)
      .filter((key) => FLEETBASE_ORDER_KEYS.includes(key))
      .filter((key) => !FLEETBASE_OWNED_ORDER_KEYS.includes(key));

    expect(collisions).toEqual([]);
  });

  it('`currency` EST une collision — et elle est traitée, pas ignorée', () => {
    // Le témoin. Sans lui, un jour où `FLEETBASE_ORDER_KEYS` se viderait par
    // erreur, le cas précédent passerait au vert sans rien regarder.
    expect(FLEETBASE_ORDER_KEYS).toContain('currency');
    expect(ORDER_CUSTOM_FIELDS.map((f) => f.key)).toContain('currency');
    expect(FLEETBASE_OWNED_ORDER_KEYS).toContain('currency');
  });

  it('le repli à plat ne lit PAS une clé que Fleetbase possède', () => {
    // La reproduction exacte du défaut du 02/08/2026 : une commande de liste,
    // sans valeurs de champs personnalisés, qui porte la devise de Fleetbase.
    const read = readOrderCustomFields({ currency: 'USD', price: '650' });

    expect(read.currency).toBeUndefined();
    expect(read.price).toBe(650);
  });

  it('les trois champs de la déclaration à la porte sont libres', () => {
    for (const key of ['collected_amount', 'collected_at', 'collection_reason']) {
      expect(ORDER_CUSTOM_FIELDS.map((f) => f.key)).toContain(key);
      expect(FLEETBASE_ORDER_KEYS).not.toContain(key);
    }
  });
});
