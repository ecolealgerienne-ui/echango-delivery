/**
 * Les données métier d'une commande, rangées dans les **champs personnalisés**
 * de Fleetbase plutôt que dans `meta`.
 *
 * ── Pourquoi ce déménagement ────────────────────────────────────────────────
 *
 * `meta` n'est pas protégeable. Il est dans le `$fillable` du modèle `Order` et
 * n'a aucun mutateur : le `$record->update($input)` générique le **remplace en
 * entier**. Constaté en production locale le 30/07/2026 — après une affectation
 * de transporteur depuis la console, `meta` valait `{_index_resource: true}`.
 * Prix, montant à encaisser, colis, précisions d'adresse : tout perdu, au
 * moment précis où quelqu'un prend la course en charge.
 *
 * Les champs personnalisés, eux, vivent dans une table séparée
 * (`custom_field_values`) et `onAfterUpdate()` ne les synchronise **que si la
 * requête les porte** (`if ($customFieldValues)`), sans supprimer ce qui manque
 * (`delete_missing` est à `false` par défaut). Une mise à jour qui les ignore
 * les laisse donc intacts — exactement la protection que `meta` n'a pas.
 *
 * ── Ce que le source impose, et qui décide de la forme d'ici ────────────────
 *
 * 1. **La clé de lecture vient du `label`**, pas du `name` :
 *    `getCustomFieldValues()` fait `Str::snake(Str::lower($cfv->custom_field_label))`.
 *    Les libellés sont donc nos clés actuelles, à l'identique — `price`,
 *    `cod_amount`… — pour que le contrat servi aux applications ne bouge pas
 *    d'un caractère. `description` porte l'explication en français, à
 *    destination de l'admin qui lira la console.
 *
 * 2. **`value_type` décide du stockage, pas `type`.** Le cast `CustomValue` ne
 *    traite spécialement que `object` et `array` (encodés/décodés en JSON) ;
 *    tout le reste est stocké **en chaîne**. Un nombre revient donc en chaîne,
 *    d'où la conversion explicite ci-dessous : sans elle, `meta.price` arrive
 *    en `"550"` et le désérialiseur Dart (`as num?`) le lit `null` — un prix
 *    qui disparaît sans erreur.
 *
 * 3. **`type` n'est qu'un indice d'affichage** pour la console (chaîne libre,
 *    max 50). `text` partout : c'est le seul dont on soit certain qu'il rende
 *    un champ éditable, et l'objectif est justement qu'un admin puisse
 *    corriger un montant.
 */

/** Comment la valeur est stockée côté Fleetbase (cast `CustomValue`). */
export type CustomFieldValueType = 'text' | 'array' | 'object';

export interface OrderCustomFieldDefinition {
  /** Clé servie aux applications — identique à celle de `meta` aujourd'hui. */
  key: string;
  /** Explication affichée à l'admin dans la console. */
  description: string;
  valueType: CustomFieldValueType;
  /** Reconvertit la valeur relue vers son type d'origine. */
  decode: (raw: any) => any;
}

const asNumber = (raw: any): number | undefined => {
  if (raw === null || raw === undefined || raw === '') return undefined;
  const value = typeof raw === 'number' ? raw : Number(raw);
  return Number.isFinite(value) ? value : undefined;
};

const asBoolean = (raw: any): boolean | undefined => {
  if (raw === null || raw === undefined || raw === '') return undefined;
  if (typeof raw === 'boolean') return raw;
  // Le stockage est textuel : `false` revient en `"false"`, qui est *vrai* en
  // JavaScript. Comparer explicitement, sans quoi une préférence désactivée se
  // relirait activée.
  return raw === 'true' || raw === '1' || raw === 1;
};

const asText = (raw: any): string | undefined => {
  if (raw === null || raw === undefined || raw === '') return undefined;
  return String(raw);
};

const asList = (raw: any): any[] | undefined => {
  if (Array.isArray(raw)) return raw;
  if (typeof raw !== 'string' || !raw.trim().length) return undefined;

  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed;
    // Double encodage : arrive si l'amont corrige un jour l'ordre
    // d'affectation de `syncCustomFieldValues()` et ré-encode la chaîne que
    // nous envoyons déjà encodée. Une passe de plus suffit.
    if (typeof parsed === 'string') {
      const inner = JSON.parse(parsed);
      return Array.isArray(inner) ? inner : undefined;
    }
    return undefined;
  } catch {
    return undefined;
  }
};

/**
 * Le catalogue. Une entrée = un champ personnalisé sur l'`OrderConfig`.
 *
 * ⚠️ **`pricing_inputs` en est délibérément absent.** Ce sont les entrées de la
 * future formule de tarification (distance, horaire, catégorie de véhicule) :
 * une donnée de calibration, pas d'exploitation. Sa perte n'empêche aucune
 * livraison de se faire, alors qu'un objet JSON de cette taille encombrerait la
 * fiche de commande de la console pour un admin qui n'a rien à en faire. Elle
 * reste dans `meta` et dans `Order.specMeta`.
 */
export const ORDER_CUSTOM_FIELDS: OrderCustomFieldDefinition[] = [
  {
    key: 'price',
    description: 'Rémunération du transporteur pour cette course (DZD).',
    valueType: 'text',
    decode: asNumber,
  },
  {
    key: 'currency',
    description: 'Devise de la rémunération.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'price_source',
    description:
      'Origine du montant : proposé par le commerçant, ou calculé par la plateforme.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'cod_amount',
    description:
      'Somme réclamée au destinataire à la porte, frais de livraison compris. '
      + 'Ce que le transporteur doit encaisser.',
    valueType: 'text',
    decode: asNumber,
  },
  {
    key: 'cod_goods_amount',
    description:
      'Prix de la marchandise seule, tel que le commerçant l\'a saisi. '
      + 'Sert à reproduire la commande à l\'identique.',
    valueType: 'text',
    decode: asNumber,
  },
  {
    key: 'cod_currency',
    description: 'Devise du montant à encaisser.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'cod_includes_delivery',
    description:
      'Le commerçant avait-il inclus la livraison dans le prix annoncé ? '
      + 'Décrit la saisie ; la livraison est réclamée à la porte dans les deux cas.',
    valueType: 'text',
    decode: asBoolean,
  },
  {
    key: 'vehicle_type',
    description: 'Catégorie de véhicule minimale exigée.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'target_favourite_uuid',
    description:
      'Favori nommé à qui la course est confiée (uuid du conducteur ou du vendor). '
      + 'Absent = diffusion large au pool réseau.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'target_favourite_kind',
    description:
      'Nature du favori ciblé : « driver » (conducteur) ou « fleet » (entreprise). '
      + 'Détermine comment la course lui est assignée à la publication.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'instructions',
    description: 'Consignes de livraison saisies par le commerçant.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'pickup_notes',
    description: 'Précisions sur l\'adresse d\'enlèvement.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'dropoff_notes',
    description: 'Précisions sur l\'adresse de livraison.',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'items',
    description: 'Contenu du colis : description, quantité, poids, fragilité.',
    valueType: 'array',
    decode: asList,
  },

  // ── Ce qui s'est passé à la porte ──────────────────────────────────────────
  //
  // Les trois champs ci-dessus décrivent ce qui **était attendu** ; ceux-ci
  // décrivent ce qui **a eu lieu**. Ils sont écrits par la clôture de la
  // livraison, jamais par la création.
  //
  // ⚠️ Ils remplacent la table `CashCollection` du registre de caisse, retiré
  // le 03/08/2026 (`docs/registre_caisse_precis.md`). Le fait reste, le solde
  // part : la plateforme dit ce qui a été perçu, elle ne tient plus le compte
  // de qui doit quoi à qui.
  //
  // ⚠️ **L'idempotence devient structurelle, et c'est le gain principal.** La
  // table accumulait des lignes, donc une reprise après échec réseau exigeait
  // une garde explicite — celle des remises manquait, et trois déclarations
  // pour une même dette étaient acceptées (mesuré le 03/08/2026). Ici la même
  // valeur écrite deux fois donne le même état : il n'y a rien à garder.
  {
    key: 'collected_amount',
    description:
      'Somme réellement perçue à la porte, déclarée par le transporteur en clôturant. '
      + 'Zéro est une valeur légitime : un destinataire qui refuse de payer est un fait.',
    valueType: 'text',
    decode: asNumber,
  },
  {
    key: 'collected_at',
    description: 'Horodatage de la déclaration d\'encaissement (ISO 8601).',
    valueType: 'text',
    decode: asText,
  },
  {
    key: 'collection_reason',
    description:
      'Motif de l\'écart entre le montant annoncé et le montant perçu, '
      + 'choisi dans une liste fermée. Absent quand les deux coïncident.',
    valueType: 'text',
    decode: asText,
  },

  // ── Ce que les transporteurs ont dit de cette course ───────────────────────
  //
  // ⚠️ **Ces deux-là étaient des tables du BFF** (`OrderDecline`,
  // `DeliveryFailure`) jusqu'au 03/08/2026. Ils sont remontés chez Fleetbase
  // parce que **la console est utilisée en exploitation** : un opérateur qui
  // ouvre une course immobile doit pouvoir lire « six refus, prix trop bas » ou
  // « échec : destinataire absent » sans nous appeler. Une donnée qui explique
  // un blocage et qui n'est visible que du BFF est une donnée qui manque là où
  // on la cherche.
  //
  // ⚠️ **Ni l'un ni l'autre n'est projeté vers les applications** — voir
  // `PROJECTED_META_FIELDS`. Un transporteur n'a pas à savoir qui d'autre a
  // refusé la course, ni à quel prix. C'est une décision de confidentialité,
  // écrite là-bas avec son motif.
  {
    key: 'declines',
    description:
      'Refus enregistrés : qui, quand, pour quel motif, et à quel prix la '
      + 'course était offerte. Sert à comprendre pourquoi une course ne part pas.',
    valueType: 'array',
    decode: asList,
  },
  {
    key: 'delivery_failures',
    description:
      'Échecs de livraison signalés à la porte : motif, précisions, preuve '
      + 'photographique et horodatage.',
    valueType: 'array',
    decode: asList,
  },
];

export const ORDER_CUSTOM_FIELD_KEYS = ORDER_CUSTOM_FIELDS.map((f) => f.key);

const BY_KEY = new Map(ORDER_CUSTOM_FIELDS.map((f) => [f.key, f]));

/**
 * Nom canonique du champ côté Fleetbase.
 *
 * `Str::slug()` est ce que `normalizeCustomFieldKey()` applique côté PHP :
 * les tirets bas deviennent des tirets. On le reproduit pour que le `name`
 * enregistré corresponde à ce que Fleetbase cherchera.
 */
export function customFieldName(key: string): string {
  return key.replace(/_/g, '-');
}

/**
 * Une valeur relue, ramenée à son type d'origine.
 *
 * Renvoie `undefined` sur une clé inconnue : le catalogue décide de ce qui
 * entre, un champ ajouté à la main dans la console ne se retrouve pas servi
 * aux applications sans que personne l'ait voulu. C'est le même principe que
 * la liste d'autorisation des projections.
 */
export function decodeCustomFieldValue(key: string, raw: any): any {
  return BY_KEY.get(key)?.decode(raw);
}

/**
 * Prépare la valeur pour Fleetbase.
 *
 * **Tout part en chaîne, y compris les tableaux** — et c'est un contournement,
 * pas une préférence.
 *
 * ── Le bug amont, et pourquoi il impose ceci ────────────────────────────────
 *
 * `syncCustomFieldValues()` crée la ligne ainsi :
 *
 *     $this->customFieldValues()->make([
 *         ...
 *         'value'      => $value,        // rempli EN PREMIER
 *         'value_type' => $valueType,    // rempli APRÈS
 *     ]);
 *
 * `fill()` respecte l'ordre du tableau, donc le cast `CustomValue::set()`
 * s'exécute alors que `value_type` n'est pas encore posé. Il lit
 * `data_get($attributes, 'value_type', 'text')`, croit à du texte, et renvoie
 * le tableau **tel quel**. Laravel fusionne alors un tableau dans les
 * attributs du modèle, et tente d'écrire une colonne nommée `0` :
 *
 *     SQLSTATE[42S22]: Unknown column '0' in 'field list'
 *
 * Constaté en réel le 30/07/2026, sur le premier envoi du colis.
 *
 * ── Pourquoi encoder nous-mêmes règle le problème dans les deux sens ────────
 *
 * En envoyant déjà une chaîne JSON, le cast — qui croit à du texte — la
 * laisse passer intacte, et c'est exactement ce qu'il faut en base. À la
 * relecture, `value_type` vaut cette fois `array` (il est en base) et
 * `CustomValue::get()` fait le `Json::decode()` : on récupère un tableau.
 *
 * Et si l'amont corrige un jour l'ordre d'affectation, la valeur sera
 * doublement encodée — une chaîne JSON contenant une chaîne JSON. `asList()`
 * s'en sort : il accepte une chaîne et la désérialise. Le contournement ne
 * deviendra donc pas un piège le jour où il cessera d'être nécessaire.
 */
export function encodeCustomFieldValue(
  definition: OrderCustomFieldDefinition,
  value: any,
): { value: string; value_type: CustomFieldValueType } {
  if (definition.valueType === 'array' || definition.valueType === 'object') {
    return { value: JSON.stringify(value), value_type: definition.valueType };
  }
  return { value: typeof value === 'string' ? value : String(value), value_type: 'text' };
}

/**
 * Relit les valeurs portées par une commande Fleetbase.
 *
 * ── Deux chemins de lecture, et pourquoi les deux ───────────────────────────
 *
 * `withCustomFields()` insère les valeurs **à plat** au premier niveau de la
 * ressource, sous une clé dérivée du libellé
 * (`Str::snake(Str::lower($label))`). C'est le chemin simple — mais il casse
 * si un admin renomme le champ dans la console.
 *
 * `custom_field_values[]` porte chaque valeur avec sa définition
 * (`custom_field.name`), et `name` n'est **pas** exposé par le formulaire
 * d'édition de la console — donc bien plus stable qu'un libellé. C'est le
 * chemin préféré ; le plat sert de repli.
 *
 * Fonction pure : elle ne lit que l'objet reçu, ce qui permet de l'appeler
 * depuis la projection sans y faire entrer un service.
 */
export function readOrderCustomFields(order: any): Record<string, any> {
  const out: Record<string, any> = {};

  const rows = Array.isArray(order?.custom_field_values) ? order.custom_field_values : [];
  for (const row of rows) {
    const name = row?.custom_field?.name ?? row?.customField?.name;
    if (!name) continue;

    const key = String(name).replace(/-/g, '_');
    const decoded = decodeCustomFieldValue(key, row?.value);
    if (decoded !== undefined) out[key] = decoded;
  }

  for (const field of ORDER_CUSTOM_FIELDS) {
    if (out[field.key] !== undefined) continue;
    // ⚠️ Le repli à plat ne lit **que** ce que Fleetbase ne nomme pas déjà.
    if (FLEETBASE_OWNED_ORDER_KEYS.includes(field.key)) continue;
    const decoded = decodeCustomFieldValue(field.key, order?.[field.key]);
    if (decoded !== undefined) out[field.key] = decoded;
  }

  return out;
}

/**
 * Clés que **Fleetbase sert lui-même** sur une commande, et que le repli à plat
 * doit donc ignorer.
 *
 * ── Le défaut, mesuré le 02/08/2026 ─────────────────────────────────────────
 *
 * `Order` a une colonne `currency` dont le défaut est `USD`. Notre champ
 * personnalisé porte le même nom. Sur la **liste**, les valeurs des champs
 * personnalisés sont absentes (ressource d'index) : le repli à plat lisait donc
 * `order.currency` — celle de Fleetbase — et, parce que les champs personnalisés
 * sont fusionnés **en dernier**, cette valeur l'emportait sur le `DZD` correct
 * venu de `specMeta`. Résultat à l'écran : « 777 USD » à côté de « À encaisser :
 * 2727 DZD », sur la même course.
 *
 * ⚠️ **Un repli qui gagne contre la source n'est plus un repli.** C'est ce
 * renversement qui rend le défaut invisible : chaque couche prise séparément
 * disait `DZD` — le champ personnalisé, `meta`, `specMeta` — et l'écran disait
 * `USD`. Une lecture de code ne pouvait pas le montrer ; il a fallu comparer ce
 * que servent la liste et la fiche pour la **même** commande.
 *
 * ── Ce que la liste contient, et pourquoi une seule entrée suffit ───────────
 *
 * Les treize clés du catalogue ont été comparées aux 37 que sert la ressource
 * d'index : **une seule collision**, celle-ci. La liste n'est donc pas une
 * précaution vague, c'est une mesure — et elle est à refaire quand on ajoute un
 * champ personnalisé, parce qu'un nom déjà pris par Fleetbase ne produit aucune
 * erreur, seulement une valeur silencieusement fausse.
 */
export const FLEETBASE_OWNED_ORDER_KEYS = ['currency'];
