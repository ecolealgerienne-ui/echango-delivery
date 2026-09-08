/**
 * Le champ personnalisé qui porte la **zone de service d'une entreprise de
 * transport** : la liste des wilayas où elle prend des courses.
 *
 * ── Pourquoi chez Fleetbase et pas dans une colonne du BFF (règle 1) ────────
 *
 * `Vendor` porte le trait `HasCustomFields` — vérifié dans le source `fleetops`
 * le 02/08/2026, aux côtés de `Driver`, `Place`, `Fleet` et dix autres. Une
 * préférence d'entreprise a donc un foyer naturel chez Fleetbase, et un
 * opérateur peut la lire et la corriger depuis la console sans que nous ayons
 * d'écran à fournir. C'est le pendant exact de `driver-zone-fields.ts`.
 *
 * ── Une seule chaîne, pas une valeur par wilaya ────────────────────────────
 *
 * Une entreprise dessert plusieurs wilayas. Un champ `text` porte la liste
 * séparée par des virgules ; `parseServiceWilayas` la relit. L'alternative — un
 * champ par wilaya, ou un type `array` — coûterait un provisionnement variable
 * et se heurterait au même refus de la chaîne vide (voir `FLEET_ZONE_UNSET`).
 *
 * ── Ce que la mesure du 02/08 a appris, transposé ici ──────────────────────
 *
 * ⚠️ **`PUT /int/v1/vendors/:id` prend l'uuid** (contrairement à `PUT /drivers`,
 * qui exige le `public_id`) — vérifié : `fb_activate_vendor_by_email` écrit
 * `{status:"active"}` par uuid et ça passe. Le corps est enveloppé sous
 * `vendor` (`setVendorCustomFieldValues`).
 *
 * ⚠️ **La création d'une définition répond sous `custom_field`**, pas `data`.
 *
 * ⚠️ **Fleetbase refuse une chaîne vide sur tout champ personnalisé** : d'où
 * `FLEET_ZONE_UNSET` pour dire « aucune wilaya déclarée ».
 */

export interface FleetZoneFieldDefinition {
  /** Clé stable, jamais affichée — c'est elle qui fait le rattachement. */
  name: 'service_wilayas';
  label: string;
  type: 'text';
  helpText: string;
}

/**
 * ⚠️ **Le rattachement se fait par `name`, jamais par `label`** : un opérateur
 * qui renomme le libellé dans la console garde son champ.
 */
export const FLEET_ZONE_FIELDS: FleetZoneFieldDefinition[] = [
  {
    name: 'service_wilayas',
    label: 'Wilayas desservies',
    type: 'text',
    helpText:
      'Les courses libres proposées à cette entreprise sont celles dont '
      + 'l’enlèvement se trouve dans l’une de ces wilayas, séparées par des '
      + 'virgules. Vide : toutes les wilayas.',
  },
];

/**
 * Ce qu'on écrit pour dire « aucune wilaya déclarée ».
 *
 * ⚠️ Fleetbase refuse `value: ""` (400) sur n'importe quel champ personnalisé,
 * et omettre la clé **conserve** l'ancienne valeur. La sentinelle est donc la
 * seule façon d'effacer. Le tiret : aucune wilaya ne s'appelle ainsi, un
 * opérateur le lit « rien ». Même choix que `ZONE_UNSET` côté conducteur.
 */
export const FLEET_ZONE_UNSET = '-';
