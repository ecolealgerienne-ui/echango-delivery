/**
 * Le catalogue des champs personnalisés d'un **conducteur**.
 *
 * ── Pourquoi chez Fleetbase et pas dans une colonne du BFF (règle 1) ────────
 *
 * `Driver` porte le trait `HasCustomFields` — vérifié dans le source de
 * `fleetops` le 02/08/2026, ligne 60 du modèle, aux côtés de `Vendor`, `Place`,
 * `Fleet` et dix autres. Une préférence de conducteur a donc un foyer naturel
 * chez Fleetbase, et le BFF n'a pas à inventer une dix-septième table.
 *
 * L'avantage n'est pas seulement doctrinal : un opérateur peut lire et corriger
 * la zone depuis la console, sans que nous ayons d'écran à fournir pour ça.
 *
 * ── Ce que la mesure a appris, et qu'aucune documentation ne dit ────────────
 *
 * ⚠️ **`PUT /int/v1/drivers/:id` exige un corps ENVELOPPÉ** : `{driver: {…}}`.
 * Envoyé à plat, Laravel rend un **500** — `Validation\Factory::make():
 * Argument #1 ($data) must be of type array, null given` — qui nomme un fichier
 * du framework et ne dit rien du contrat. Trois quarts d'heure y sont passés
 * avant de tenter l'enveloppe. C'est la même convention que la lecture unitaire
 * d'une commande, servie sous `{order: {…}}`.
 *
 * ⚠️ **La création d'une définition répond sous `custom_field`**, pas sous
 * `data` : lire la mauvaise clé faisait conclure à un échec sur une création
 * parfaitement réussie.
 *
 * ⚠️ **Les définitions sont attachées au conducteur lui-même** (`subject_uuid`
 * = son uuid), pas à une configuration partagée comme pour les commandes. Il y
 * a donc deux définitions **par conducteur**. C'est ce que le modèle impose :
 * la relation `customFields()` filtre sur `subject_uuid`. Coût assumé et connu.
 */

export type DriverZoneFieldName = 'zone_wilaya' | 'zone_radius_km';

export interface DriverZoneFieldDefinition {
  /** Clé stable, jamais affichée — c'est elle qui fait le rattachement. */
  name: DriverZoneFieldName;
  /** Ce qu'un opérateur lit dans la console. */
  label: string;
  type: 'text' | 'number';
  helpText: string;
}

/**
 * ⚠️ **Le rattachement se fait par `name`, jamais par `label`.** Le formulaire
 * de la console expose le libellé et pas le nom : un opérateur qui renomme
 * « Wilaya de travail » garde son champ, et nous continuons de le trouver.
 * Même parti pris que le catalogue des commandes.
 */
export const DRIVER_ZONE_FIELDS: DriverZoneFieldDefinition[] = [
  {
    name: 'zone_wilaya',
    label: 'Wilaya de travail',
    type: 'text',
    helpText:
      'Les courses proposées à ce transporteur sont celles dont l’enlèvement '
      + 'se trouve dans cette wilaya. Vide : toutes les wilayas.',
  },
  {
    name: 'zone_radius_km',
    label: 'Rayon autour de sa position (km)',
    // ⚠️ **`text` et non `number`, et ce n'est pas une négligence (02/08/2026).**
    //
    // Un champ personnalisé de type `number` **refuse une chaîne vide** :
    // mesuré, `value: ""` rend `400 « Error occurred while trying to update a
    // driver »`, là où `value: "15"` passe. Or la chaîne vide est la seule
    // façon d'**effacer** une valeur — un réglage qu'on ne peut pas défaire est
    // un piège, pas un choix.
    //
    // L'alternative aurait été d'employer `0` comme sentinelle d'effacement.
    // Elle est pire : zéro kilomètre est une valeur *plausible* qui signifie
    // « ne rien voir », et la réinterpréter en « tout voir » ferait exactement
    // ce que la règle 10 interdit — donner un sens arbitraire à une donnée qui
    // en a déjà un.
    //
    // `readRadiusKm` analyse la chaîne, donc rien n'est perdu côté lecture.
    type: 'text',
    helpText:
      'Affine la liste autour de la position du transporteur. Sans position '
      + 'connue, ce rayon ne s’applique pas — la wilaya reste seule à filtrer. '
      + 'Laisser vide pour ne pas limiter.',
  },
];

/**
 * Ce qu'on écrit pour dire « aucune préférence ».
 *
 * ── Pourquoi une sentinelle, alors que le vide dirait la même chose ────────
 *
 * ⚠️ **Fleetbase refuse une chaîne vide sur n'importe quel champ personnalisé**
 * — texte comme nombre. Mesuré le 02/08/2026 : `value: ""` rend `400 « Error
 * occurred while trying to update a driver »`, `value: "Alger"` rend 200, et le
 * type n'y change rien. L'effacement par le vide est donc **impossible**, et
 * l'omission ne vaut pas mieux : les valeurs ne sont synchronisées que si la
 * requête les porte, donc ne rien envoyer **conserve** l'ancienne.
 *
 * ⚠️ **Ce n'est pas la valeur de repli que la règle 10 interdit.** Celle-là
 * détruit l'information d'absence en la déguisant en donnée — un `0` qui passe
 * pour un montant, un `false` qui passe pour un état connu. Ici c'est
 * l'inverse : la sentinelle **est** l'absence, elle est relue comme telle, et
 * elle existe parce que le stockage amont ne sait pas représenter le vide.
 *
 * Le tiret est choisi parce qu'aucune wilaya ne s'appelle ainsi et qu'aucun
 * rayon ne s'écrit ainsi : un opérateur qui le voit dans la console lit « rien
 * », pas une valeur qu'il faudrait interpréter.
 */
export const ZONE_UNSET = '-';

/**
 * Le nombre lu depuis une valeur de champ personnalisé.
 *
 * ⚠️ **Une valeur illisible rend `null`, jamais un nombre de repli.** Un rayon
 * fabriqué filtrerait sur une distance que personne n'a choisie, et
 * l'utilisateur n'aurait aucun moyen de s'en apercevoir — il verrait seulement
 * moins de courses. L'absence, elle, se traduit par « pas de filtrage », qui
 * est le côté sûr de l'erreur.
 */
export function readRadiusKm(raw: unknown): number | null {
  if (typeof raw === 'number') return Number.isFinite(raw) && raw > 0 ? raw : null;
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  if (!trimmed || trimmed === ZONE_UNSET) return null;
  const value = Number(trimmed);
  return Number.isFinite(value) && value > 0 ? value : null;
}

/** La wilaya lue depuis une valeur de champ personnalisé. */
export function readWilaya(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  return trimmed && trimmed !== ZONE_UNSET ? trimmed : null;
}
