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

import { readOrderCustomFields } from '../../fleetbase/order-custom-fields';
import { platformCurrency } from '../money/currency';

/**
 * Niveau de détail d'un lieu.
 *
 * ── Décision produit du 31/07/2026, qui remplace la réduction à la commune ──
 *
 * Une course diffusée était servie avec sa livraison **réduite à sa commune**.
 * Constaté à l'écran : l'entreprise voyait huit lignes titrées « Destinataire »
 * et ne pouvait décider de rien — ni la distance, ni l'accès, ni même de quel
 * bout de la ville il s'agissait. Le motif d'origine était juste (ne pas livrer
 * l'annuaire des clients à qui rafraîchit une liste), la contrepartie ne l'était
 * pas : **on protégeait l'adresse, qui est le critère de décision, et on ne
 * protégeait rien de ce qui identifie réellement quelqu'un**.
 *
 * Ce qui rend l'arbitrage tenable est le même fait qui a levé la réservation aux
 * favoris le 29/07 : les transporteurs et les entreprises ne s'inscrivent pas
 * d'eux-mêmes, ils sont **invités nominativement** par Echango. Le contrôle a
 * lieu à l'entrée du réseau, sur l'identité réelle — pas sur ce que chacun peut
 * lire une fois entré.
 *
 * On masque donc **l'identité du destinataire, et elle seule**.
 */
export type PlaceDetail =
  /** Tout : le lecteur est engagé sur cette course. */
  | 'full'
  /** Tout sauf qui habite là : course diffusée, pas encore réclamée. */
  | 'anonymous';

const pick = (source: any, keys: string[]): Record<string, any> => {
  const out: Record<string, any> = {};
  for (const key of keys) {
    if (source?.[key] !== undefined) out[key] = source[key];
  }
  return out;
};

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

/**
 * Ce qui désigne **une personne** plutôt qu'un endroit.
 *
 * C'est la liste, et la seule, qui disparaît d'une course non réclamée. Elle est
 * courte volontairement : tout le reste — rue, numéro, étage, commune,
 * coordonnées — décrit un lieu, et le lieu est ce sur quoi on décide de prendre
 * une course ou non.
 *
 * ⚠️ `name` en fait partie parce que sur un lieu de livraison il porte le nom du
 * destinataire (le carnet d'adresses du commerçant enregistre « Toto » ou
 * « Mme Benali »), et non un libellé d'endroit. L'app retombe alors sur
 * `address`, qui dit où aller sans dire chez qui.
 */
const PLACE_IDENTITY_FIELDS = ['name', 'phone', 'contact_name', 'contact_phone'];

/**
 * Les colonnes qui décrivent **un endroit**, et rien qu'un endroit.
 *
 * ⚠️ **`address` n'en fait pas partie, et c'est le piège de tout ce lot.**
 * `Place.address` n'est pas une colonne : c'est un accesseur Fleetbase qui
 * recompose « nom, rue, commune, code postal, pays ». Il **contient donc le
 * nom**. Retirer `name` en laissant `address` ne masque rien du tout — pire,
 * sur le chemin de création de l'application le lieu de livraison n'a *que*
 * son nom (`createPlace(dto.dropoffLocationName, …)` sans `street1`, l'adresse
 * tapée partant dans `meta.dropoff_notes`), donc `address` **est** le nom du
 * destinataire et rien d'autre.
 *
 * L'adresse servie sur une course non réclamée est donc **recomposée ici**, à
 * partir des seules colonnes structurées. Quand elles sont vides — le cas
 * courant sur les commandes de l'app — il ne reste rien, et c'est correct :
 * l'adresse réelle est dans `meta.dropoff_notes`, servi par ailleurs, et la
 * position dans `location`. Le transporteur a de quoi aller à la porte sans
 * savoir qui l'ouvre.
 *
 * Trouvé par un agent de vérification, pas à la lecture — et il était visible à
 * l'écran : le titre de chaque ligne de « Courses libres » aurait été le nom du
 * destinataire, juste au-dessus du bandeau qui promet de ne pas le donner.
 */
const PLACE_STRUCTURED_ADDRESS_FIELDS = [
  'street1',
  'street2',
  'neighborhood',
  'city',
  'postal_code',
  'province',
];

export function projectPlace(place: any, detail: PlaceDetail = 'full') {
  if (!place) return undefined;

  // `contact_name` n'existe pas sur le modèle `Place` de Fleetbase : le nom du
  // contact est déposé dans `meta` à la création. Le remonter ici évite que
  // chaque appelant ait à connaître ce détail de stockage.
  const fromMeta = place?.meta?.contact_name;
  const projected: Record<string, any> = {
    ...pick(place, PLACE_FULL),
    ...(place.contact_name === undefined && typeof fromMeta === 'string'
      ? { contact_name: fromMeta }
      : {}),
    // Adresse principale du carnet (§ « adresse magasin », 30/07/2026) : même
    // mécanisme que `contact_name`, un booléen déposé dans `meta` sans
    // équivalent natif sur `Place`.
    is_default: place?.meta?.is_default === true,
  };

  if (detail === 'full') return projected;

  // ⚠️ Suppression **après** composition, et non liste d'autorisation réduite.
  //
  // Ce n'est pas une entorse à la règle du fichier : la liste d'autorisation
  // reste `PLACE_FULL`, elle décide seule de ce qui peut sortir. Ce retrait-ci
  // s'applique par-dessus. Le composer à part aurait créé une seconde liste à
  // tenir à jour — et un champ ajouté à l'une sans l'autre est exactement le
  // genre d'oubli qui a produit les fuites de la revue M10.
  for (const field of PLACE_IDENTITY_FIELDS) delete projected[field];

  // `address` est recomposé et non supprimé : le supprimer purement laisserait
  // l'app sans rien à afficher là où une vraie adresse structurée existe (les
  // lieux du carnet, saisis par la carte, en ont une).
  // ⚠️ Dédoublonné, parce que `city` et `province` sont **la même chaîne** dans
  // les wilayas-communes homonymes — Alger, Oran, Constantine, Annaba. Sans ça
  // l'adresse se terminait par sa propre fin : « Cité 1er Novembre, Alger,
  // 16000, Alger ». Se dédoublonner côté app est impossible, la répétition étant
  // interne à la chaîne qu'on lui sert.
  const seen = new Set<string>();
  const structured: string[] = [];

  for (const field of PLACE_STRUCTURED_ADDRESS_FIELDS) {
    const value = projected[field];
    if (typeof value !== 'string' || !value.trim()) continue;

    const component = value.trim();
    const key = component.toLowerCase();
    if (seen.has(key)) continue;

    seen.add(key);
    structured.push(component);
  }

  if (structured.length) {
    projected.address = structured.join(', ');
  } else {
    delete projected.address;
  }

  return projected;
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
 * Clés que Fleetbase dépose lui-même dans `meta` et qui ne sont pas des
 * données métier.
 *
 * `_index_resource` est le marqueur observé le 30/07/2026 sur une commande dont
 * `meta` avait été écrasé par une affectation depuis la console : il valait
 * `{_index_resource: true}` et rien d'autre. Le reconnaître permet de
 * distinguer « meta absent » de « meta remplacé par un artefact ».
 */
const FLEETBASE_INTERNAL_META_KEYS = ['_index_resource'];

/**
 * Les données métier effectives d'une commande, dans l'ordre de confiance.
 *
 * ── Trois stockages, et pourquoi trois ──────────────────────────────────────
 *
 * 1. **Les champs personnalisés** (`custom_field_values`) — le stockage
 *    durable, et la source. Table séparée, synchronisée seulement si la
 *    requête la porte : intacte après n'importe quelle mise à jour de la
 *    commande. C'est aussi le seul endroit qu'un admin peut corriger depuis la
 *    console en étant sûr que la correction tienne.
 *
 * 2. **`meta`** — le stockage historique, fragile par construction. Il est dans
 *    le `$fillable` sans mutateur : `$record->update($input)` le **remplace en
 *    entier**. Constaté le 30/07/2026 — après une affectation de transporteur
 *    depuis la console, il ne restait que `{_index_resource: true}`. Il reste lu
 *    pour les commandes d'avant la migration.
 *
 * ⚠️ **Il y en avait TROIS jusqu'au 03/08/2026.** `Order.specMeta` — une copie
 * locale de ce qui avait été demandé — servait de dernier recours pour les
 * commandes d'avant les champs personnalisés. Elle est partie : la reprise de
 * données a constaté que **535 commandes sur 535 avaient déjà leurs champs
 * personnalisés complets** (`scripts/backfill-order-custom-fields.sh`), donc
 * le filet ne rattrapait plus rien. C'était la dernière donnée métier stockée
 * côté BFF.
 *
 * ── L'ordre de préséance, et pourquoi il est dans ce sens ───────────────────
 *
 * Le plus durable gagne, **clé par clé**. Une valeur corrigée en amont — par un
 * admin qui rectifie un montant — reste donc autoritaire, conformément à la
 * règle 1 : Fleetbase fait foi. Les couches inférieures ne comblent que les
 * trous, et le seul trou qu'elles réparent est un effacement, qui n'est jamais
 * une intention.
 *
 * L'ordre inverse aurait fait de la copie locale la vraie source et rendu toute
 * correction amont invisible : exactement le second vocabulaire que la règle 1
 * interdit.
 */
export function effectiveOrderMeta(order: any): Record<string, any> | undefined {
  const merged = mergeMetaLayers(order?.meta);
  const custom = readOrderCustomFields(order);

  if (!Object.keys(custom).length) return merged;
  return { ...(merged ?? {}), ...custom };
}

function mergeMetaLayers(liveMeta: any): Record<string, any> | undefined {
  const parse = (value: any): Record<string, any> | undefined => {
    let source = value;
    if (typeof source === 'string') {
      try {
        source = JSON.parse(source);
      } catch {
        return undefined;
      }
    }
    return source && typeof source === 'object' && !Array.isArray(source) ? source : undefined;
  };

  const live = parse(liveMeta);

  // ⚠️ Les clés internes de Fleetbase sont retirées **avant tout**, y compris
  // quand il n'y a pas de spécification locale à fusionner.
  //
  // La version précédente ne le faisait que dans la branche de fusion, et un
  // `meta` réduit à `{_index_resource: true}` ressortait donc tel quel sur
  // toute commande sans `specMeta` — c'est-à-dire sur toutes celles d'avant
  // hier. Ce drapeau n'est pas une donnée métier : il signale que
  // l'enregistrement vient de la ressource allégée, et le relayer plus loin
  // reviendrait à propager un artefact de transport comme s'il décrivait la
  // commande. Trouvé par un test unitaire, pas à la lecture.
  const meaningful: Record<string, any> = {};
  for (const [key, value] of Object.entries(live ?? {})) {
    if (!FLEETBASE_INTERNAL_META_KEYS.includes(key)) meaningful[key] = value;
  }

  return live ? meaningful : undefined;
}

/**
 * Champs de `meta` exposés aux clients.
 *
 * `meta` est un fourre-tout JSON : le relayer entier ferait sortir tout ce
 * qu'un intégrateur y déposerait un jour, sans que personne ne le décide —
 * exactement le défaut que cette projection corrige au niveau de la commande.
 */
export const PROJECTED_META_FIELDS = [
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
  // Un seul sens, et tous ses lecteurs l'ont déjà. Il est tenu au point
  // d'écriture (`buildOrderMeta`) plutôt que réinterprété par chaque lecteur.
  // ⚠️ La liste de ses lecteurs a raccourci le 03/08/2026 : le montant figé au
  // registre et le plafond de dette sont partis avec le registre de caisse.
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
  // ── Ce qui s'est passé à la porte ────────────────────────────────────────
  //
  // ⚠️ **Ces trois-là ont été ajoutés aux champs personnalisés le 03/08/2026
  // sans être ajoutés ICI, et ils n'atteignaient donc AUCUNE application.** La
  // fiche du commerçant affichait « pas encore encaissé » sur une livraison
  // déclarée. Aucune erreur, aucun journal : la liste d'autorisation fait
  // exactement ce pour quoi elle existe — elle refuse par défaut —, et c'est ce
  // qui rend l'oubli silencieux plutôt que dangereux. C'est la contrepartie
  // assumée de la polarité choisie (règle 12).
  //
  // Les trois personas les reçoivent : le transporteur parce que c'est **sa**
  // déclaration, le commerçant parce qu'il en est le destinataire, l'entreprise
  // parce qu'elle facilite la course.
  'collected_amount',
  'collected_at',
  'collection_reason',
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
 * ⚠️ **`meta` n'est plus expurgé sur une course non réclamée** (31/07/2026).
 *
 * `dropoff_notes` et `instructions` en étaient retirés, parce qu'ils portent
 * l'adresse telle que le commerçant l'a tapée — rue, numéro, étage. C'était
 * cohérent tant que `payload.dropoff` était lui-même réduit à sa commune ; ça ne
 * l'est plus depuis que l'adresse complète est servie (voir `PlaceDetail`).
 *
 * **Ce qui reste vrai et qu'il faut assumer** : ces deux champs sont du texte
 * libre, donc un commerçant peut y écrire « demander Karim, 0555… ». Le masquage
 * porte sur les champs **structurés** d'identité, il ne peut rien contre une
 * saisie libre. C'est un risque résiduel accepté, pas un oubli — et il vaut la
 * peine d'être dit ici plutôt que découvert plus tard : « sonner au 3e » est
 * précisément l'information sans laquelle un transporteur tourne dix minutes
 * dans une cage d'escalier.
 */
function projectMeta(meta: any): Record<string, any> | undefined {
  let source = meta;

  if (typeof source === 'string') {
    try {
      source = JSON.parse(source);
    } catch {
      return undefined;
    }
  }

  if (!source || typeof source !== 'object') return undefined;

  const projected = pick(source, PROJECTED_META_FIELDS);
  normaliseCurrencies(projected);
  return Object.keys(projected).length ? projected : undefined;
}

/**
 * Une seule devise sur toute la course — décidée ici, pas relayée.
 *
 * ── Le défaut (02/08/2026) ──────────────────────────────────────────────────
 *
 * « 777 USD » pour le prix, « À encaisser : 2727 DZD » deux lignes plus bas.
 * Deux devises sur la même course, parce que les deux nombres venaient de deux
 * sources : le prix relayait le champ de Fleetbase, le montant à encaisser
 * venait du registre de caisse, qui écrit `DZD`. Motif complet et cause exacte
 * (une collision de noms avec la colonne `currency` de Fleetbase) dans
 * `common/money/currency.ts`.
 *
 * ── Pourquoi ici et pas dans l'application ──────────────────────────────────
 *
 * Substituer le libellé côté écran créerait une **troisième** règle, dans un
 * fichier où personne n'irait la chercher — et il faudrait la répéter pour
 * chacun des trois personas (règle 5). La projection est le point par lequel
 * passent déjà les trois, et c'est elle qui décide de ce qui sort.
 *
 * ── Ce que cette fonction ne fait pas ───────────────────────────────────────
 *
 * ⚠️ **Aucune conversion.** Les montants ne sont pas touchés ; seul leur nom
 * est corrigé, parce que Fleetbase ne propose pas le DZD et que sa case ne peut
 * donc jamais dire la vérité de cette plateforme.
 *
 * ⚠️ **Aucune devise sans montant.** Une course sans prix ne reçoit pas de
 * devise : « DZD » tout seul décrirait une somme qui n'existe pas, et l'absence
 * de prix est une information qu'un repli effacerait (règle 10).
 */
function normaliseCurrencies(meta: Record<string, any>): void {
  const currency = platformCurrency(process.env.CURRENCY);
  if (meta.price !== undefined && meta.price !== null) meta.currency = currency;
  if (meta.cod_amount !== undefined && meta.cod_amount !== null) meta.cod_currency = currency;
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
 * Sur une course non réclamée (décision produit du 31/07/2026) : l'enlèvement
 * est un commerce et passe en entier, la livraison passe **complète elle
 * aussi**, à l'exception de qui habite là. Les relations `owner` et `customer`
 * d'un lieu ne sont jamais reprises — elles portent les données du client, et
 * les laisser rouvrirait par une porte de côté ce que le masquage ferme.
 *
 * ⚠️ La même règle qu'en face, et c'est délibéré : une entreprise et un
 * indépendant regardent **la même course libre** et décident de la même chose.
 * Deux niveaux de détail différents pour la même donnée, ce serait le « second
 * vocabulaire » que la règle 1 du projet interdit — et le moins-disant des deux
 * deviendrait vite le bug qu'on ne comprend pas.
 */
export function projectOrderForDriver(order: any, options: OrderProjectionOptions = {}) {
  if (!order) return order;
  const { unclaimed = false, links = true, extra = {} } = options;
  const payload = order.payload;

  // ⚠️ Sur une course NON RÉCLAMÉE, aucun rattachement (défaut D5).
  //
  // La branche d'expurgation ne touchait que `meta` et `payload` : les trois
  // identifiants de rattachement sortaient quand même. Le seul rattachement dont
  // un transporteur a besoin est le sien, et il ne l'a que sur une course qui
  // est déjà la sienne.
  //
  // ⚠️ **Ce retrait ne protège PAS l'identité du commerçant, et il ne faut pas
  // le croire.** Une version précédente de ce commentaire l'affirmait — « mis
  // bout à bout, c'est la cartographie commerciale du réseau » — alors que la
  // ligne d'à côté sert `pickup` en entier, enseigne et téléphone du magasin
  // compris (décision produit du 28/07 : l'enlèvement est un commerce). Ce qui
  // est retiré ici, ce sont des **identifiants Fleetbase**, exploitables pour
  // agir ; le nom du commerçant, lui, est donné.
  //
  // Décrire une protection qu'on n'a pas est pire que ne pas l'avoir : on cesse
  // de se poser la question. La question, elle, reste ouverte — faut-il masquer
  // le contact du magasin tant que personne ne s'est engagé ? — et elle est
  // consignée dans `docs/specs_facilitateur.md` §D7 plutôt que tranchée ici.
  const exposeLinks = links && !unclaimed;

  return {
    ...pick(order, ORDER_FIELDS),
    ...(exposeLinks ? pick(order, ORDER_LINK_FIELDS) : {}),
    meta: projectMeta(order.meta),
    payload: payload
      ? {
          pickup: projectPlace(payload.pickup, 'full'),
          dropoff: projectPlace(payload.dropoff, unclaimed ? 'anonymous' : 'full'),
        }
      : undefined,
    // `redacted` dit à l'app qu'il **manque** quelque chose, et lequel : sans ce
    // drapeau, une fiche sans nom ni téléphone se lit comme une donnée absente,
    // et le transporteur appellerait le commerçant pour la réclamer.
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
 *
 * ── Le niveau de détail suit l'ENGAGEMENT, pas le persona (défaut D7) ──────
 *
 * Cette projection servait `dropoff` en entier, sans condition et sans moyen
 * de faire autrement. Tant qu'une entreprise ne voyait que les courses qu'un
 * opérateur lui avait rattachées, c'était sans conséquence. Dès qu'elle consulte
 * les courses **libres** pour décider d'en prendre une, la même fonction
 * livrerait nom et téléphone du destinataire de toute course en attente de tout
 * commerçant — à tout compte flotte.
 *
 * Ce qui suit l'engagement, depuis le 31/07/2026, est **l'identité du client, et
 * elle seule** : l'adresse, les précisions d'accès, le prix et le montant à
 * encaisser sont servis dans les deux cas, parce que ce sont eux qui permettent
 * de décider. `facilitator_uuid` posé ⇒ l'entreprise est engagée, et le nom et
 * le téléphone apparaissent, parce qu'il faut bien pouvoir sonner.
 */
export function projectOrderForFleet(
  order: any,
  extra: Record<string, any> = {},
  options: { unclaimed?: boolean } = {},
) {
  if (!order) return order;
  const { unclaimed = false } = options;
  const payload = order.payload;
  const driver = order.driver_assigned;

  return {
    ...pick(order, ORDER_FIELDS),
    // Sur une course libre, aucun rattachement — même motif que côté
    // transporteur : ils nomment le commerçant, et il n'y a rien à en faire
    // avant de s'être engagé.
    ...(unclaimed ? {} : pick(order, ORDER_LINK_FIELDS)),
    meta: projectMeta(order.meta),
    payload: payload
      ? {
          pickup: projectPlace(payload.pickup, 'full'),
          dropoff: projectPlace(payload.dropoff, unclaimed ? 'anonymous' : 'full'),
        }
      : undefined,
    ...(unclaimed ? { redacted: true } : {}),
    // ⚠️ Conditionné par `unclaimed` alors qu'une course libre n'a par
    // définition aucun conducteur (`isClaimable` exige `!driver_assigned_uuid`).
    // C'était donc le seul champ de cette projection sans garde, protégé par un
    // invariant posé ailleurs : le jour où « libre » s'assouplit — course adhoc
    // pré-assignée, réaffectation — nom et téléphone du conducteur d'un
    // concurrent sortiraient, en silence et sans que personne ne l'ait décidé.
    driver_assigned:
      !unclaimed && driver ? pick(driver, ['uuid', 'public_id', 'name', 'phone']) : undefined,
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
