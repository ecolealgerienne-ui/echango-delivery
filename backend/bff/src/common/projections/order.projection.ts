/**
 * Projection des objets Fleetbase avant de les servir à un client.
 *
 * ── Pourquoi une liste d'autorisation et non une liste d'exclusion ──────────
 *
 * Les trois modules relayaient l'objet Fleetbase intégral. Ce qui sortait du
 * BFF n'était donc pas décidé ici mais par Fleetbase, et changeait
 * silencieusement à chaque mise à jour de l'amont (revue M10). Toutes les
 * fuites corrigées à la main pendant la session — `driver_assigned_uuid`
 * exploitable pour usurper une identité, adresses et téléphones sur les
 * courses non réclamées, relation `customer` imbriquée dans un lieu — sont la
 * même erreur répétée : on retirait ce qu'on avait pensé à retirer.
 *
 * Une liste d'exclusion est fausse par défaut : un champ ajouté en amont sort
 * sans que personne ne le décide. Une liste d'autorisation est vide par
 * défaut : un champ nouveau ne sort pas tant qu'on ne l'a pas voulu. Le coût
 * est symétrique — il faut penser à ajouter ce dont l'app a besoin — mais
 * l'oubli est alors visible à l'écran, pas invisible sur le réseau.
 *
 * ── Ce que ces fonctions ne font PAS ────────────────────────────────────────
 *
 * Elles ne décident pas de l'accès. L'appartenance est vérifiée avant, dans
 * chaque service, contre les tables locales. Projeter un objet auquel on
 * n'avait pas droit reste une fuite, simplement plus discrète.
 */

/** Niveau de détail d'un lieu. */
export type PlaceDetail =
  /** Tout : le client a droit à cette course. */
  | 'full'
  /** Commune seule : course diffusée, pas encore réclamée. */
  | 'locality';

const pick = (source: any, keys: string[]): Record<string, any> => {
  const out: Record<string, any> = {};
  for (const key of keys) {
    if (source?.[key] !== undefined) out[key] = source[key];
  }
  return out;
};

/**
 * Réduit une adresse à sa commune.
 *
 * Les champs structurés sont préférés. À défaut, on retombe sur l'adresse
 * formatée en retirant son premier segment, qui porte le nom et la rue
 * (`MAGASIN1 - 3 AVENUE PAUL LANGEVIN, SCEAUX, 92330` → `SCEAUX, 92330`).
 * Cette heuristique dépend du format de saisie : en cas de doute elle renvoie
 * **rien** plutôt qu'un fragment qui pourrait encore identifier une porte.
 */
export function coarseLocality(place: any): string {
  // Le pays est délibérément absent : la colonne `country` de Fleetbase stocke
  // un **code ISO-2**, et « Alger, 16000, Alger, DZ » se lit comme une donnée
  // mal formatée. Sur un service national, il n'apprend rien de toute façon.
  const structured = [place?.city, place?.postal_code, place?.province]
    .filter((v) => typeof v === 'string' && v.trim().length > 0);

  if (structured.length) return structured.join(', ');

  const formatted = typeof place?.address === 'string' ? place.address : '';
  const segments = formatted
    .split(',')
    .map((s: string) => s.trim())
    .filter(Boolean);

  return segments.length > 1 ? segments.slice(1).join(', ') : '';
}

/** Champs d'un lieu que l'app sait lire (voir `Place.fromJson`). */
const PLACE_FULL = [
  'uuid',
  'public_id',
  'id',
  'name',
  'address',
  'street1',
  'street2',
  // Composantes rendues par le géocodage inverse et rangées dans les colonnes
  // de `Place` (30/07/2026). Projetées pour que le formulaire de modification
  // puisse les remettre : sans elles, modifier un nom sans repasser par la
  // carte les laisserait telles quelles côté serveur, mais l'app ne pourrait
  // ni les afficher ni signaler leur absence.
  'neighborhood',
  'city',
  'district',
  'postal_code',
  'province',
  'country',
  'location',
  'phone',
  'contact_name',
  'contact_phone',
];

/** Ce qui subsiste d'un lieu réduit à sa commune. */
const PLACE_LOCALITY = ['uuid', 'public_id', 'id', 'city', 'postal_code', 'province', 'country'];
// ⚠️ `neighborhood` et `district` en sont volontairement absents : le quartier
// désigne un périmètre de quelques rues, ce qui rapproche trop de la porte sur
// une course encore non réclamée.

export function projectPlace(place: any, detail: PlaceDetail, anonymousName?: string) {
  if (!place) return undefined;

  if (detail === 'full') {
    // `contact_name` n'existe pas sur le modèle `Place` de Fleetbase : le nom
    // du contact est déposé dans `meta` à la création. Le remonter ici évite
    // que chaque appelant ait à connaître ce détail de stockage — et il est
    // remonté SEULEMENT dans la branche complète : sur une course non
    // réclamée, ce nom est précisément ce que l'expurgation retire.
    const fromMeta = place?.meta?.contact_name;
    return {
      ...pick(place, PLACE_FULL),
      ...(place.contact_name === undefined && typeof fromMeta === 'string'
        ? { contact_name: fromMeta }
        : {}),
      // Adresse principale du carnet (§ « adresse magasin », 30/07/2026) :
      // même mécanisme que `contact_name`, un booléen déposé dans `meta` sans
      // équivalent natif sur `Place`.
      is_default: place?.meta?.is_default === true,
    };
  }

  return {
    ...pick(place, PLACE_LOCALITY),
    name: anonymousName ?? 'Destinataire',
    address: coarseLocality(place),
  };
}

/** Champs d'une commande que les apps savent lire. */
const ORDER_FIELDS = [
  'uuid',
  'public_id',
  'id',
  'status',
  'type',
  'adhoc',
  'dispatched',
  'tracking_number',
  'notes',
  'distance',
  'estimated_duration',
  // `proof_url` a été RETIRÉ (29/07/2026). C'est l'URL que Fleetbase construit
  // depuis son propre `APP_URL` : injoignable depuis un téléphone, et surtout
  // protégée par rien — la publier revient à livrer les preuves de livraison à
  // qui devine l'adresse. Toute la discipline posée côté transporteur (§11 :
  // jamais l'URL Fleetbase, toujours un chemin BFF authentifié) était
  // contournée ici par un champ oublié dans la liste d'autorisation.
  //
  // La preuve reste accessible, par une route qui vérifie l'appartenance :
  // `GET /commercant/commandes/:id/preuve`.
  'scheduled_at',
  'pod_required',
  'pod_method',
  'created_at',
  'updated_at',
];

/**
 * Champs de `meta` exposés aux clients.
 *
 * `meta` est un fourre-tout JSON : le relayer entier ferait sortir tout ce
 * qu'un intégrateur y déposerait un jour, sans que personne ne le décide —
 * exactement le défaut que cette projection corrige au niveau de la commande.
 */
const META_FIELDS = [
  'instructions',
  'vehicle_type',
  'items',
  'pickup_notes',
  'dropoff_notes',
  // Le prix est proposé par le commerçant et doit atteindre le transporteur :
  // c'est ce qui lui permet de décider s'il prend la course.
  'price',
  'currency',
  // L'origine du montant : le transporteur doit pouvoir distinguer un prix
  // proposé par le commerçant d'un tarif de la plateforme, ils ne se négocient
  // pas de la même façon.
  'price_source',
  // Somme réclamée au destinataire **à la porte**, livraison comprise. Rien à
  // voir avec `price` : elle circule en sens inverse, du destinataire vers le
  // commerçant. Le transporteur doit la connaître avant d'accepter — porter
  // des espèces n'engage pas comme porter un colis — et l'avoir sous les yeux
  // au moment de la remise, qui est là où se produit l'erreur de montant.
  //
  // Un seul sens, et tous ses lecteurs l'ont déjà : montant annoncé avant
  // acceptation, `expectedAmount` figé au registre, refus de percevoir plus
  // que dû, plafond de dette. Il est tenu au point d'écriture
  // (`buildOrderMeta`) plutôt que réinterprété par chaque lecteur.
  'cod_amount',
  // Le prix de la marchandise, tel que le commerçant l'a saisi. Sert à
  // reproduire la commande à l'identique et à lui montrer la décomposition du
  // montant réclamé — jamais à décider d'un encaissement.
  'cod_goods_amount',
  'cod_currency',
  // Décrit **comment le commerçant a saisi son montant**, pas ce que contient
  // `cod_amount` : la livraison est réclamée à la porte dans les deux cas.
  // Sert à reproduire la commande et à expliquer la décomposition ; le
  // règlement avec le transporteur, lui, ne change pas (journal §17).
  'cod_includes_delivery',
  // Choix du commerçant à la création. Écrit depuis le début (il sert à
  // reproduire une commande dupliquée) mais jamais projeté : la fiche ne
  // pouvait donc pas lui rappeler s'il avait sollicité ses favoris.
  'prefer_favourites',
];

/**
 * ⚠️ **Tolère un `meta` sérialisé en chaîne.**
 *
 * La version précédente faisait `if (typeof meta !== 'object') return undefined`
 * : une chaîne JSON était donc **écartée en silence**, et avec elle TOUT ce que
 * `meta` porte — prix, catégorie de véhicule, colis, montant à encaisser,
 * précisions d'adresse.
 *
 * ⚠️ Ce n'est **pas** ce qui a vidé la fiche du 30/07/2026 : la console montrait
 * un `meta` objet et complet, ce qui écarte cette piste-là. La tolérance reste
 * parce que le motif est réel en amont (ci-dessous), pas parce qu'elle a résolu
 * ce défaut.
 *
 * Ce n'est pas une hypothèse gratuite : `meta` est casté `Json::class` côté
 * Fleetbase, et ce projet a déjà rencontré exactement ce défaut de forme sur
 * `tracking_number`, servi « tantôt une chaîne, tantôt l'objet » — au point que
 * le client Dart et `trackingNumberOf()` appliquent tous deux cette même
 * tolérance. Un champ JSON qui arrive parfois encodé est un motif connu de
 * l'amont, pas une exception.
 *
 * Une chaîne illisible retombe sur `undefined`, comme avant : mieux vaut pas de
 * `meta` qu'un `meta` inventé.
 */
/**
 * Clés de `meta` retirées d'une course **diffusée mais pas encore réclamée**.
 *
 * ⚠️ Trou trouvé le 30/07/2026. `payload.dropoff` était bien réduit à sa
 * commune, mais `meta.dropoff_notes` porte **l'adresse de livraison telle que
 * le commerçant l'a tapée** — rue, numéro, étage — et sortait en entier. La
 * réduction était donc contournée par une clé voisine, exactement le défaut
 * que l'expurgation existe pour fermer : on retire ce qu'on a pensé à retirer.
 *
 * `instructions` part avec, pour la même raison : « sonner au 3e, porte
 * gauche, demander Karim » identifie une porte aussi sûrement qu'une rue.
 *
 * Ce qui reste est ce qui permet de **décider** de prendre la course — prix,
 * catégorie de véhicule, colis, montant à encaisser — et l'enlèvement, qui
 * est un commerce et se donne en entier par décision produit.
 */
const META_REDACTED_WHEN_UNCLAIMED = ['dropoff_notes', 'instructions'];

function projectMeta(meta: any, unclaimed = false): Record<string, any> | undefined {
  let source = meta;

  if (typeof source === 'string') {
    try {
      source = JSON.parse(source);
    } catch {
      return undefined;
    }
  }

  if (!source || typeof source !== 'object') return undefined;

  const allowed = unclaimed
    ? META_FIELDS.filter((field) => !META_REDACTED_WHEN_UNCLAIMED.includes(field))
    : META_FIELDS;

  const projected = pick(source, allowed);
  return Object.keys(projected).length ? projected : undefined;
}

/**
 * Identifiants de rattachement. Séparés parce qu'ils ne se donnent pas au même
 * public : `driver_assigned_uuid` a permis, avant la correction de C2, de
 * revendiquer l'identité d'un transporteur — un commerçant n'a aucune raison
 * de le connaître.
 */
const ORDER_LINK_FIELDS = ['customer_uuid', 'facilitator_uuid', 'driver_assigned_uuid'];

export interface OrderProjectionOptions {
  /** Course diffusée mais pas encore réclamée : le client est protégé. */
  unclaimed?: boolean;
  /** Rattachements exposés (le transporteur a besoin du sien). */
  links?: boolean;
  /** Champs ajoutés par le BFF, déjà projetés par l'appelant. */
  extra?: Record<string, any>;
}

/**
 * Projection destinée au transporteur.
 *
 * Sur une course non réclamée, deux niveaux distincts (décision produit du
 * 28/07/2026) : l'enlèvement est un commerce et passe en entier, la livraison
 * est chez un particulier et se réduit à sa commune. Les relations `owner` et
 * `customer` d'un lieu ne sont jamais reprises — elles peuvent porter les
 * données du client, et les laisser rouvrirait par une porte de côté ce que
 * l'expurgation de la livraison ferme.
 */
export function projectOrderForDriver(order: any, options: OrderProjectionOptions = {}) {
  if (!order) return order;
  const { unclaimed = false, links = true, extra = {} } = options;
  const payload = order.payload;

  return {
    ...pick(order, ORDER_FIELDS),
    ...(links ? pick(order, ORDER_LINK_FIELDS) : {}),
    meta: projectMeta(order.meta, unclaimed),
    payload: payload
      ? {
          pickup: projectPlace(payload.pickup, 'full'),
          dropoff: projectPlace(payload.dropoff, unclaimed ? 'locality' : 'full'),
        }
      : undefined,
    ...(unclaimed ? { redacted: true } : {}),
    ...extra,
  };
}

/**
 * Projection destinée au commerçant.
 *
 * Le nom du transporteur assigné est exposé — le commerçant doit pouvoir dire
 * à son client qui vient — mais pas son identifiant Fleetbase.
 */
export function projectOrderForMerchant(order: any, extra: Record<string, any> = {}) {
  if (!order) return order;
  const payload = order.payload;
  const driver = order.driver_assigned;

  return {
    ...pick(order, ORDER_FIELDS),
    // ⚠️ **Aucun `is_draft` ici, délibérément.** Une version précédente
    // projetait ce drapeau, dérivé de trois colonnes à la fois (`adhoc`,
    // `dispatched`, `driver_assigned_uuid`) : c'était un second état, parallèle
    // au statut Fleetbase, et il a immédiatement divergé — une publication dont
    // la première étape réussit (`adhoc = true`) et la seconde échoue laissait
    // une commande **encore `created` chez Fleetbase** mais « déjà publiée »
    // selon cette dérivation, donc ni republiable, ni affichée pareil d'un
    // écran à l'autre.
    //
    // Le statut Fleetbase fait foi (règle projet,
    // `docs/architecture_bff_fleetbase.md`) : il est déjà dans `ORDER_FIELDS`,
    // l'application en déduit ce qu'elle a besoin d'afficher. Un état de plus
    // ici, c'est un état de plus à garder synchronisé pour toujours.
    meta: projectMeta(order.meta),
    payload: payload
      ? {
          pickup: projectPlace(payload.pickup, 'full'),
          dropoff: projectPlace(payload.dropoff, 'full'),
        }
      : undefined,
    driver_assigned: driver ? pick(driver, ['name', 'phone', 'photo_url']) : undefined,
    ...extra,
  };
}

/**
 * Projection destinée au gestionnaire de flotte.
 *
 * Il pilote ses transporteurs : il lui faut l'identifiant du driver assigné
 * pour réaffecter, ce que le commerçant n'a pas.
 */
export function projectOrderForFleet(order: any, extra: Record<string, any> = {}) {
  if (!order) return order;
  const payload = order.payload;
  const driver = order.driver_assigned;

  return {
    ...pick(order, ORDER_FIELDS),
    ...pick(order, ORDER_LINK_FIELDS),
    meta: projectMeta(order.meta),
    payload: payload
      ? {
          pickup: projectPlace(payload.pickup, 'full'),
          dropoff: projectPlace(payload.dropoff, 'full'),
        }
      : undefined,
    driver_assigned: driver ? pick(driver, ['uuid', 'public_id', 'name', 'phone']) : undefined,
    ...extra,
  };
}

/** Champs d'un driver exposés au gestionnaire de flotte. */
const DRIVER_FIELDS = [
  'uuid',
  'public_id',
  'name',
  'phone',
  'email',
  'online',
  'status',
  'vehicle',
  'created_at',
];

export function projectDriverForFleet(driver: any) {
  if (!driver) return driver;
  return pick(driver, DRIVER_FIELDS);
}
