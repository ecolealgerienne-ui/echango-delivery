import { Injectable, Logger, HttpException, BadRequestException } from '@nestjs/common';
import { badRequest, notFound, forbidden } from '../common/errors/http-errors';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
// `FACILITATOR_TYPE_VENDOR` est importé plutôt que réécrit : sa valeur
// (`fleet-ops:vendor`) a été **mesurée** dans Fleetbase et non déduite, et la
// recopier ici serait la deuxième copie d'un fait vérifié une fois (règle 5).
import { FACILITATOR_TYPE_VENDOR, FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { OrderCustomFieldsService } from '../fleetbase/order-custom-fields.service';
import { MerchantFavouritesService } from '../fleetbase/merchant-favourites.service';
import { DriverZoneService } from '../fleetbase/driver-zone.service';
import { OrderPickup, orderPickup, zoneAllowsPickup } from '../common/orders/driver-zone';
import { ORDER_CUSTOM_FIELD_KEYS } from '../fleetbase/order-custom-fields';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import {
  effectiveOrderMeta,
  projectOrderForMerchant,
  projectPlace,
} from '../common/projections/order.projection';
import { PricingService } from '../common/pricing/pricing.service';

/**
 * Le favori retenu pour une course — **un conducteur ou une entreprise**.
 *
 * ── Pourquoi un type discriminé, et pas un objet à champs facultatifs ──────
 *
 * Les deux cas n'écrivent pas la même colonne chez Fleetbase :
 *
 *     conducteur ⇒ `driver_assigned_uuid`   (la course part à quelqu'un)
 *     entreprise ⇒ `facilitator_uuid`       (la course est confiée, pas affectée)
 *
 * Un objet portant `driverUuid?` et `vendorUuid?` laisserait l'appelant lire le
 * mauvais champ sans que rien ne l'arrête : un uuid de `Vendor` écrit dans la
 * colonne du conducteur produit une course **confiée à personne**, et le défaut
 * ne se voit qu'au moment où elle n'arrive pas. Le `kind` force la branche à
 * l'écriture, et le compilateur refuse d'accéder au champ de l'autre cas.
 */
type PickedFavourite =
  | { kind: 'driver'; driverUuid: string; accountId: string }
  | { kind: 'fleet'; vendorUuid: string; fleetId: string };

const asDriverPick = (account: any): PickedFavourite => ({
  kind: 'driver',
  driverUuid: account.fleetbaseDriverUuid,
  accountId: account.id,
});

const asFleetPick = (fleet: any): PickedFavourite => ({
  kind: 'fleet',
  vendorUuid: fleet.fleetbaseVendorUuid,
  fleetId: fleet.id,
});
import { readDriverPosition, readPositionSeenAt } from '../common/geo/driver-position';
import { EXPECTS_CASH_AT_DOOR } from './cash-expectation';
import { findFailure, projectFailures } from '../common/orders/delivery-failures';
import { platformCurrency } from '../common/money/currency';
import { isTerminalOrderStatus } from '../common/orders/order-status';
import {
  phoneContains,
  subscriberDigits,
} from '../common/identity/subscriber-number';
import { adhocRadiusMetres as configuredAdhocRadius } from '../common/orders/adhoc-radius';

@Injectable()
export class CommerçantService {
  private readonly logger = new Logger(CommerçantService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private favourites: MerchantFavouritesService,
    private configService: ConfigService,
    private audit: AuditService,
    private pricing: PricingService,
    private orderCustomFields: OrderCustomFieldsService,
    private driverZone: DriverZoneService,
  ) {}

  /**
   * Merge the merchant's cached order rows with their live Fleetbase state.
   *
   * The cache alone is not enough to show anything useful: it stores an id, a
   * tracking number and a status frozen at 'pending' on creation that nothing
   * ever resynchronises — so a merchant would watch a delivery that never
   * appears to progress, and would see neither addresses nor courier.
   *
   * The cache keeps the job it is actually good at: recording which orders
   * belong to which merchant. That mapping is what makes the anti-IDOR check
   * trustworthy.
   *
   * ⚠️ **Correction du 29/07/2026** : la justification qui suivait — « §2.8 a
   * établi que Fleetbase ignore les filtres, donc lui demander à qui sont ces
   * commandes renverrait toute la compagnie » — était fausse. Le paramètre
   * envoyé, `facilitator_uuid`, n'était pas un nom de filtre ; `customer` en
   * est un, et il fait le `where` attendu. Fleetbase **sait** répondre à « à
   * qui appartient cette commande », ce qui remet en cause l'existence même de
   * ce cache (`docs/architecture_bff_fleetbase.md` §4.4). Rien n'est supprimé
   * avant les vérifications du §9 de ce document.
   */
  private async mergeWithFleetbase(
    cached: { id: string; fleetbaseOrderId: string }[],
    vendorUuid?: string,
  ) {
    if (!cached.length) return [];

    let live: any[] = [];
    try {
      live = await this.fetchLiveOrders(cached, vendorUuid);
    } catch (error) {
      // Degrade rather than fail: without Fleetbase the merchant still sees
      // that the order exists, just not how far along it is.
      this.logger.warn(`Fleetbase unreachable, serving cached orders only: ${error.message}`);
      // Repli dégradé : seuls l'identifiant et le drapeau sortent. Étendre la
      // ligne Prisma exposait `merchantId` et les colonnes internes du cache.
      return cached.map((c) => ({
        uuid: c.fleetbaseOrderId,
        bff_order_id: c.id,
        stale: true,
      }));
    }

    // ⚠️ **Rechargées une par une avant d'être appariées.**
    //
    // `fetchLiveOrders` passe par `GET /orders`, servi par la ressource
    // d'index : `meta` y vaut `{_index_resource: true}` et
    // `custom_field_values` est **absent**, `with[]` ou pas. Sans ce
    // rechargement, la liste du commerçant n'aurait ni prix, ni montant à
    // encaisser, ni encaissement déclaré.
    //
    // ⚠️ On ne recharge que ce que le cache local désigne — donc une PAGE (25
    // par défaut), pas toute la compagnie. Les appelants qui passent une seule
    // commande n'y perdent rien.
    //
    // ⚠️ **Sauf un** : `collectionsOnMyOrders` passe toutes les commandes du
    // commerçant. Par lots de huit, trois cents commandes font une quarantaine
    // d'aller-retours. C'est lent et c'est juste ; le borner tronquerait la
    // liste en silence, ce qui serait pire.
    const voulus = new Set(cached.map((c) => c.fleetbaseOrderId));
    const complets = await this.fleetbaseClient.hydrateOrders(
      live.filter((o: any) => voulus.has(o?.uuid)),
    );

    const byId = new Map(complets.map((o: any) => [o?.uuid, o]));

    return cached.map((c) => {
      const order = byId.get(c.fleetbaseOrderId);
      if (!order) {
        // Order vanished from Fleetbase (deleted, or another organization).
        return { uuid: c.fleetbaseOrderId, bff_order_id: c.id, missing: true };
      }
      // Projection en liste d'autorisation : le BFF décide de ce qui sort, et
      // non Fleetbase (revue M10). L'identifiant local est conservé pour que
      // l'app puisse encore adresser la ligne dont il provient.
      //
      // `meta` est complété par la spécification locale : une affectation
      // depuis la console l'efface chez Fleetbase, et sans ce complément la
      // liste perdrait prix et montant à encaisser dès qu'un transporteur est
      // désigné.
      return projectOrderForMerchant(this.withEffectiveMeta(order), { bff_order_id: c.id });
    });
  }

  /**
   * Va chercher chez Fleetbase l'état des commandes que le cache dit être à ce
   * commerçant.
   *
   * ── Pourquoi un repli, et pourquoi il n'est pas de la prudence gratuite ────
   *
   * `?customer=<vendorUuid>` est vérifié et fonctionne. Mais il repose sur
   * `orders.customer_uuid`, **et cette colonne est restée nulle sur toutes les
   * commandes créées avant le 28/07/2026** : le BFF envoyait `customer` en
   * chaîne plate là où `normalizeCustomerType()` n'accepte que
   * `customer_uuid`/`customer_type` (journal §2.10). Ces commandes existent, le
   * commerçant les voit aujourd'hui, et le filtre serveur ne les renverra
   * jamais.
   *
   * Passer au filtre sans repli les ferait donc disparaître de son historique —
   * une régression métier invisible en test sur des données récentes, et
   * exactement ce que le plan interdit.
   *
   * Le repli ne coûte rien dans le cas normal : il ne se déclenche que s'il
   * manque quelque chose. Et son avertissement est utile en soi, puisqu'il
   * dénombre les commandes héritées qu'une reprise de données devrait corriger.
   */
  private async fetchLiveOrders(
    cached: { fleetbaseOrderId: string }[],
    vendorUuid?: string,
  ): Promise<any[]> {
    if (!vendorUuid) {
      return this.fleetbaseClient.fetchEveryOrder();
    }

    const scoped = await this.fleetbaseClient.fetchEveryOrder(100, 50, {
      customer: vendorUuid,
    });

    const found = new Set(scoped.map((o: any) => o?.uuid));
    const missing = cached.filter((c) => !found.has(c.fleetbaseOrderId));
    if (!missing.length) return scoped;

    this.logger.warn(
      `${missing.length} commande(s) absente(s) du filtre customer=${vendorUuid} — ` +
        'probablement créées avant le correctif customer_uuid (journal §2.10). ' +
        'Repli sur la lecture complète.',
    );

    const everything = await this.fleetbaseClient.fetchEveryOrder();
    const missingIds = new Set(missing.map((c) => c.fleetbaseOrderId));
    return [...scoped, ...everything.filter((o: any) => missingIds.has(o?.uuid))];
  }

  /**
   * État Fleetbase d'**une** commande dont l'appartenance est déjà établie.
   *
   * Trois écrans faisaient exactement la même chose : télécharger toute la
   * compagnie pour y retrouver un seul objet. La lecture est maintenant bornée
   * au commerçant, avec le même repli hérité que `fetchLiveOrders`.
   *
   * La lecture unitaire `GET /orders/{uuid}` serait plus directe encore, et
   * elle n'est délibérément pas utilisée ici : rien ne garantit qu'elle charge
   * les mêmes relations que la liste (`queryForInternal` en précharge une
   * dizaine), et une projection qui perdrait des champs changerait le contrat
   * avec l'application — ce que le plan interdit. À comparer par test réel
   * avant de basculer.
   */
  private async liveOrderFor(
    vendorUuid: string,
    order: { fleetbaseOrderId: string },
  ): Promise<any> {
    const orders = await this.fetchLiveOrders([order], vendorUuid);
    return orders.find((o: any) => o?.uuid === order.fleetbaseOrderId);
  }

  /**
   * Numéro de suivi, quelle que soit la forme sous laquelle Fleetbase le sert.
   *
   * `tracking_number` est tantôt une chaîne, tantôt l'objet complet — le client
   * Dart applique déjà la même tolérance (`readTrackingNumber`), preuve que les
   * deux formes se rencontrent en vrai.
   */
  private trackingNumberOf(order: any): string | null {
    const raw = order?.tracking_number;
    if (typeof raw === 'string') return raw;
    return raw?.tracking_number ?? null;
  }

  async getOrders(merchantId: string, query: ListOrdersQueryDto) {
    this.logger.log(`Fetching orders for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      const page = query.page || 1;
      const limit = query.limit || 25;

      const cached = await this.prisma.order.findMany({
        where: { merchantId },
        skip: (page - 1) * limit,
        take: limit,
        orderBy: { createdAt: 'desc' },
      });

      const orders = await this.mergeWithFleetbase(cached, merchant.fleetbaseVendorUuid);
      const total = await this.prisma.order.count({ where: { merchantId } });

      // `status` is filtered here rather than in the query: the cached status
      // is stale, so only the merged result knows the real one.
      const filtered = query.status
        ? orders.filter((o: any) => o?.status === query.status)
        : orders;

      return {
        orders: filtered,
        pagination: { page, limit, total, pages: Math.ceil(total / limit) },
      };
    } catch (error) {
      this.logger.error(`Failed to fetch orders: ${error.message}`);
      badRequest('order.fetch_failed', 'Failed to fetch orders');
    }
  }

  /**
   * Rayon de diffusion d'une course adhoc, en mètres.
   *
   * La règle vit dans `common/orders/adhoc-radius.ts` : elle était écrite ici
   * ET dans `TransporteurService`, sous un commentaire qui affirmait que les
   * deux devaient rester identiques (règle 5).
   */
  private adhocRadiusMetres(): number {
    // Aliasé à l'import : sans alias, l'appel se lirait comme une récursion
    // sur la méthode du même nom. Il n'en est pas une — un identifiant nu
    // résout le module et non la méthode — mais rien ne le dit à la lecture.
    return configuredAdhocRadius(this.configService.get('ADHOC_RADIUS_METRES'));
  }

  /**
   * Métadonnées transmises à Fleetbase.
   *
   * `vehicle_type` y vit plutôt que dans une colonne native : Fleetbase n'a pas
   * de notion de *catégorie* de véhicule — `vehicle_assigned_uuid` désigne un
   * véhicule précis. Le filtrage est donc appliqué par le BFF au moment de
   * lister les opportunités d'un transporteur.
   */
  private buildOrderMeta(dto: CreateOrderDto): Record<string, any> | undefined {
    const meta: Record<string, any> = {};
    if (dto.deliveryInstructions) meta.instructions = dto.deliveryInstructions;
    if (dto.vehicleType) meta.vehicle_type = dto.vehicleType;
    if (dto.items?.length) meta.items = dto.items;
    if (dto.pickupNotes) meta.pickup_notes = dto.pickupNotes;
    if (dto.dropoffNotes) meta.dropoff_notes = dto.dropoffNotes;

    // ⚠️ **La wilaya d'enlèvement est recopiée ici, et ce n'est pas un état
    // parallèle (02/08/2026).**
    //
    // Elle vit sur le `Place`, qui est sa source. Mais **la liste des commandes
    // ne la sert pas** : mesuré, la ressource d'index rend un point d'enlèvement
    // à quinze clés — `city` y est, `province` non — là où la fiche unitaire en
    // rend trente. C'est la troisième fois que cette ressource allégée nous
    // coûte, après les prix invisibles côté entreprise et le `meta` réduit à son
    // drapeau.
    //
    // Or c'est **sur la liste** que le filtre du transporteur s'applique.
    // Hydrater chaque course pour la lire coûterait un aller-retour par course,
    // à trois secondes pièce sur cet environnement — pour une donnée qui ne
    // changera jamais : le point d'enlèvement d'une course ne se déplace pas.
    //
    // Elle rejoint donc `vehicle_type`, que le même filtre lit déjà depuis la
    // liste par le même chemin. Ce n'est pas un second vocabulaire au sens de la
    // règle 1 — c'est la spécification figée à la création, comme
    // `CashCollection.expectedAmount`, et la fiche reste la source pour tout le
    // reste.
    if (dto.pickupProvince) meta.pickup_province = dto.pickupProvince;
    if (dto.dropoffProvince) meta.dropoff_province = dto.dropoffProvince;
    // Reproduit à l'identique par « refaire cette livraison » — sans lui, la
    // duplication retombait systématiquement sur la valeur par défaut du
    // formulaire (`true`), jamais sur le choix réel de la commande d'origine.
    meta.prefer_favourites = dto.preferFavourites === true;

    // Le devis est demandé sur TOUTE commande, même quand le commerçant a
    // saisi son montant : ce qui est enregistré au passage — distance, horaire,
    // catégorie de véhicule — sont les entrées de la future formule de calcul.
    // Elles ne sont pas rattrapables après coup : la distance dépend du
    // géocodage et du réseau routier du moment, et une commande rejouée plus
    // tard ne donnerait pas le même chiffre. Sans elles, les courses du pilote
    // ne serviront pas à calibrer le barème.
    //
    // Calculé AVANT le bloc d'encaissement, et pas seulement par commodité :
    // quand la livraison n'est pas comprise dans le prix de la marchandise,
    // c'est la rémunération qui s'ajoute au montant réclamé à la porte. Le
    // second dépend donc du premier.
    const quote = this.pricing.quote(
      {
        pickupLatitude: dto.pickupLatitude,
        pickupLongitude: dto.pickupLongitude,
        dropoffLatitude: dto.dropoffLatitude,
        dropoffLongitude: dto.dropoffLongitude,
        scheduledAt: dto.scheduledAt,
        vehicleType: dto.vehicleType,
      },
      dto.price,
    );

    meta.pricing_inputs = quote.inputs;

    if (quote.amount !== null) {
      meta.price = quote.amount;
      meta.currency = quote.currency;
      // L'origine du montant est enregistrée AVEC lui. Sans elle, l'historique
      // mélangerait prix proposés et prix calculés, et la calibration de la
      // future formule se ferait sur ses propres résultats.
      meta.price_source = quote.source;
    }

    // ── Paiement à la livraison ───────────────────────────────────────────
    //
    // Deux montants distincts, et les confondre serait l'erreur fondatrice :
    // `price` va du commerçant au transporteur, `cod_amount` va du
    // destinataire au commerçant. Sens inverses.
    //
    // ⚠️ **`cod_amount` est ce que le destinataire remet à la porte**, et
    // rien d'autre. C'est le sens que lui donnent déjà tous ses lecteurs : le
    // montant annoncé au transporteur avant qu'il accepte, `expectedAmount`
    // figé dans le registre de caisse, le refus de percevoir plus que dû, et
    // le plafond de dette. Un seul sens, tenu au point d'écriture, plutôt
    // qu'un champ que chaque lecteur interprète.
    //
    // Le commerçant, lui, saisit le **prix de sa marchandise**. Quand il
    // décide que la livraison est à la charge du destinataire, la
    // rémunération s'ajoute : marchandise 1300 + course 650 = 1950 réclamés à
    // la porte, dont 650 que le transporteur retient et 1300 qu'il remet.
    // Avant cette addition, le transporteur se voyait annoncer 1300 et le
    // commerçant n'en récupérait que 650 — il payait la livraison qu'il avait
    // explicitement mise à la charge de son client.
    if (dto.codAmount) {
      const goods = dto.codAmount;
      const includesDelivery = dto.codIncludesDelivery === true;
      const fee = includesDelivery ? 0 : (meta.price ?? null);

      // Refus explicite plutôt qu'un repli silencieux : sans rémunération
      // connue, « la livraison est à la charge du destinataire » n'a pas de
      // montant, et retomber sur la marchandise seule ferait payer le
      // commerçant à son insu — exactement ce que ce choix voulait éviter.
      if (fee === null) {
        badRequest(
          'order.cod_requires_price',
          'Indiquez la rémunération du transporteur : elle sera réclamée au destinataire en plus de la marchandise.',
        );
      }

      meta.cod_amount = goods + fee;
      // Ce que le commerçant a saisi, conservé tel quel. Recalculer
      // `cod_amount − price` fonctionnerait aujourd'hui, mais « refaire cette
      // livraison » repartirait alors du total et y rajouterait la course à
      // chaque duplication — l'erreur se composerait à chaque copie.
      meta.cod_goods_amount = goods;
      meta.cod_currency = this.pricing.currency;
      // Décrit désormais **comment le commerçant a saisi son montant**, et
      // non ce que contient `cod_amount` : la livraison est comprise dans le
      // montant réclamé à la porte dans les deux cas.
      meta.cod_includes_delivery = includesDelivery;
    }

    return Object.keys(meta).length ? meta : undefined;
  }



  /**
   * Parmi ces favoris, ceux dont la zone déclarée accepte ce départ.
   *
   * ── Pourquoi une lecture par favori, et pourquoi c'est acceptable ──────────
   *
   * La préférence vit dans les champs personnalisés du `Driver` : la lire coûte
   * un appel chacun. Le coût suit donc le nombre de favoris **encore en lice** —
   * un ou deux en pratique, après les filtres véhicule et disponibilité — et non
   * la taille du réseau. Même raisonnement que la résolution de disponibilité
   * juste au-dessus (journal §24).
   *
   * ⚠️ **Une zone illisible ne retire personne.** `DriverZoneService.read()`
   * rend « aucune préférence » sur n'importe quel échec, et cette fonction s'en
   * remet à lui : une panne Fleetbase doit coûter un filtre, jamais un favori.
   */
  private async favouritesAllowingPickup(
    accounts: any[],
    pickup: OrderPickup,
    /** Catégorie exigée par la course, si elle en exige une. */
    vehicleType?: string,
  ) {
    if (!accounts.length) return accounts;

    // Rien de connu sur le départ ET aucune exigence de véhicule : il n'y a
    // rien à comparer, donc rien à retirer. Éviter l'appel plutôt que le faire
    // pour n'en rien tirer.
    if (!pickup.wilaya && !pickup.point && !vehicleType) return accounts;

    // ⚠️ **Une seule lecture par favori pour les DEUX filtres.** La catégorie
    // de véhicule vivait dans `DriverAccount.vehicleType` — donc dans le
    // `where` d'une requête Prisma — jusqu'au 03/08/2026. Elle est chez
    // Fleetbase maintenant, et elle sort de la lecture qui portait déjà la
    // zone et la position. Deux passes auraient doublé le coût pour la même
    // réponse.
    const readings = await Promise.all(
      accounts.map((a: any) => this.driverZone.read(a.fleetbaseDriverUuid)),
    );

    // ⚠️ **Non déclaré = compatible**, et c'est le même biais que partout :
    // un transporteur ne doit pas être écarté du réseau par un champ qu'il n'a
    // pas rempli. Une course proposée à tort se remarque ; une course jamais
    // proposée est un manque à gagner que personne ne peut constater.
    const suits = (declared: string | null) => {
      if (!vehicleType || !declared) return true;
      return this.compatibleVehicleTypes(vehicleType).in.includes(declared);
    };

    return accounts.filter(
      (_: any, i: number) =>
        suits(readings[i].vehicleType)
        && zoneAllowsPickup(pickup, readings[i].zone, readings[i].point),
    );
  }

  /**
   * Premier transporteur favori actuellement en ligne, ou `null`.
   *
   * ── Ce que fait ce repli, et ce qu'il ne fait pas ──────────────────────────
   *
   * Il choisit **au moment de la création** : si aucun favori n'est en ligne,
   * la course part immédiatement au pool commun. C'est ce qui préserve l'effet
   * réseau (voir DriverFavourite dans le schéma).
   *
   * Ce qu'il ne fait PAS : reprendre la course si le favori ne l'accepte
   * jamais. Ce second repli, différé dans le temps, demande une tâche de fond
   * surveillant les courses assignées et non démarrées — à construire, avec le
   * délai comme décision produit. En attendant, une course confiée à un favori
   * qui l'ignore reste bloquée : c'est la limite à connaître avant d'activer
   * l'option en production.
   */
  private async pickAvailableFavourite(
    // ⚠️ L'uuid du VENDOR, plus l'identifiant de compte : les favoris vivent
    // désormais sur le vendor Fleetbase du commerçant (03/08/2026), donc c'est
    // lui la clé de lecture. Le passer explicitement évite une relecture du
    // compte sur un chemin appelé à chaque création de commande.
    vendorUuid: string,
    vehicleType?: string,
    /**
     * D'où part la course. ⚠️ **Optionnel, et son absence n'écarte personne** :
     * les deux appelants la connaissent, mais un troisième qui l'oublierait
     * doit dégrader vers « aucun filtrage » et non vers « aucun favori ».
     */
    pickup: OrderPickup = { wilaya: null, point: null },
  ) {
    // ⚠️ **Conducteurs seulement, et c'est un choix d'incrément.**
    //
    // Un favori peut désormais être une entreprise, mais la solliciter ne veut
    // pas dire la même chose : on ne pose pas `driver_assigned_uuid`, on pose
    // `facilitator_uuid`, et c'est l'entreprise qui désigne ensuite son
    // conducteur. Deux écritures différentes, deux gardes différentes.
    //
    // Les mélanger ici ferait assigner un `Vendor` uuid dans la colonne du
    // conducteur — une course confiée à personne, et le défaut ne se verrait
    // qu'au moment où elle n'arrive pas. Tant que le second incrément n'est pas
    // écrit, les favoris entreprise se **stockent et s'affichent** sans être
    // sollicités : le commerçant peut préparer sa liste, rien ne se route de
    // travers.
    // ⚠️ `readOrNone` et non `read` : sur CE chemin, ne pas trouver de favori
    // envoie la course au pool, ce que le commerçant a accepté en cochant
    // l'option. Le repli est donc sûr dans ce sens précis — l'inverse
    // (assigner à un favori qu'on croit avoir lu) ne le serait pas.
    const favourites = (await this.favourites.readOrNone(vendorUuid))
      .filter((f) => f.party_type === 'driver');
    if (!favourites.length) return null;

    const uuids = favourites.map((f) => f.party_uuid);

    // Le compte Echango porte la catégorie de véhicule et sert de garde : un
    // favori sans compte applicatif ne peut de toute façon pas recevoir la
    // course, faute de jeton push et d'application.
    // ⚠️ Le filtre de véhicule n'est plus ici : il a rejoint
    // `favouritesAllowingPickup`, où la lecture Fleetbase se fait déjà. Le
    // compte applicatif ne sert plus qu'à une chose — savoir qui a une
    // application capable de recevoir la course.
    const accounts = await this.prisma.driverAccount.findMany({
      where: { fleetbaseDriverUuid: { in: uuids }, active: true },
    });
    if (!accounts.length) return null;

    // La disponibilité fait foi côté Fleetbase, pas côté BFF : c'est lui qui
    // décide à qui le dispatch parle.
    //
    // Une lecture par favori, en parallèle, plutôt qu'un parcours de tout
    // l'annuaire (journal §24) : le coût suit le nombre de favoris de ce
    // commerçant — un ou deux en pratique — au lieu de la taille du réseau.
    //
    // ⚠️ `online` doit rester **strictement** `true`. Un favori dont la lecture
    // échoue ou qui a disparu n'est pas « peut-être disponible » : le laisser
    // passer enverrait la course à quelqu'un qui ne la verra jamais, et elle
    // resterait bloquée là. Mieux vaut le repli sur le pool.
    let online: Set<string>;
    try {
      const resolved = await Promise.all(
        accounts.map((a: any) => this.fleetbaseClient.getDriverByUuid(a.fleetbaseDriverUuid)),
      );
      online = new Set(
        resolved.filter((d: any) => d?.online === true).map((d: any) => d.uuid),
      );
    } catch (error) {
      this.logger.warn(`Favoris non résolus, repli sur le pool : ${error.message}`);
      return null;
    }

    const onlineAccounts = accounts.filter((a: any) => online.has(a.fleetbaseDriverUuid));

    // ⚠️ **La zone déclarée écarte aussi d'une sollicitation, pas seulement
    // d'une liste** (décision produit du 02/08/2026 : le rayon gouverne les
    // notifications, pas que l'affichage).
    //
    // C'est ici que ça compte le plus, et l'argument est **exactement celui que
    // ce fichier fait déjà pour `online`** : assigner pose
    // `driver_assigned_uuid`, donc **sort la course du pool**. La confier à
    // quelqu'un qui a filtré cette wilaya, c'est la confier à quelqu'un qui ne
    // la regardera pas — et rien ne la reprend (voir la limite décrite plus
    // haut). Le repli, lui, est sans danger : la course part au pool.
    //
    // Même biais qu'ailleurs : `zoneAllowsPickup` laisse passer tout ce qu'il
    // ignore — zone illisible, course sans wilaya, conducteur sans position.
    // Un favori n'est jamais écarté par une préférence qu'on n'a pas su lire.
    const available = await this.favouritesAllowingPickup(onlineAccounts, pickup, vehicleType);

    // ⚠️ Un plafond de dette écartait ici les favoris qui détenaient déjà trop
    // d'espèces. Retiré le 03/08/2026 avec le registre de caisse : sans
    // registre des remises, « ce qu'il détient encore » n'est pas calculable,
    // et un plafond assis sur autre chose aurait borné la mauvaise exposition
    // (`docs/registre_caisse_precis.md`).
    //
    // Ce qui reste ici — en ligne, et la zone déclarée — est de la logistique :
    // qui peut effectivement aller chercher ce colis.
    if (available[0]) return asDriverPick(available[0]);
    return this.pickFleetFavourite(vendorUuid);
  }

  /**
   * Un favori **entreprise** disponible, quand aucun conducteur favori ne l'est.
   *
   * ── L'ordre est une décision produit, et c'est un défaut par défaut ───────
   *
   * ⚠️ **Les conducteurs passent avant les entreprises.** Le motif est qu'un
   * conducteur est immédiatement actionnable — la course part à quelqu'un —,
   * alors qu'une entreprise ajoute un temps : elle doit encore désigner le
   * sien, et tant qu'elle ne l'a pas fait la course n'avance pas.
   *
   * Ce n'est pas une évidence : « je fais confiance à cette société » est une
   * préférence aussi légitime que « je fais confiance à cette personne », et un
   * commerçant qui met les deux en favori peut vouloir l'inverse. **À trancher
   * avec le produit** ; l'ordre se renverse en échangeant les deux appels, et
   * rien d'autre ne dépend de ce choix.
   *
   * ── Ce qui remplace la disponibilité ─────────────────────────────────────
   *
   * Une entreprise n'est ni en ligne ni hors ligne — la notion n'existe que
   * pour un conducteur. L'équivalent est son **compte actif** : c'est ce qui
   * dit qu'elle peut se connecter, voir la course et y affecter quelqu'un.
   * Exiger davantage — par exemple qu'elle ait un conducteur libre — voudrait
   * dire décider à sa place, ce que le §6.1 de `specs_facilitateur.md` écarte
   * explicitement.
   */
  private async pickFleetFavourite(vendorUuid: string): Promise<PickedFavourite | null> {
    const favourites = (await this.favourites.readOrNone(vendorUuid))
      .filter((f) => f.party_type === 'fleet');
    if (!favourites.length) return null;

    const fleets = await this.prisma.fleetAccount.findMany({
      where: {
        fleetbaseVendorUuid: { in: favourites.map((f) => f.party_uuid) },
        active: true,
      },
      select: { id: true, fleetbaseVendorUuid: true },
    });
    if (!fleets.length) return null;

    // ⚠️ Le pendant du plafond conducteur, retiré le 03/08/2026 pour le même
    // motif. Une entreprise active est éligible ; ce qu'elle détient en
    // espèces ne nous regarde plus.
    return fleets[0] ? asFleetPick(fleets[0]) : null;
  }

  /**
   * Catégories acceptables pour une exigence donnée.
   *
   * Une exigence est un **minimum**, pas une égalité : demander une voiture
   * n'exclut pas un utilitaire. Traiter le champ comme une égalité stricte
   * écarterait des transporteurs parfaitement capables.
   */
  private compatibleVehicleTypes(required: string): { in: string[] } {
    const ladder = ['moto', 'voiture', 'utilitaire'];
    const index = ladder.indexOf(required);
    return { in: index < 0 ? ladder : ladder.slice(index) };
  }

  /**
   * Devis d'une course, avant sa création.
   *
   * ── Pourquoi cet endpoint existe alors qu'aucune formule n'est écrite ───────
   *
   * Pour que l'appel soit **déjà en place** le jour où le barème sera tranché :
   * l'app interroge, affiche ce qu'on lui répond, et n'aura pas à changer.
   * Aujourd'hui `amount` vaut `null` et l'app garde sa saisie manuelle ; demain
   * il portera un montant calculé et la saisie s'effacera d'elle-même.
   *
   * Poser la couture avant la formule évite le scénario habituel : un barème
   * décidé, puis trois semaines à recâbler les écrans pour l'afficher.
   *
   * Les entrées retenues sont renvoyées avec le devis — distance, horaire — pour
   * que le commerçant voie sur quoi le montant repose, et pas seulement le
   * montant.
   */
  async quoteOrder(merchantId: string, dto: QuoteRequestDto) {
    await this.getMerchantWithValidation(merchantId);

    const quote = this.pricing.quote({
      pickupLatitude: dto.pickupLatitude,
      pickupLongitude: dto.pickupLongitude,
      dropoffLatitude: dto.dropoffLatitude,
      dropoffLongitude: dto.dropoffLongitude,
      scheduledAt: dto.scheduledAt,
      vehicleType: dto.vehicleType,
    });

    return {
      amount: quote.amount,
      currency: quote.currency,
      source: quote.source,
      distanceMetres: quote.inputs.distance_metres,
      distanceMethod: quote.inputs.distance_method,
    };
  }

  // ── Transporteurs favoris ─────────────────────────────────────────────────

  async listFavourites(merchantId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    // ⚠️ `read` et non `readOrNone` : ici une liste vide est une INFORMATION
    // affichée (« aucun transporteur favori »). Un défaut de lecture déguisé en
    // absence ferait croire au commerçant qu'il a perdu sa liste (règle 10).
    const favourites = await this.favourites.read(merchant.fleetbaseVendorUuid);
    return {
      // ⚠️ `driver_uuid` garde son nom : c'est le contrat que l'application lit
      // déjà, et le renommer casserait l'écran des favoris pour un gain de
      // vocabulaire. `party_type` s'ajoute à côté — un écran qui l'ignore
      // continue de fonctionner exactement comme avant, ce qui est la seule
      // façon d'étendre un contrat sans coordonner un déploiement.
      // ⚠️ **`(f: any)` a coûté un défaut réel le 03/08/2026.** La source est
      // passée de Prisma aux champs personnalisés du vendor, les noms de
      // champs ont changé (`partyType` → `party_type`), et le `any` a fait
      // taire le compilateur : la route rendait une liste de lignes dont
      // TOUTES les valeurs étaient `undefined`, avec un HTTP 200. Le banc
      // d'appartenance l'a vue comme « aucune ressource », ce qui accusait le
      // décor. Typé, maintenant.
      data: favourites.map((f) => ({
        // L'identifiant EST l'uuid de la partie : c'est ce que la route de
        // suppression attend, et l'application le renvoie tel quel.
        id: f.party_uuid,
        party_type: f.party_type,
        driver_uuid: f.party_uuid,
        name: f.party_name ?? null,
      })),
    };
  }

  /**
   * Transporteurs proposables en favori : ceux qui ont déjà livré pour ce
   * commerçant.
   *
   * Volontairement restreint à l'historique plutôt qu'à l'annuaire complet de
   * l'organisation. Exposer tous les transporteurs à tous les commerçants
   * livrerait la composition du réseau à quiconque crée un compte, et n'a
   * aucune utilité : on ne met en favori que quelqu'un qu'on a vu travailler.
   */
  async listKnownDrivers(merchantId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    const cached = await this.prisma.order.findMany({
      where: { merchantId },
      select: { fleetbaseOrderId: true },
    });
    const owned = new Set(cached.map((c: any) => c.fleetbaseOrderId));
    if (!owned.size) return { data: [] };

    let orders: any[] = [];
    try {
      orders = await this.fetchLiveOrders(cached, merchant.fleetbaseVendorUuid);
    } catch (error) {
      this.logger.warn(`Historique transporteurs indisponible : ${error.message}`);
      // Même raison que pour le carnet d'adresses : une liste vide se lit
      // « vous n'avez jamais travaillé avec personne », ce qui est faux.
      badRequest('merchant.known_drivers_unavailable',
        'Impossible de lire vos transporteurs habituels pour le moment.');
    }

    const seen = new Map<string, string | null>();
    for (const order of orders) {
      if (!owned.has(order?.uuid)) continue;
      const uuid = order?.driver_assigned_uuid ?? order?.driver_assigned?.uuid;
      if (uuid && !seen.has(uuid)) {
        seen.set(uuid, order?.driver_assigned?.name ?? null);
      }
    }

    return {
      data: Array.from(seen.entries()).map(([uuid, name]) => ({
        driver_uuid: uuid,
        name,
      })),
    };
  }

  /**
   * Cherche un transporteur du réseau par nom ou téléphone.
   *
   * ── Ce qui n'est pas renvoyé, et pourquoi ───────────────────────────────────
   *
   * **Pas le téléphone.** Le commerçant qui cherche le connaît déjà — c'est par
   * là qu'il cherche. Le renvoyer transformerait la recherche en moyen de
   * récupérer les coordonnées de prestataires indépendants qu'on n'a jamais
   * fait travailler.
   *
   * **Pas de liste tronquée.** Au-delà de dix correspondances, on demande de
   * préciser plutôt que d'en montrer dix : une liste tronquée qu'on peut
   * balayer en changeant une lettre est exactement l'annuaire qu'on refuse
   * d'ouvrir. « Précisez » ferme ce chemin sans gêner personne — celui qui
   * connaît la personne tape un nom, pas une lettre.
   */
  async searchDrivers(merchantId: string, query: string) {
    await this.getMerchantWithValidation(merchantId);

    // Envoyé tel quel : c'est Fleetbase qui cherche désormais, et son
    // `searchWhere` est un LIKE SQL — le forcer en minuscules ne servait que la
    // comparaison en mémoire, qui n'existe plus.
    const q = query.trim();

    // ⚠️ La recherche porte sur l'annuaire FLEETBASE, pas sur les comptes
    // applicatifs.
    //
    // La première version interrogeait `DriverAccount`, et ne trouvait presque
    // rien : cette table ne contient que les transporteurs **ayant déjà créé
    // leur compte dans l'application**, avec un nom qu'ils ont saisi eux-mêmes
    // à l'inscription — souvent vide, et sans rapport garanti avec celui que
    // l'opérateur voit dans la console. Deux critères cachés, donc, dont aucun
    // n'était visible du commerçant.
    //
    // L'annuaire qui fait autorité est celui de Fleetbase : c'est là que
    // l'opérateur crée les transporteurs, c'est ce nom qu'il communique, et
    // c'est l'uuid Fleetbase que `DriverFavourite` référence de toute façon.
    // ── La recherche est déléguée à Fleetbase (Lot 1) ────────────────────────
    //
    // `?query=` fait un `searchWhere(['name','email','phone'])` à travers la
    // relation `user` — le téléphone est donc couvert, sans passer par le
    // filtre `phone` qui, lui, renvoie 500 (bug amont, §5.1).
    //
    // Ce n'est pas qu'une économie. La version précédente appelait
    // `getAllDrivers()` **sans pagination** : au-delà de la taille de page par
    // défaut de Fleetbase, des transporteurs devenaient introuvables sans
    // qu'aucune erreur ne le signale — un commerçant aurait cherché quelqu'un
    // d'existant et conclu qu'il n'était pas sur le réseau. Même famille que le
    // plafond de 100 sur les commandes.
    //
    // On demande 11 résultats pour une limite de 10 : le onzième ne sert qu'à
    // savoir qu'il y en a trop, et n'est jamais renvoyé.
    let matches: any[] = [];
    try {
      const response = await this.fleetbaseClient.getAllDrivers({ query: q, limit: 11 });
      matches = this.fleetbaseClient.extractCollection(response, 'drivers');
    } catch (error) {
      this.logger.warn(`Annuaire transporteurs indisponible : ${error.message}`);
      badRequest('driver.search_unavailable', 'Recherche indisponible pour le moment');
    }

    // Repli sur les chiffres seuls : une saisie comme « 0555 12 34 » ne trouve
    // rien côté serveur si l'enregistrement est écrit « +2135551234 ». Le
    // rapatriement reste borné et ne se déclenche que sur un échec.
    if (matches.length === 0 && subscriberDigits(q).length >= 4) {
      try {
        // Paginé, et comparé sur les chiffres NORMALISÉS : la version
        // précédente plafonnait à 100 conducteurs et comparait les chiffres
        // bruts — elle échouait donc sur l'exemple même de ce commentaire,
        // « 0555 12 34 » contre « +2135551234 ».
        const wide = await this.fleetbaseClient.fetchEveryDriverMatching();
        matches = wide.filter((d: any) => phoneContains(d?.phone, q));
      } catch {
        // Le repli est un bonus : son échec ne doit pas casser la recherche.
      }
    }

    // ── Les entreprises de transport, cherchées CHEZ NOUS ──────────────────
    //
    // Pas dans l'annuaire Fleetbase, et c'est le même critère que celui qu'
    // `addFavourite` applique : un `Vendor` peut y exister sans être une
    // entreprise inscrite sur la plateforme — un opérateur en crée pour
    // d'autres usages. La proposer serait proposer quelqu'un qui ne peut
    // recevoir aucune course, faute de compte pour se connecter.
    //
    // ⚠️ **Le prestataire plateforme est exclu.** Echango est déjà le
    // facilitateur par défaut de toute course du pool : le mettre en favori ne
    // changerait rien, et l'afficher dans une liste de prestataires « qu'on
    // choisit » ferait croire à un choix qui n'en est pas un.
    // ⚠️ **La recherche se fait chez Fleetbase, l'appartenance chez nous**
    // (03/08/2026). Le nom vit sur le `Vendor` ; le BFF, lui, est le seul à
    // savoir lesquels de ces vendors sont des entreprises de transport — chez
    // Fleetbase, un commerçant et une entreprise sont le même objet.
    //
    // ⚠️ `query=` est **mesuré** honoré, avec témoin : 456 vendors, 1 résultat
    // sur un fragment réel, 0 sur un fragment inventé. Un filtre abandonné en
    // silence aurait rendu les 456 comme si c'était la réponse.
    let fleets: { fleetbaseVendorUuid: string; businessName: string | null }[] = [];
    if (q.length >= 2) {
      const vendors = await this.fleetbaseClient.searchVendors(q);
      const parUuid = new Map<string, string | null>(
        vendors.map((v: any) => [v?.uuid, typeof v?.name === 'string' ? v.name : null]),
      );

      const comptes = parUuid.size
        ? await this.prisma.fleetAccount.findMany({
            where: {
              active: true,
              isPlatform: false,
              fleetbaseVendorUuid: { in: [...parUuid.keys()].filter(Boolean) },
            },
            select: { fleetbaseVendorUuid: true },
            take: 11,
          })
        : [];

      fleets = comptes.map((f: any) => ({
        fleetbaseVendorUuid: f.fleetbaseVendorUuid,
        businessName: parUuid.get(f.fleetbaseVendorUuid) ?? null,
      }));
    }

    // Le plafond porte sur le TOTAL, pas sur chaque famille : c'est une seule
    // liste à l'écran, et « trop de résultats » se juge sur ce qu'elle
    // afficherait. Compter séparément laisserait passer 10 + 10.
    if (matches.length + fleets.length > 10) {
      return { data: [], too_many: true };
    }

    // Le compte applicatif, quand il existe, apporte la catégorie de véhicule
    // — et surtout son absence est une information : un transporteur sans
    // compte ne recevra aucune course, et le taire ferait d'une mise en favori
    // un geste sans effet.
    const accounts = await this.prisma.driverAccount.findMany({
      where: { fleetbaseDriverUuid: { in: matches.map((d: any) => d.uuid) } },
      select: { fleetbaseDriverUuid: true, active: true },
    });
    const byUuid = new Map<string, any>(
      accounts.map((a: any) => [a.fleetbaseDriverUuid, a]),
    );

    return {
      // ⚠️ `driver_uuid` garde son nom pour les DEUX familles : c'est la clé que
      // l'application lit déjà, et la renommer casserait l'écran des favoris
      // pour un gain de vocabulaire. `party_type` s'ajoute à côté — un écran
      // qui l'ignore continue de fonctionner comme avant.
      data: [
        ...matches.map((d: any) => {
          const account = byUuid.get(d.uuid);
          return {
            party_type: 'driver',
            driver_uuid: d.uuid,
            name: d.name ?? null,
            // ⚠️ **Plus servi depuis le 03/08/2026**, et le retirer est un
            // choix, pas un oubli. La catégorie vit maintenant dans les champs
            // personnalisés du conducteur chez Fleetbase : la servir ici
            // demanderait **un appel par résultat de recherche**, pour un
            // champ que l'écran de recherche n'affiche pas.
            //
            // Le compte applicatif reste interrogé — son absence, elle, est une
            // information : un transporteur sans compte ne recevra aucune
            // course, et le taire ferait d'une mise en favori un geste sans
            // effet.
            // Le téléphone n'est jamais renvoyé : celui qui cherche le connaît
            // déjà, c'est par là qu'il cherche.
            has_account: Boolean(account?.active),
          };
        }),
        ...fleets.map((f: any) => ({
          party_type: 'fleet',
          driver_uuid: f.fleetbaseVendorUuid,
          name: f.businessName ?? null,
          // Une entreprise n'a pas de catégorie de véhicule : c'est son
          // conducteur qui en aura une, et il n'est pas encore désigné. `null`
          // plutôt qu'une valeur inventée (règle 10).
          //
          // ⚠️ Le type est écrit, et il le faut : un `null` nu dans un littéral
          // d'objet n'a pas de type inférable, et `nest build` le refuse
          // (`TS7018`) là où `tsc --noEmit` l'accepte — les deux ne lisent pas
          // la même configuration. Sans lui, le champ perdrait aussi sa forme
          // pour l'appelant, qui lit `string | null` sur l'autre branche.
          vehicle_type: null as string | null,
          // Vrai par construction : la requête ne rend que des `FleetAccount`
          // actifs. Le champ garde son sens — « peut recevoir une course ».
          has_account: true,
        })),
      ],
      too_many: false,
    };
  }

  async addFavourite(
    merchantId: string,
    fleetbaseDriverUuid: string,
    driverName?: string,
    partyType: 'driver' | 'fleet' = 'driver',
  ) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    // ── Une entreprise se vérifie chez NOUS, pas dans l'annuaire Fleetbase ──
    //
    // Un `Vendor` peut exister chez Fleetbase sans être une entreprise inscrite
    // sur la plateforme — un opérateur en crée pour d'autres usages. La mettre
    // en favori n'aurait alors aucun sens : elle ne peut recevoir aucune course,
    // faute de compte pour se connecter. Le critère est donc le `FleetAccount`
    // **actif**, qui est exactement « fait partie du réseau ».
    if (partyType === 'fleet') {
      const fleet = await this.prisma.fleetAccount.findUnique({
        where: { fleetbaseVendorUuid: fleetbaseDriverUuid },
        select: { id: true, active: true },
      });

      if (!fleet || !fleet.active) {
        this.audit.denied({
          actorType: 'merchant',
          actorId: merchantId,
          action: 'favourite.add',
          resourceType: 'FleetAccount',
          resourceId: fleetbaseDriverUuid,
          reason: 'Entreprise inexistante ou inactive dans le réseau',
        });
        badRequest(
          'merchant.fleet_not_in_network',
          "Cette entreprise n'existe pas dans le réseau Echango",
        );
      }

      // Le nom vient du serveur, comme pour un conducteur : une liste de favoris
      // doit décrire des entités réelles, pas les étiquettes de son auteur.
      // ⚠️ Le nom vient du `Vendor`, plus de la copie locale : c'est lui qui
      // fait foi, et un opérateur qui corrige une raison sociale en console
      // doit voir la correction se propager aux listes de favoris.
      const identite = await this.fleetbaseClient.getVendorIdentity(fleetbaseDriverUuid);
      await this.favourites.add(merchant.fleetbaseVendorUuid, {
        party_type: 'fleet',
        party_uuid: fleetbaseDriverUuid,
        party_name: identite?.name ?? driverName ?? null,
      });
      return { added: true };
    }

    // Le transporteur doit exister dans le réseau et y être actif.
    //
    // La règle précédente — « il doit avoir déjà livré pour vous » — a été
    // levée le 29/07 : elle rendait les favoris inaccessibles à tout nouveau
    // commerçant, et supposait que la seule façon de connaître un transporteur
    // soit de l'avoir vu travailler. On peut aussi l'avoir croisé, ou se l'être
    // fait recommander.
    //
    // Ce contrôle-ci demeure, sous une autre forme : il empêche de sonder
    // l'existence d'un uuid arbitraire, et de mettre en favori quelqu'un qui a
    // quitté le réseau.
    // Contrôlé contre l'annuaire Fleetbase, comme la recherche : viser
    // `DriverAccount` ici aurait refusé tout transporteur qui n'a pas encore
    // installé l'application — c'est-à-dire précisément ceux que la recherche
    // vient de proposer.
    //
    // Lecture unitaire (journal §24) : un seul appel, et l'uuid renvoyé est
    // vérifié côté client Fleetbase.
    let driver: any = null;
    try {
      driver = await this.fleetbaseClient.getDriverByUuid(fleetbaseDriverUuid);
    } catch (error) {
      this.logger.warn(`Annuaire transporteurs indisponible : ${error.message}`);
      badRequest('merchant.favourite_add_unavailable', 'Ajout impossible pour le moment');
    }

    if (!driver) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'favourite.add',
        resourceType: 'Driver',
        resourceId: fleetbaseDriverUuid,
        reason: 'Transporteur inexistant ou inactif dans le réseau',
      });
      badRequest('merchant.driver_not_in_network', 'Ce transporteur n\'existe pas dans le réseau Echango');
    }

    // Le nom vient du serveur, jamais de la requête : sinon un commerçant
    // pourrait enregistrer n'importe quelle étiquette sur n'importe qui, et sa
    // liste de favoris cesserait de décrire des personnes réelles.
    const resolvedName = driver.name ?? driverName;

    await this.favourites.add(merchant.fleetbaseVendorUuid, {
      party_type: 'driver',
      party_uuid: fleetbaseDriverUuid,
      party_name: resolvedName,
    });
    return { added: true };
  }

  async removeFavourite(merchantId: string, favouriteId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    // ⚠️ L'appartenance est **structurelle** depuis que les favoris vivent sur
    // le vendor : on ne lit et n'écrit que la liste de CE commerçant, donc il
    // n'y a plus d'identifiant global qui puisse désigner le favori d'un
    // autre. La version précédente devait filtrer sur `merchantId` pour ça.
    //
    // ⚠️ Et `favouriteId` est désormais l'**uuid de la partie**, plus un cuid
    // local — c'est ce que `listFavourites` sert sous la clé `id`, donc
    // l'application renvoie ce qu'on lui a donné et le contrat ne bouge pas.
    const removed = await this.favourites.remove(merchant.fleetbaseVendorUuid, favouriteId);

    if (!removed) {
      notFound('merchant.favourite_not_found', 'Favori introuvable');
    }
    return { removed: true };
  }

  /**
   * Résout une commande du commerçant par l'un OU l'autre de ses identifiants,
   * et vérifie l'appartenance.
   *
   * ⚠️ Deux identifiants coexistent : le `cuid` local (renvoyé à la création)
   * et l'`uuid` Fleetbase (présent partout ailleurs). L'app envoie l'uuid, or
   * `cancelOrder` et `getOrderTracking` cherchaient le cuid — les deux
   * répondaient donc **404 systématiquement**, et le suivi échouait en
   * silence côté client (revue archi #3). `getOrderDetail` faisait déjà la
   * bonne chose ; ce helper évite que les trois divergent à nouveau.
   *
   * L'appartenance est décidée **ici**, sur la table locale. Le motif invoqué
   * (§2.8, « Fleetbase ignore les filtres ») est faux depuis le 29/07/2026 —
   * mais décider l'appartenance localement reste juste : un paramètre d'URL
   * n'est pas une frontière de sécurité. Voir
   * `docs/architecture_bff_fleetbase.md` §4.3.
   */
  private async resolveOwnedOrder(merchantId: string, orderId: string) {
    const order = await this.prisma.order.findFirst({
      where: { OR: [{ id: orderId }, { fleetbaseOrderId: orderId }] },
    });

    if (!order) {
      notFound('order.not_found', 'Order not found');
    }

    if (order.merchantId !== merchantId) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'order.access',
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Commande appartenant à un autre commerçant',
      });
      forbidden('order.forbidden', 'You do not have access to this order');
    }

    return order;
  }

  async getOrderDetail(merchantId: string, orderId: string) {
    this.logger.log(`Fetching order ${orderId} for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    const merged = await this.detailedOrder(order, merchant.fleetbaseVendorUuid);

    // ⚠️ L'encaissement déclaré à la porte n'est plus lu à part : depuis le
    // 03/08/2026 il vit dans les champs personnalisés de la commande, donc il
    // arrive déjà dans `meta` (`collected_amount`, `collected_at`,
    // `collection_reason`). Une seconde lecture serait une seconde source pour
    // la même donnée — exactement ce que la règle 1 interdit.
    // ⚠️ Les échecs se lisent sur la commande FUSIONNÉE, pas sur le cache : ils
    // vivent dans ses champs personnalisés depuis le 03/08/2026, et `merged`
    // est ce qui les porte.
    //
    // ⚠️ **Et ils se lisent sur le BRUT, pas sur le projeté — corrigé le
    // 03/08/2026.** `failuresFor` s'appliquait à la valeur de `detailedOrder`,
    // qui est **déjà projetée** ; or `delivery_failures` ne figure pas dans
    // `PROJECTED_META_FIELDS`, délibérément (l'app reçoit la forme expurgée,
    // avec un chemin de photo authentifié, pas la liste brute). La lecture
    // rendait donc **toujours** une liste vide : le commerçant ne voyait aucun
    // échec de livraison, et `GET .../preuves/:id` répondait 404 en toutes
    // circonstances.
    //
    // Aucune erreur, aucun journal — la capacité existait des deux côtés et ne
    // se rejoignait nulle part (règles 9 et 10). Trouvée en vérifiant une
    // revue de sécurité, pas à la relecture.
    return {
      ...(merged.projected as any),
      ...(merged.raw ? this.failuresFor(merged.raw) : {}),
    };
  }

  /**
   * La commande Fleetbase, `meta` recomposé depuis ses champs personnalisés.
   *
   * Un seul point de fusion pour tous les chemins de lecture : la liste, la
   * fiche, le modèle de duplication et la publication. Les disperser aurait
   * garanti qu'un chemin soit oublié — et celui qu'on oublie est toujours
   * celui qui décide d'un montant.
   *
   * ⚠️ Prenait un second argument, `Order.specMeta`, jusqu'au 03/08/2026 — la
   * copie locale de ce que le commerçant avait demandé. Elle est retirée : la
   * reprise a constaté 535 commandes sur 535 déjà complètes en amont, donc le
   * filet ne rattrapait plus rien.
   */
  private withEffectiveMeta(live: any): any {
    if (!live) return live;
    return { ...live, meta: effectiveOrderMeta(live) };
  }

  /**
   * La commande telle qu'une fiche de détail a besoin de la voir.
   *
   * ── Lecture unitaire : désigner la commande, pas la chercher ───────────────
   *
   * La console interroge la commande à l'unité (`GET /int/v1/orders/{id}` avec
   * ses relations) ; le BFF la prenait dans la liste paginée, en parcourant
   * jusqu'à cinquante pages pour retrouver celle qu'il connaît déjà par son
   * uuid. Désigner coûte un appel, chercher en coûte autant que l'organisation
   * a de commandes — et un parcours peut manquer sa cible, ce qu'une lecture
   * unitaire ne peut pas faire.
   *
   * ⚠️ **Ce n'est PAS ce qui a vidé la fiche du 30/07/2026**, et il faut le
   * dire ici pour que personne ne recycle l'explication. L'hypothèse était que
   * la liste n'aurait pas servi `meta` ; le source Fleetbase l'invalide —
   * `OrderResource::toArray()` renvoie `meta` et `payload` (avec `pickup`,
   * `dropoff`, `entities`) **sans condition**, et la même classe sert les deux
   * routes. La fiche était incomplète parce que l'écran ne lisait pas ces
   * champs, corrigé côté Flutter (`548087c`) et constaté à l'écran.
   *
   * ── Le repli n'est pas de la prudence gratuite ─────────────────────────────
   *
   * `mergeWithFleetbase` porte deux comportements que la lecture unitaire n'a
   * pas : le drapeau `stale` quand Fleetbase est injoignable, et `missing`
   * quand la commande a disparu. Les deux se voient à l'écran (« État
   * indisponible ») au lieu de faire échouer la fiche. Y retomber garantit
   * qu'un défaut de la lecture unitaire dégrade l'affichage au lieu de le
   * casser.
   *
   * ── Deux formes, et il en FALLAIT deux (03/08/2026) ───────────────────────
   *
   * `projected` sort par la route ; `raw` ne sort jamais et sert à lire ce que
   * la projection retire — aujourd'hui les seuls `delivery_failures`.
   *
   * ⚠️ Cette fonction ne rendait que le projeté, et ses deux appelants avaient
   * besoin du brut sans le savoir : ils lisaient `meta.delivery_failures` sur
   * un objet d'où la liste d'autorisation venait de le retirer. Le résultat
   * était **toujours vide**, sans erreur ni journal.
   *
   * ⚠️ `raw` est `null` sur la branche de repli, et ce n'est pas un oubli : le
   * repli passe par la LISTE Fleetbase, qui ne sert **aucun champ
   * personnalisé** (piège §3.1 de `docs/ou_vit_quoi.md`). Prétendre y lire des
   * échecs rendrait une liste vide qu'on croirait complète — dire `null` force
   * l'appelant à distinguer « aucun échec » de « je n'ai pas pu regarder »
   * (règle 10).
   */
  private async detailedOrder(
    order: { id: string; fleetbaseOrderId: string },
    vendorUuid: string,
  ): Promise<{ projected: any; raw: any | null }> {
    const live = await this.liveOrderDetailed(order, vendorUuid);
    if (live) {
      return { projected: projectOrderForMerchant(live, { bff_order_id: order.id }), raw: live };
    }

    const [merged] = await this.mergeWithFleetbase([order], vendorUuid);
    return { projected: merged, raw: null };
  }

  /**
   * La commande Fleetbase **brute et complète**, ou `null`.
   *
   * Partagée par les usages qui ont besoin de la commande entière : la fiche
   * de détail, le modèle de duplication, et la publication — cette dernière
   * lisant `prefer_favourites`, `vehicle_type` et `cod_amount` pour décider à
   * quel favori confier la course. Un `meta` manquant y serait plus qu'un
   * affichage incomplet : il changerait l'attribution.
   *
   * La garde sur l'uuid n'est pas décorative : cet objet décide de qui reçoit
   * la course. Même principe que `getDriverByUuid` — sur un doute d'enveloppe
   * ou une régression amont, le pire cas doit être « introuvable », jamais
   * « la commande de quelqu'un d'autre ».
   *
   * `null` plutôt qu'une exception : chaque appelant a son propre repli, et
   * aucun ne doit échouer sur une lecture d'agrément.
   */
  private async liveOrderDetailed(
    order: { fleetbaseOrderId: string },
    vendorUuid: string,
  ): Promise<any | null> {
    try {
      const response = await this.fleetbaseClient.getOrderWithRelations(order.fleetbaseOrderId);
      // Fleetbase enveloppe tantôt sous `order`, tantôt à plat — même
      // tolérance qu'ailleurs dans ce fichier.
      const live = response?.order ?? response;

      // Uuid absent ou différent : on ne sert pas la commande de quelqu'un
      // d'autre sur un doute. Même garde que `getDriverByUuid`.
      //
      // La fusion a lieu ici, et non chez chaque appelant : c'est le point de
      // passage unique des cinq lectures unitaires (fiche, preuve, position,
      // duplication, publication). Une fusion recopiée cinq fois aurait fini
      // par en manquer une.
      if (live?.uuid === order.fleetbaseOrderId) return this.withEffectiveMeta(live);

      this.logger.warn(
        `Lecture unitaire inexploitable pour ${order.fleetbaseOrderId} — repli sur la liste`,
      );
    } catch (error: any) {
      this.logger.warn(
        `Lecture unitaire échouée pour ${order.fleetbaseOrderId} (${error.message}) — repli sur la liste`,
      );
    }

    // Repli sur la liste. Elle porte en principe les mêmes champs (le même
    // `OrderResource` sert les deux routes), mais elle est parcourue page par
    // page et peut manquer une commande là où la lecture unitaire la désigne :
    // mieux vaut une fiche éventuellement partielle qu'un écran en erreur.
    return this.liveOrderFor(vendorUuid, order)
      .then((live) => this.withEffectiveMeta(live))
      .catch((): any => null);
  }

  /**
   * Les signalements d'échec d'une commande, tels que le commerçant les voit.
   *
   * ⚠️ **Ne fait plus aucune requête depuis le 03/08/2026** : les échecs vivent
   * sur la commande, donc ils arrivent avec `meta`. Le format servi ne change
   * pas — `delivery_failure` et `delivery_failures`, les clés que l'application
   * lit déjà.
   */
  private failuresFor(live: any): Record<string, any> {
    return projectFailures(live, 'commercant');
  }

  /**
   * Photo d'un signalement d'échec, servie au commerçant propriétaire.
   *
   * ── L'appartenance est STRUCTURELLE depuis le 03/08/2026 ─────────────────
   *
   * La route porte l'uuid de la **commande** : servir la preuve exige de la
   * résoudre, donc de traverser `resolveOwnedOrder()`, qui vérifie déjà qu'elle
   * est à ce commerçant. La version précédente cherchait le signalement par son
   * identifiant seul, puis vérifiait le propriétaire en deux temps — un contrôle
   * qui reposait sur le fait que son auteur y avait pensé.
   */
  async getFailureProof(merchantId: string, orderId: string, failureId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    const order = await this.resolveOwnedOrder(merchantId, orderId);
    const { raw } = await this.detailedOrder(order, merchant.fleetbaseVendorUuid);

    // ⚠️ `raw` seul : la preuve se lit dans `meta.delivery_failures`, que la
    // projection retire. Cette route répondait 404 en TOUTES circonstances
    // jusqu'au 03/08/2026, parce qu'elle cherchait dans le projeté.
    const failure = raw ? findFailure(raw, failureId) : undefined;

    if (!failure?.proof_url) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'proof.access',
        resourceType: 'DeliveryFailure',
        resourceId: failureId,
        reason: 'Signalement inexistant sur cette commande, ou sans preuve',
      });
      notFound('order.proof_not_found', 'Aucune preuve pour ce signalement');
    }

    try {
      return await this.fleetbaseClient.fetchStoredFile(failure.proof_url);
    } catch (error: any) {
      this.logger.warn(
        `Lecture de la preuve ${failureId} impossible (${failure.proof_url}) : ${error.message}`,
      );
      notFound('order.proof_not_found', 'Preuve indisponible');
    }
  }

  /**
   * Preuve de livraison de la commande, servie au commerçant.
   *
   * ⚠️ Dépend de `proof_url` sur la commande Fleetbase, **dont le
   * renseignement n'est pas vérifié** : la preuve capturée par le transporteur
   * crée bien une ressource `Proof`, mais que Fleetbase reporte son URL sur la
   * commande elle-même reste à confirmer sur une livraison réelle. Si ce champ
   * reste vide, la route répond « pas de preuve » — ce qui est indiscernable,
   * pour l'appelant, d'une livraison sans preuve exigée. C'est le premier point
   * à observer sur une vraie livraison avec `pod_required`.
   */
  async getOrderProof(merchantId: string, orderId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    const live = await this.liveOrderDetailed(order, merchant.fleetbaseVendorUuid);

    if (!live?.proof_url) {
      notFound('order.proof_not_found', 'Aucune preuve enregistrée pour cette livraison');
    }

    try {
      return await this.fleetbaseClient.fetchStoredFile(live.proof_url);
    } catch (error) {
      this.logger.warn(`Preuve de ${orderId} illisible : ${error.message}`);
      notFound('order.proof_not_found', 'Preuve indisponible');
    }
  }

  /**
   * Dernière position connue du transporteur affecté à cette commande.
   *
   * ── Ce que cette route est, et n'est pas ────────────────────────────────────
   *
   * C'est un **point**, pas un suivi : la position que le transporteur a
   * remontée en dernier, avec sa date. Pas d'itinéraire, pas d'heure d'arrivée
   * estimée — celle-ci demande un moteur de routage (OSRM), non auto-hébergé à
   * ce stade. Attendre OSRM pour montrer quoi que ce soit reviendrait à laisser
   * le commerçant devant un statut textuel alors que la donnée est là.
   *
   * La fraîcheur est renvoyée avec le point, et ce n'est pas cosmétique : une
   * position vieille d'une heure affichée comme actuelle est pire qu'aucune
   * position. Le transporteur peut être hors ligne, en tunnel, ou avoir fermé
   * l'application.
   *
   * `null` plutôt qu'une erreur quand personne n'est encore affecté : c'est
   * l'état normal d'une course en attente, pas un échec.
   */
  async getOrderDriverPosition(merchantId: string, orderId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    const live = await this.liveOrderDetailed(order, merchant.fleetbaseVendorUuid);

    const driverUuid = live?.driver_assigned_uuid ?? live?.driver_assigned?.uuid;
    if (!driverUuid) return { position: null };

    // La position vit sur le conducteur Fleetbase, pas dans un miroir local
    // (Lot 6). `Position` est l'historique ; `Driver.location` est l'état
    // courant, mis à jour par le `track` que le BFF émet à chaque remontée GPS.
    let driver: any;
    try {
      driver = await this.fleetbaseClient.getDriverByUuid(driverUuid);
    } catch (error) {
      this.logger.warn(`Position du transporteur indisponible : ${error.message}`);
      return { position: null };
    }

    const position = readDriverPosition(driver);
    if (!position) return { position: null };

    return {
      position: {
        latitude: position.latitude,
        longitude: position.longitude,
        // Jamais omise : c'est elle qui dit si le point vaut quelque chose.
        // ⚠️ C'est un « vu le », pas un « positionné le » — voir
        // `readPositionSeenAt`.
        recorded_at: readPositionSeenAt(driver),
      },
    };
  }



  /**
   * Modèle de commande repris d'une livraison passée.
   *
   * ── Pourquoi un modèle, et non une commande créée directement ──────────────
   *
   * Une duplication silencieuse recopierait aussi ce qui ne se duplique pas :
   * un enlèvement programmé la veille à 8 h, une fois recréé, est dans le
   * passé. Le serveur renvoie donc les champs à reprendre, l'application
   * rouvre le formulaire pré-rempli, et le commerçant valide en connaissance de
   * cause. Un clic de plus, et aucune commande créée par accident — ce qui,
   * pour une livraison réelle facturée à quelqu'un, n'est pas un détail.
   *
   * `scheduledAt` est délibérément **absent** du modèle : c'est le seul champ
   * qu'on ne peut pas reprendre sans mentir, et le laisser vide fait retomber
   * sur « dès que possible », qui est vrai.
   */
  async getOrderTemplate(merchantId: string, orderId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    const cached = await this.resolveOwnedOrder(merchantId, orderId);

    // Lecture unitaire : la duplication reprend tout `meta` (catégorie de
    // véhicule, montant à encaisser, préférence de favoris, articles), et
    // désigner la commande vaut mieux que la chercher dans une liste paginée
    // qui peut la manquer.
    const live = await this.liveOrderDetailed(cached, merchant.fleetbaseVendorUuid);

    if (!live) {
      notFound('order.not_found_upstream', 'Commande introuvable chez Fleetbase');
    }

    const meta = live.meta ?? {};
    const place = (raw: any, prefix: 'pickup' | 'dropoff') => {
      if (!raw) return {};
      const coords = raw.location?.coordinates;
      const [longitude, latitude] = Array.isArray(coords) ? coords : [];
      return {
        [`${prefix}LocationName`]: raw.name ?? raw.address ?? null,
        [`${prefix}Latitude`]: typeof latitude === 'number' ? latitude : null,
        [`${prefix}Longitude`]: typeof longitude === 'number' ? longitude : null,
        [`${prefix}ContactName`]: raw.contact_name ?? raw.meta?.contact_name ?? null,
        [`${prefix}ContactPhone`]: raw.phone ?? raw.contact_phone ?? null,
        // ⚠️ **Les composantes d'adresse manquaient au modèle (02/08/2026).**
        //
        // Une duplication restaurait le point et le nom, mais **ni la commune,
        // ni le quartier, ni la wilaya** — elles ne repartaient donc pas avec
        // la copie. C'est le défaut déjà corrigé deux fois sur ce chemin
        // (`podMethod` et `preferFavourites` le 30/07, la quantité de colis le
        // 31/07) : un champ que la duplication ne relit pas disparaît en
        // silence.
        //
        // Il devient bloquant maintenant que la wilaya porte le filtre du
        // transporteur : une course dupliquée serait **invisible** à qui filtre
        // par wilaya, sans que rien ne le signale.
        [`${prefix}City`]: raw.city ?? null,
        [`${prefix}Province`]: raw.province ?? null,
        [`${prefix}Neighborhood`]: raw.neighborhood ?? null,
      };
    };

    return {
      ...place(live.payload?.pickup, 'pickup'),
      ...place(live.payload?.dropoff, 'dropoff'),
      pickupNotes: meta.pickup_notes ?? null,
      dropoffNotes: meta.dropoff_notes ?? null,
      deliveryInstructions: meta.instructions ?? null,
      items: Array.isArray(meta.items) ? meta.items : null,
      vehicleType: meta.vehicle_type ?? null,
      // `?? 'aucune'`, pas `?? null` : l'app envoie toujours l'un des deux
      // valeurs à la création (jamais de troisième état), et `pod_method`
      // n'est écrit chez Fleetbase QUE quand une preuve est exigée — son
      // absence est donc le signal fiable que « aucune » avait été choisi, pas
      // une valeur inconnue. Sans ce repli, la duplication d'une commande sans
      // preuve exigée faisait réapparaître « Photo à la livraison », le
      // défaut du formulaire de création, jamais le choix d'origine.
      podMethod: live.pod_method ?? 'aucune',
      // Reproduit tel quel : sans lui, une commande dupliquée sollicitait
      // toujours les favoris en premier, même quand la commande d'origine
      // avait délibérément visé le pool commun.
      preferFavourites: meta.prefer_favourites !== false,
      // Le prix est repris tel quel : c'est une proposition du commerçant, et
      // reproposer ce qui avait trouvé preneur est le comportement utile. S'il
      // avait été refusé pour insuffisance, l'écran de création reste
      // modifiable.
      price: typeof meta.price === 'number' ? meta.price : null,
      // Repris comme le reste : une boulangerie qui livre le même client
      // encaisse en général le même montant. Modifiable à l'écran.
      //
      // ⚠️ On rend le **prix de la marchandise**, jamais `cod_amount` : ce
      // dernier contient déjà la rémunération du transporteur quand le
      // commerçant l'a mise à la charge du destinataire. Le reprendre tel quel
      // le ferait ré-additionner à la création suivante — 1300 devient 1950,
      // puis 2600 —, et l'erreur se composerait à chaque duplication sans
      // jamais lever d'exception.
      //
      // Le repli sur `cod_amount` couvre les commandes d'avant ce champ, où
      // les deux montants étaient confondus.
      codAmount:
        typeof meta.cod_goods_amount === 'number'
          ? meta.cod_goods_amount
          : typeof meta.cod_amount === 'number'
            ? meta.cod_amount
            : null,
      codIncludesDelivery: meta.cod_includes_delivery === true,
    };
  }

  /**
   * Create a new delivery order
   */
  async createOrder(merchantId: string, dto: CreateOrderDto) {
    this.logger.log(`Creating order for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    // Calculé AVANT le `try`, et ce n'est pas un détail de style. Cette
    // fonction peut refuser (encaissement de la marchandise seule sans
    // rémunération connue), et à l'intérieur du `try` les deux `Place`
    // d'enlèvement et de livraison sont **déjà créés chez Fleetbase** : le
    // refus les laisserait orphelins, sans rien pour les reprendre. Refuser
    // avant la première écriture est la seule compensation qui ne coûte rien
    // (règles §2 et §3).
    const meta = this.buildOrderMeta(dto);

    try {
      // Fleetbase orders require pre-created Place records for pickup/dropoff,
      // referenced by UUID, plus a resolved order_config_uuid.
      //
      // ── L'ordre compte, et il est imposé par une décision produit ──────────
      //
      // **Pas de livraison enregistrée si ses données métier ne le sont pas.**
      // Prix, montant à encaisser et colis doivent vivre dans le stockage
      // durable, sinon la commande n'a pas lieu d'être : le commerçant la
      // croirait protégée, le transporteur agirait sur des montants qui
      // peuvent disparaître à la première action console.
      //
      // La configuration et ses définitions sont donc résolues **d'abord**, et
      // le refus tombe **avant** la création des deux `Place` — sans quoi il
      // les laisserait orphelins chez Fleetbase (règle §2).
      const orderConfigUuid = await this.fleetbaseClient.getDefaultOrderConfigUuid();
      const customFieldValues = await this.orderCustomFields.valuesFor(orderConfigUuid, meta);
      this.assertCustomFieldsComplete(meta, customFieldValues);

      const metaWithoutCustomFields = this.metaOutsideCatalogue(meta);

      const [pickupPlace, dropoffPlace] = await Promise.all([
        // Les contacts sont bien transmis : ils étaient saisis, validés, puis
        // jetés (voir createPlace). Un transporteur devant une porte sans
        // numéro à appeler ne peut que constater l'échec.
        this.fleetbaseClient.createPlace(
          dto.pickupLocationName,
          dto.pickupLatitude,
          dto.pickupLongitude,
          {
            name: dto.pickupContactName,
            phone: dto.pickupContactPhone,
            city: dto.pickupCity,
            // La wilaya voyage enfin jusqu'à la course : c'est elle qui portera
            // le filtre du transporteur (décision du 02/08/2026).
            province: dto.pickupProvince,
            neighborhood: dto.pickupNeighborhood,
          },
        ),
        this.fleetbaseClient.createPlace(
          dto.dropoffLocationName,
          dto.dropoffLatitude,
          dto.dropoffLongitude,
          {
            name: dto.dropoffContactName,
            phone: dto.dropoffContactPhone,
            // ⚠️ Commune et quartier, jamais la rue : sur une course non
            // réclamée, ces deux-là suffisent à juger un détour et ne
            // désignent aucune porte.
            city: dto.dropoffCity,
            province: dto.dropoffProvince,
            neighborhood: dto.dropoffNeighborhood,
          },
        ),
      ]);

      // Favori disponible ? On le sollicite ; sinon la course part au pool,
      // **y compris quand elle est encaissée**.
      //
      // Une version précédente réservait les courses encaissées aux favoris, au
      // motif qu'on ne confie pas d'espèces à quelqu'un qu'on n'a jamais vu
      // travailler. Le raisonnement supposait un pool anonyme — il ne l'est
      // pas : **les transporteurs sont sélectionnés et provisionnés par
      // Echango**, sur invitation nominative (voir `DriverInvitation`), et
      // aucun ne s'inscrit de lui-même. Le contrôle a donc déjà eu lieu, à
      // l'entrée dans le réseau, et le refaire par commerçant ne protégeait de
      // rien tout en interdisant l'encaissement à tout commerçant sans favori —
      // c'est-à-dire à tout nouveau commerçant.
      //
      // Le plafond de dette reste, lui : il ne présume rien de la personne, il
      // borne l'exposition. C'est le garde-fou qui fait le travail.
      //
      // ⚠️ Un brouillon (`dto.draft`) ne sollicite aucun favori à la création :
      // la décision de dispatch est tout entière différée à la publication
      // (`publishOrder`), au moment où elle a une chance de refléter une
      // disponibilité à jour plutôt que celle de l'instant de la saisie.
      //
      // ⚠️ Le plafond de dette est vérifié sur `meta.cod_amount` — le montant
      // réclamé à la porte — et non sur `dto.codAmount`, qui n'est que le prix
      // de la marchandise. C'est l'espèce que le transporteur portera qui
      // fonde l'exposition, livraison comprise. Prendre la saisie ici aurait
      // sous-estimé le plafond sur ce chemin et pas sur celui de
      // `publishOrder`, qui lit déjà `meta` : deux réponses différentes pour
      // la même course selon qu'elle passe ou non par un brouillon.
      const favourite = dto.preferFavourites && !dto.draft
        ? await this.pickAvailableFavourite(
            merchant.fleetbaseVendorUuid,
            dto.vehicleType,
            // ⚠️ Ici la commande n'existe PAS encore : le depart vient du
            // formulaire, pas d'une lecture. C'est la raison d'etre de
            // `OrderPickup` — meme regle, deux origines.
            {
              wilaya: dto.pickupProvince ?? null,
              point: { latitude: dto.pickupLatitude, longitude: dto.pickupLongitude },
            },
          )
        : null;

      // Les données métier partent DEUX fois, et ce n'est pas une duplication
      // gratuite (règle 1) : ce sont deux stockages aux propriétés opposées.
      //
      // - `custom_field_values` est le stockage **durable** : table séparée,
      //   synchronisée seulement si la requête la porte, donc intacte après
      //   n'importe quelle mise à jour de la commande. C'est la source servie
      //   aux applications.
      // - `meta` reste écrit pour les lecteurs qui l'attendent — l'historique
      //   des commandes d'avant cette migration, et tout intégrateur tiers.
      //   Il est fragile par construction, d'où sa place derrière.
      const response = await this.createOrderOrCleanUp({
        order_config_uuid: orderConfigUuid,
        customer_uuid: merchant.fleetbaseVendorUuid,
        customer_type: 'vendor',
        type: 'transport',
        payload: {
          pickup_uuid: pickupPlace.place.uuid,
          dropoff_uuid: dropoffPlace.place.uuid,
        },
        // ⚠️ `meta` ne porte plus que ce qui n'a PAS de champ personnalisé —
        // aujourd'hui `pricing_inputs` seul.
        //
        // Écrire les deux était juste tant que les champs personnalisés
        // pouvaient manquer. Depuis qu'une commande sans eux est **refusée**,
        // `meta` n'est plus un filet mais un doublon — et un doublon qui
        // diverge : le jour où un admin corrige un prix dans les champs
        // personnalisés, le panneau `METADATA` de la console continue
        // d'afficher l'ancien. Deux valeurs pour le même montant, sans que rien
        // ne dise laquelle fait foi. C'est le second vocabulaire que la règle 1
        // interdit, réintroduit par prudence mal placée.
        //
        // ⚠️ `Order.specMeta` gardait tout, lui — il n'était ni affiché ni
        // modifiable, donc il ne pouvait pas contredire l'écran. Il est retiré
        // le 03/08/2026 : la reprise a constaté 535 commandes sur 535 déjà
        // complètes en amont, donc le filet ne rattrapait plus rien. Le BFF ne
        // stocke plus **aucune** donnée métier de commande.
        meta: metaWithoutCustomFields,
        custom_field_values: customFieldValues,
        scheduled_at: dto.scheduledAt,
        // Un brouillon envoie `adhoc: false` ET `dispatched: false`
        // EXPLICITEMENT, pas seulement leur absence.
        //
        // ⚠️ **Corrige une hypothèse fausse** (30/07/2026) : omettre `adhoc` et
        // `driver_assigned_uuid` ne suffisait pas — la commande passait quand
        // même en `Dispatched` dès la création, et `status: 'created'` forcé
        // n'a rien changé non plus. Capture réseau de la console : son
        // formulaire de création envoie `status: null` (jamais une chaîne) et
        // surtout `dispatched: false`/`adhoc: false` explicites, deux champs
        // que ce chemin omettait purement et simplement. Fleetbase semble
        // traiter leur absence comme un défaut permissif.
        ...(dto.draft
          ? { adhoc: false, dispatched: false }
          : favourite?.kind === 'driver'
            ? { driver_assigned_uuid: favourite.driverUuid }
            : favourite?.kind === 'fleet'
              // Confiée, PAS affectée : l'entreprise désigne ensuite le sien.
              // `adhoc` reste faux — une course confiée ne doit pas continuer
              // d'être proposée aux indépendants, et le dispatch relance tout
              // seul toutes les ~4 minutes tant qu'elle l'est.
              ? {
                  facilitator_uuid: favourite.vendorUuid,
                  facilitator_type: FACILITATOR_TYPE_VENDOR,
                  adhoc: false,
                }
              : { adhoc: true, adhoc_distance: this.adhocRadiusMetres() }),
        pod_required: dto.podMethod ? dto.podMethod !== 'aucune' : undefined,
        pod_method: dto.podMethod && dto.podMethod !== 'aucune' ? dto.podMethod : undefined,
      }, [pickupPlace.place.uuid, dropoffPlace.place.uuid]);

      const fleetbaseOrder = response.order;
      const fleetbaseOrderId = fleetbaseOrder?.uuid || fleetbaseOrder?.id;

      // ── Ce qui suit est la seconde moitié d'une écriture en deux systèmes ──
      //
      // La commande existe désormais chez Fleetbase. La ligne locale qui dit
      // **à qui elle appartient** n'existe pas encore, et sans elle la commande
      // serait orpheline : invisible au commerçant, absente de ses
      // notifications, et son encaissement refusé faute de savoir à qui
      // l'imputer — alors qu'un transporteur la verrait et la livrerait.
      //
      // Il n'y a pas de transaction commune aux deux systèmes. À défaut, on
      // compense : si l'écriture locale échoue, la commande Fleetbase est
      // annulée, comme le `Vendor` l'est déjà quand une inscription commerçant
      // échoue à mi-chemin.
      const order = await this.createOrderCache(
        {
          merchantId,
          fleetbaseOrderId,
          // Le statut RÉEL renvoyé par Fleetbase, et non `'pending'` — un
          // statut inventé qui n'appartient pas à son vocabulaire. Le
          // réconciliateur y verrait un changement au premier passage et
          // notifierait une transition qui n'a jamais eu lieu.
          status: fleetbaseOrder?.status ?? 'created',
          // Seul un favori CONDUCTEUR renseigne cette colonne : une course
          // confiée à une entreprise n'a pas encore de conducteur, et y écrire
          // l'uuid du `Vendor` ferait mentir le cache que le réconciliateur
          // relit.
          driverAssignedUuid: favourite?.kind === 'driver' ? favourite.driverUuid : null,
        },
        fleetbaseOrderId,
      );

      if (favourite) {
        this.logger.log(
          favourite.kind === 'driver'
            ? `Commande ${order.id} confiée au favori ${favourite.driverUuid}`
            : `Commande ${order.id} confiée à l'entreprise favorite ${favourite.vendorUuid}`,
        );
      }

      this.logger.log(`Order created: ${order.id}`);

      return order;
    } catch (error) {
      // Une erreur métier délibérée traverse intacte. Sans cette ligne, le
      // filet générique la réemballait en « Failed to create order » : le
      // commerçant recevait, en production, un message qui ne disait ni ce qui
      // n'allait pas ni quoi faire — alors que le refus avait précisément été
      // écrit pour le lui expliquer.
      if (error instanceof HttpException) throw error;

      this.logger.error(`Failed to create order: ${error.message}`, error);
      const detail = error.response?.data ? JSON.stringify(error.response.data) : error.message;
      badRequest(
        'order.create_failed',
        this.configService.get('NODE_ENV') === 'development'
          ? `Failed to create order: ${detail}`
          : 'Failed to create order',
      );
    }
  }

  /**
   * Publie un brouillon : déclenche le dispatch qu'une création en mode
   * `draft` a délibérément omis.
   *
   * ── Ce qui fait qu'une commande EST un brouillon ─────────────────────────
   *
   * Aucun champ dédié, aucun statut Fleetbase « draft » — l'absence de
   * `adhoc` et de `driver_assigned_uuid` est le seul signal, exactement celui
   * que `createOrder` a laissé vide. Le vérifier ici, à nouveau, est ce qui
   * empêche de publier deux fois une commande déjà partie (au pool ou chez un
   * favori) : la republier écraserait une assignation en cours avec une
   * nouvelle décision de dispatch, potentiellement différente.
   *
   * ── Comment la décision de dispatch est reprise ─────────────────────────
   *
   * `meta.prefer_favourites` porte le choix fait à la création (Task #38) :
   * c'est lui qui décide, pas un nouveau réglage demandé au commerçant au
   * moment de publier — publier doit rester un geste, pas un second
   * formulaire. `vehicle_type` et `cod_amount` viennent du même `meta`, pour
   * que `pickAvailableFavourite` applique exactement les mêmes filtres qu'à
   * la création (catégorie de véhicule, plafond de dette).
   *
   * ── Deux appels, dans cet ordre, imposé par le source Fleetbase ──────────
   *
   * 1. **Qui peut prendre la commande** — un favori assigné
   *    (`POST /drivers/{uuid}/assign-order`), ou la diffusion au pool
   *    (`adhoc: true`).
   * 2. **Dispatcher** — `POST /v1/orders/{id}/dispatch`, l'endpoint dédié.
   *
   * L'ordre n'est pas un choix de style : `dispatchOrder` refuse avec « No
   * driver assigned to dispatch! » tant qu'il n'y a ni transporteur assigné
   * ni `adhoc`. Et le second appel est irremplaçable — trois tentatives ont
   * échoué avant de trouver cet endpoint dans `server/src/routes.php` (détail
   * dans `dispatchOrder()` côté client Fleetbase).
   */
  async publishOrder(merchantId: string, orderId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    const cached = await this.resolveOwnedOrder(merchantId, orderId);

    // Lecture unitaire, et ici l'enjeu n'est pas l'affichage :
    // `prefer_favourites`, `vehicle_type` et `cod_amount` vivent dans `meta`,
    // et c'est sur eux que se décide **à qui la course est confiée**. Une
    // commande manquée par le parcours de la liste ferait échouer la
    // publication ; un `meta` incomplet la publierait de travers, sans erreur.
    const live = await this.liveOrderDetailed(cached, merchant.fleetbaseVendorUuid);

    if (!live) {
      notFound('order.not_found_upstream', 'Commande introuvable chez Fleetbase');
    }

    // Le statut Fleetbase, et lui seul.
    //
    // ⚠️ La version précédente regardait `adhoc`/`dispatched`/
    // `driver_assigned_uuid` : une publication interrompue entre ses deux
    // étapes (assignation faite, dispatch échoué) laissait la commande
    // `created` chez Fleetbase mais « déjà publiée » pour ce garde — donc
    // définitivement bloquée, sans aucun moyen de la relancer. Sur le statut,
    // une publication ratée reste `created`, donc reste republiable : le
    // réessai est possible précisément parce qu'on ne mémorise rien à côté.
    if (live.status !== 'created') {
      badRequest(
        'order.already_published',
        `Cette commande n'est plus un brouillon (statut : ${live.status}).`,
      );
    }

    const meta = live.meta ?? {};
    const preferFavourites = meta.prefer_favourites !== false;
    const favourite = preferFavourites
      ? await this.pickAvailableFavourite(
          merchant.fleetbaseVendorUuid,
          meta.vehicle_type,
          // La commande existe : son depart se lit sur elle.
          orderPickup(live),
        )
      : null;

    try {
      // Étape 1 — qui peut prendre la commande.
      if (favourite?.kind === 'driver') {
        // Même route que le persona flotte (`flotte.service.ts`), déjà en
        // usage réel : `POST /drivers/{uuid}/assign-order` — int/v1
        // uniquement, cette route n'existe pas sur `v1` (vérifié dans
        // `server/src/routes.php`), d'où `callFleetOps` et l'uuid.
        await this.fleetbaseClient.assignOrderToDriver(
          favourite.driverUuid,
          cached.fleetbaseOrderId,
        );
      } else if (favourite?.kind === 'fleet') {
        // Confiée à l'entreprise, qui désignera son conducteur.
        // `attachFacilitator` pose déjà `adhoc: false` dans le même appel —
        // indispensable, sans quoi Fleetbase continuerait de proposer aux
        // indépendants une course déjà réclamée, et relancerait ses pings
        // toutes les ~4 minutes.
        await this.fleetbaseClient.attachFacilitator(
          cached.fleetbaseOrderId,
          favourite.vendorUuid,
        );
      } else {
        await this.fleetbaseClient.releaseOrderToPool(
          cached.fleetbaseOrderId,
          this.adhocRadiusMetres(),
        );
      }

      // Étape 2 — dispatcher, par la route de la console.
      //
      // `dispatchWithActivity()` pose le drapeau ET l'activité qui écrit le
      // statut, d'un seul bloc. C'est ce que fait la console, et c'est ce qui
      // distingue cette route de sa jumelle `v1`, qui sépare les deux et
      // refuse dès que le drapeau est posé — laissant alors le statut bloqué
      // à `created` pour toujours. Détail complet dans `dispatchOrder()`.
      //
      // ⚠️ **Compensée si elle échoue.** Les deux étapes ne sont pas
      // atomiques — aucune transaction ne couvre notre Postgres et le MySQL de
      // Fleetbase joint en HTTP — et l'étape 1 a déjà rendu la course
      // réclamable par un transporteur (`transporteur.service.ts` filtre sur
      // `adhoc === true` sans exiger `dispatched`). Sans compensation, un
      // échec ici laisse une course en circulation que le commerçant croit
      // encore en brouillon.
      try {
        await this.fleetbaseClient.dispatchOrder(cached.fleetbaseOrderId);
      } catch (dispatchError) {
        await this.withdrawAfterFailedDispatch(cached.fleetbaseOrderId);
        throw dispatchError;
      }
    } catch (error: any) {
      if (error instanceof HttpException) throw error;

      // Le message de Fleetbase est remonté tel quel quand il existe : ses
      // deux refus de dispatch sont explicites et actionnables (« No driver
      // assigned to dispatch! », « Order has already been dispatched! »).
      // Les remplacer par une phrase générique reviendrait à jeter la seule
      // information qui dit quoi corriger.
      const detail =
        error.response?.data?.errors?.[0] ||
        error.response?.data?.error ||
        error.response?.data?.message;

      this.logger.error(
        `Publication échouée (${orderId}) : ${detail ?? error.message}`,
      );
      badRequest(
        'order.publish_failed',
        detail || 'Impossible de publier cette commande pour le moment',
      );
    }

    // Troisième écriture, locale — et **délibérément non bloquante**.
    //
    // La publication a réussi côté Fleetbase à ce point : lever ici ferait
    // remonter un échec au commerçant pour une course pourtant partie, qui
    // réessaierait alors une publication désormais refusée. Le cache n'est
    // qu'un cache, et `OrderReconcilerService` le remet d'aplomb au passage
    // suivant — c'est exactement le rôle qu'on lui a donné.
    try {
      await this.prisma.order.update({
        where: { id: cached.id },
        data: {
          driverAssignedUuid: favourite?.kind === 'driver' ? favourite.driverUuid : null,
        },
      });
    } catch (error: any) {
      this.logger.warn(
        `Cache non mis à jour après publication de ${cached.id} : ${error.message} — ` +
          'le réconciliateur corrigera',
      );
    }

    if (favourite) {
      this.logger.log(
        favourite.kind === 'driver'
          ? `Brouillon ${cached.id} publié vers le favori ${favourite.driverUuid}`
          : `Brouillon ${cached.id} confié à l'entreprise favorite ${favourite.vendorUuid}`,
      );
    } else {
      this.logger.log(`Brouillon ${cached.id} publié vers le pool commun`);
    }

    const [merged] = await this.mergeWithFleetbase([cached], merchant.fleetbaseVendorUuid);
    return merged;
  }

  /**
   * Défait l'étape 1 quand le dispatch a échoué.
   *
   * ── Pourquoi ça compte, et ce que ça ne garantit pas ────────────────────────
   *
   * L'étape 1 rend la course réclamable (`adhoc: true` suffit à la faire
   * apparaître aux transporteurs). Un échec de l'étape 2 sans compensation
   * laisse donc une course en circulation que le commerçant croit encore en
   * brouillon — la pire des deux issues, parce qu'elle est invisible de son
   * côté.
   *
   * Best-effort, et l'aveu est important : si la compensation échoue à son
   * tour, la course **reste** réclamable, et seul ce journal en garde trace.
   * Il n'y a pas de transaction possible entre deux systèmes joints en HTTP ;
   * ce filet réduit la fenêtre, il ne la ferme pas. Une course prise dans
   * l'intervalle par un transporteur ne serait de toute façon plus retirable
   * sans le prévenir.
   */
  private async withdrawAfterFailedDispatch(fleetbaseOrderId: string): Promise<void> {
    try {
      await this.fleetbaseClient.withdrawFromDispatch(fleetbaseOrderId);
      this.logger.log(
        `Dispatch échoué sur ${fleetbaseOrderId} — course retirée de la diffusion`,
      );
    } catch (error: any) {
      this.logger.error(
        `COMPENSATION ÉCHOUÉE — la commande Fleetbase ${fleetbaseOrderId} reste ` +
          `réclamable par un transporteur alors qu'elle n'a pas été publiée. ` +
          `À retirer à la main depuis la console : ${error.message}`,
      );
    }
  }

  /**
   * Écrit la ligne de cache, ou annule la commande amont.
   *
   * ── Pourquoi une compensation, et non une simple journalisation ─────────────
   *
   * Cette ligne porte le rattachement commerçant ↔ commande, c'est-à-dire la
   * seule chose que Fleetbase ne sait pas exprimer (§2.8 : ses filtres de
   * requête sont ignorés en silence). Sans elle, la commande est **orpheline** :
   * elle part au dispatch, un transporteur la voit et la livre, mais elle
   * n'appartient à personne — le commerçant ne la voit pas, ses notifications
   * ne l'atteignent pas, et son encaissement est refusé.
   *
   * Une commande orpheline est donc pire qu'une commande non créée. La
   * compensation est best-effort — si l'annulation échoue à son tour, on
   * journalise en `error` avec l'identifiant, seule trace permettant à un
   * opérateur de la retrouver dans la console.
   */
  /**
   * Refuse la création si une donnée métier n'a pas de champ durable où aller.
   *
   * ── Décision produit, 30/07/2026 : pas de livraison sans ses montants ──────
   *
   * La tentation était de créer la commande quand même et de se rabattre sur
   * `meta`. C'est le mauvais arbitrage : une livraison dont le prix et le
   * montant à encaisser ne sont pas stockés durablement **paraît normale**. Le
   * commerçant la croit protégée, le transporteur voit un montant à réclamer —
   * et tout disparaît à la première affectation depuis la console. Le défaut ne
   * se révèle qu'au moment où il coûte de l'argent, à la porte du destinataire.
   *
   * Un refus, lui, se voit tout de suite, se corrige tout de suite, et ne
   * laisse personne agir sur une donnée fantôme.
   *
   * Le refus est levé **avant** toute écriture chez Fleetbase — d'où sa place
   * en tête de `createOrder`, avant même les deux `Place`.
   */
  /**
   * Ce qui reste à `meta` : les clés sans champ personnalisé correspondant.
   *
   * Renvoie `undefined` s'il ne reste rien, pour ne pas écrire un objet vide là
   * où l'absence est plus lisible.
   */
  private metaOutsideCatalogue(
    meta: Record<string, any> | undefined,
  ): Record<string, any> | undefined {
    if (!meta) return undefined;

    const rest: Record<string, any> = {};
    for (const [key, value] of Object.entries(meta)) {
      if (!ORDER_CUSTOM_FIELD_KEYS.includes(key)) rest[key] = value;
    }

    return Object.keys(rest).length ? rest : undefined;
  }

  private assertCustomFieldsComplete(
    meta: Record<string, any> | undefined,
    values: { custom_field_uuid: string }[],
  ): void {
    const expected = ORDER_CUSTOM_FIELD_KEYS.filter(
      (key) => meta?.[key] !== undefined && meta?.[key] !== null,
    );

    if (values.length >= expected.length) return;

    this.logger.error(
      `Champs personnalisés incomplets : ${values.length}/${expected.length} déclarés. `
        + 'Création refusée — une commande dont les montants ne sont pas stockés '
        + 'durablement serait indiscernable d\'une commande saine.',
    );

    badRequest(
      'order.custom_fields_unavailable',
      'Enregistrement impossible pour le moment : réessayez dans un instant.',
    );
  }

  /**
   * Crée la commande, et **supprime les deux lieux** si Fleetbase la refuse.
   *
   * Les `Place` d'enlèvement et de livraison sont créés avant la commande — ils
   * sont référencés par elle. Un échec après leur création les laisse orphelins
   * dans l'organisation, invisibles et jamais nettoyés : c'est ce qui s'est
   * accumulé pendant les essais du 30/07/2026, où la liste des lieux comptait
   * autant de doublons que de tentatives.
   *
   * La compensation est best-effort, comme toutes celles de ce projet : si elle
   * échoue à son tour, un log `error` nomme les lieux à reprendre à la main.
   */
  private async createOrderOrCleanUp(order: any, placeUuids: string[]) {
    try {
      return await this.fleetbaseClient.createOrder(order);
    } catch (error: any) {
      for (const uuid of placeUuids) {
        await this.fleetbaseClient.deletePlace(uuid).catch((cleanupError: any) =>
          this.logger.error(
            `Lieu ${uuid} laissé orphelin après un échec de création : ${cleanupError.message}`,
          ),
        );
      }
      throw error;
    }
  }

  private async createOrderCache(data: any, fleetbaseOrderId: string) {
    try {
      return await this.prisma.order.create({ data });
    } catch (error: any) {
      this.logger.error(
        `Cache de commande non écrit (${fleetbaseOrderId}) : ${error.message} — ` +
          'annulation de la commande Fleetbase pour ne pas la laisser orpheline',
      );

      try {
        await this.fleetbaseClient.cancelOrder(fleetbaseOrderId);
      } catch (cancelError: any) {
        this.logger.error(
          `ANNULATION DE COMPENSATION ÉCHOUÉE — la commande Fleetbase ` +
            `${fleetbaseOrderId} existe sans propriétaire et doit être annulée ` +
            `à la main : ${cancelError.message}`,
        );
      }

      badRequest('order.create_failed', 'La livraison n\'a pas pu être enregistrée. Réessayez.');
    }
  }

  /**
   * Cancel an order
   */
  /**
   * L'argent des commandes de ce commerçant : attendu, perçu, ou muet.
   *
   * ── Ce que cette route est devenue le 03/08/2026 ───────────────────────────
   *
   * Elle lisait Fleetbase **et** un registre de caisse local. Le registre est
   * retiré (`docs/registre_caisse_precis.md`) : tenir des soldes est de la
   * trésorerie, et détenir des fonds pour compte de tiers est une activité
   * réglementée qu'un agrégateur n'exerce pas. La source est désormais unique —
   * la commande elle-même, chez Fleetbase — ce qui est aussi la règle 1
   * appliquée pour de bon.
   *
   * ── Ce qu'elle sert, et pourquoi trois listes et non une ───────────────────
   *
   * `attendus` — un montant est annoncé, la livraison est en route. Personne ne
   * tient encore cet argent : ce n'est dû par personne, c'est un prévisionnel.
   *
   * `perçus` — le transporteur a déclaré à la porte ce qu'il a réellement pris.
   * C'est un **fait daté**, avec son écart et son motif quand il y en a un.
   * ⚠️ La plateforme s'arrête ici : elle dit ce qui s'est passé, elle ne dit
   * pas qui doit quoi à qui. Le rapprochement se fait entre le commerçant et
   * son transporteur, avec cette liste pour matière.
   *
   * `non déclarés` — livrée, un montant était annoncé, et **rien n'a été
   * déclaré**. Le cas normal est une clôture faite depuis la console Fleetbase,
   * qui est une interface de production légitime et ne connaît pas nos gardes.
   *
   * ⚠️ **Le trou doit rester visible, et le montant affiché est celui qui était
   * ANNONCÉ.** Nous ignorons ce qui a changé de mains ; présenter le montant
   * attendu comme une somme perçue serait inventer un fait. Deux colis livrés à
   * plus de 5 000 DZD et un écran affichant 0 sans rien signaler : c'est le
   * défaut que cette troisième liste existe pour empêcher (règle 10).
   */
  async collectionsOnMyOrders(merchantId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    const currency = platformCurrency(this.configService.get('CURRENCY'));

    const empty = {
      currency,
      expected_total: 0,
      orders: [] as any[],
      collected_total: 0,
      collected: [] as any[],
      unrecorded_total: 0,
      unrecorded: [] as any[],
    };

    const cached = await this.prisma.order.findMany({
      where: { merchantId },
      orderBy: { createdAt: 'desc' },
    });
    if (!cached.length) return empty;

    const live = await this.mergeWithFleetbase(cached, merchant.fleetbaseVendorUuid);

    const describe = (o: any) => ({
      uuid: o.uuid,
      bff_order_id: o.bff_order_id ?? null,
      status: o.status ?? null,
      driver_name: o.driver_assigned?.name ?? null,
      driver_phone: o.driver_assigned?.phone ?? null,
      dropoff_name: o.payload?.dropoff?.name ?? null,
      expected_amount: Number(o.meta.cod_amount),
      scheduled_at: o.scheduled_at ?? null,
      completed_at: o.updated_at ?? null,
    });

    // ⚠️ `stale`/`missing` écartés : Fleetbase injoignable, ou commande
    // disparue. On ne parle pas d'argent sur une commande dont on ignore
    // l'état — s'appuyer sur le cache local serait annoncer un montant sans
    // savoir s'il est encore d'actualité.
    const candidates = live.filter(
      (o: any) =>
        o?.uuid && !o.stale && !o.missing && Number(o.meta?.cod_amount) > 0,
    );

    // ── Perçu : la déclaration faite à la porte ───────────────────────────
    //
    // ⚠️ Le test porte sur `!== undefined`, jamais sur la vérité du nombre :
    // **zéro est une déclaration**, et c'en est même la plus importante — un
    // destinataire qui refuse de payer. `if (collected_amount)` l'aurait rangée
    // avec les livraisons muettes, c'est-à-dire aurait effacé le seul cas où le
    // commerçant a besoin d'être prévenu.
    const declared = (o: any) => o.meta?.collected_amount !== undefined;

    const collected = candidates.filter(declared).map((o: any) => ({
      ...describe(o),
      collected_amount: Number(o.meta.collected_amount),
      collected_at: o.meta.collected_at ?? null,
      // Servi tel quel : c'est un code d'une liste fermée, l'application le
      // traduit. Un motif en français ici serait illisible en arabe (règle 4).
      collection_reason: o.meta.collection_reason ?? null,
    }));

    const orders = candidates
      .filter((o: any) => !declared(o) && EXPECTS_CASH_AT_DOOR.includes(o.status))
      .map(describe);

    const unrecorded = candidates
      .filter((o: any) => !declared(o) && o.status === 'completed')
      .map(describe);

    if (unrecorded.length) {
      // Trace serveur : c'est le symptôme d'une clôture hors application, et
      // l'écran seul ne le dirait qu'au commerçant qui regarde.
      this.logger.warn(
        `${unrecorded.length} livraison(s) du commerçant ${merchantId} sont terminées `
          + 'avec un montant à encaisser et sans déclaration — '
          + 'clôture probablement faite hors application (console Fleetbase).',
      );
    }

    const sum = (rows: any[], key: string) =>
      rows.reduce((total, row) => total + (Number(row[key]) || 0), 0);

    return {
      currency,
      expected_total: sum(orders, 'expected_amount'),
      orders,
      collected_total: sum(collected, 'collected_amount'),
      collected,
      unrecorded_total: sum(unrecorded, 'expected_amount'),
      unrecorded,
    };
  }

  async cancelOrder(merchantId: string, orderId: string) {
    this.logger.log(`Cancelling order ${orderId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    // Le garde de transition lit l'état RÉEL chez Fleetbase, pas le champ
    // `status` du cache — celui-ci est figé à 'pending' depuis la création et
    // n'est jamais resynchronisé (revue archi #15). S'y fier laissait annuler
    // une commande déjà livrée.
    const [live] = await this.mergeWithFleetbase([order], merchant.fleetbaseVendorUuid);
    const liveStatus = (live as any)?.status ?? null;

    if (isTerminalOrderStatus(liveStatus)) {
      badRequest('order.already_terminal', `Commande déjà ${liveStatus}, annulation impossible`);
    }

    // Annuler pendant qu'un transporteur est en route est une décision qui
    // engage : le driver peut être devant la porte. Le refus par défaut protège
    // les deux parties tant que la règle métier n'est pas tranchée
    // (specs_echango_delivery.md §6) ; l'opérateur, lui, peut toujours annuler
    // depuis la console Fleetbase.
    if (liveStatus && ['started', 'enroute'].includes(liveStatus)) {
      badRequest(
        'order.cancel_not_allowed',
        'Le transporteur est déjà en route. Contactez Echango pour annuler cette livraison.',
      );
    }

    try {
      await this.fleetbaseClient.cancelOrder(order.fleetbaseOrderId);

      const updated = await this.prisma.order.update({
        where: { id: order.id },
        // `canceled`, l'orthographe de Fleetbase (un seul « l ») et non
        // `cancelled`. Le réconciliateur compare cette colonne à ce que dit
        // l'amont : deux orthographes pour le même état lui feraient voir un
        // changement à chaque passage, et notifier une annulation en boucle.
        data: { status: 'canceled' },
      });

      this.logger.log(`Order cancelled: ${order.id}`);
      return updated;
    } catch (error) {
      if (error instanceof BadRequestException) throw error;
      this.logger.error(`Failed to cancel order: ${error.message}`);
      badRequest('order.cancel_failed', 'Failed to cancel order');
    }
  }


  /**
   * Get secure tracking info for an order
   */
  async getOrderTracking(merchantId: string, orderId: string) {
    this.logger.log(`Fetching tracking for order ${orderId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    const order = await this.resolveOwnedOrder(merchantId, orderId);

    try {
      const [live] = await this.mergeWithFleetbase([order], merchant.fleetbaseVendorUuid);
      return {
        id: order.id,
        // Statut issu de Fleetbase, pas du cache : c'est tout l'objet du suivi.
        status: (live as any)?.status ?? null,
        // Servi depuis Fleetbase : la colonne de cache portait le numéro tel
        // qu'il était à la création, et le suivi est précisément l'écran où
        // servir une valeur figée n'a aucun sens.
        //
        // ⚠️ Déplié explicitement. Fleetbase expose `tracking_number` tantôt en
        // chaîne, tantôt en objet — relayer la valeur brute aurait changé le
        // **type** d'un champ de la réponse, c'est-à-dire cassé le contrat sans
        // qu'aucune erreur ne le dise.
        trackingNumber: this.trackingNumberOf(live),
        fleetbaseData: live,
      };
    } catch (error) {
      this.logger.error(`Failed to fetch tracking: ${error.message}`);
      badRequest('order.tracking_failed', 'Failed to fetch tracking information');
    }
  }


  /**
   * Get merchant's saved addresses, stored as Fleetbase Places owned by
   * their Vendor (owner_uuid), scoped server-side via GET /places?owner_uuid=...
   */
  async getAddresses(merchantId: string) {
    this.logger.log(`Fetching addresses for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      // `getOwnedPlaces` rend un tableau plat, paginé jusqu'au bout : c'est LUI
      // qui garantit qu'aucune adresse ne manque, pas l'appelant.
      const places = await this.fleetbaseClient.getOwnedPlaces(merchant.fleetbaseVendorUuid);
      // Projeté comme partout ailleurs (revue M10) : cette route servait les
      // objets `Place` Fleetbase **bruts**, seul reliquat de la fuite corrigée
      // le 28/07. Ce qui sortait était donc décidé par Fleetbase — dont
      // `owner_uuid`, `company_uuid` et toute relation qu'une mise à jour
      // amont y ajouterait.
      return { data: places.map((p: any) => projectPlace(p, 'full')) };
    } catch (error) {
      this.logger.error(`Failed to fetch addresses: ${error.message}`);
      // ⚠️ **Surtout pas `{ data: [] }`.** Mesuré le 03/08/2026 en coupant
      // Fleetbase : le commerçant qui a deux adresses en voyait zéro, en
      // HTTP 200, et son écran affichait « aucune adresse enregistrée ». Un
      // repli qui détruit l'information d'absence (règle 10) — et ici il fait
      // pire que masquer : il invite à ressaisir une adresse qui existe.
      badRequest('merchant.addresses_unavailable',
        'Impossible de lire votre carnet d’adresses pour le moment.');
    }
  }

  /**
   * Les composantes d'adresse, rangées dans les colonnes de `Place`.
   *
   * Elles viennent du géocodage inverse et **jamais d'une saisie** : le
   * commerçant tape une rue, pas une wilaya. C'est ce qui justifie de les
   * omettre quand elles sont absentes plutôt que de les envoyer vides —
   * `PUT /places` ne touche pas aux clés absentes, donc une modification sans
   * passage par la carte conserve ce qu'un passage précédent avait établi,
   * alors qu'une valeur vide l'effacerait.
   *
   * `street1` n'est pas ici : c'est le seul champ que le commerçant saisit
   * lui-même, et il doit rester effaçable.
   */
  private addressComponents(dto: SaveAddressDto): Record<string, any> {
    const components: Record<string, any> = {};
    if (dto.neighborhood) components.neighborhood = dto.neighborhood;
    if (dto.city) components.city = dto.city;
    if (dto.district) components.district = dto.district;
    if (dto.province) components.province = dto.province;
    if (dto.postalCode) components.postal_code = dto.postalCode;
    // Code ISO-2 : la colonne `country` stocke un code, que l'accesseur
    // `country_name` résout ensuite. Un nom de pays y laisserait `country_name`
    // vide, sans erreur.
    if (dto.country) components.country = dto.country.toUpperCase();
    return components;
  }

  /**
   * Save a new address as a Fleetbase Place owned by the merchant's Vendor.
   */
  async saveAddress(merchantId: string, dto: SaveAddressDto) {
    this.logger.log(`Saving address for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      const response = await this.fleetbaseClient.createOwnedPlace(merchant.fleetbaseVendorUuid, {
        name: dto.name,
        // `?? 0` : absence de position, pas une position au large du golfe de
        // Guinée — même convention que `readDriverPosition()`. Seuls `name` et
        // `contactPhone` sont exigés du commerçant (§ SaveAddressDto).
        latitude: dto.latitude ?? 0,
        longitude: dto.longitude ?? 0,
        // `street1`, et non `address` : `address` n'est PAS une colonne du
        // modèle `Place` — c'est un accesseur (`$appends`) qui recompose
        // name + street1 + street2 + city + province + code postal + pays.
        // L'envoyer était donc ignoré en silence par `fill()`, et l'adresse
        // saisie n'atteignait jamais la base : la console affichait « RUE 1 : -»
        // et la relecture retombait sur le nom du lieu.
        street1: dto.address,
        ...this.addressComponents(dto),
        phone: dto.contactPhone,
        meta: {
          label: dto.label ?? 'commerce',
          // `contact_name`, et non `contactName` : c'est la clé que
          // `projectPlace` relit, et que la création de commande dépose. Deux
          // orthographes pour la même donnée faisaient disparaître le contact
          // d'une adresse enregistrée dès sa relecture.
          contact_name: dto.contactName,
          notes: dto.notes,
          is_default: dto.isDefault === true,
        },
      });

      const uuid = response?.place?.uuid;
      // Une seule adresse principale à la fois : sans ce nettoyage, une
      // ancienne resterait marquée et le préremplissage du retrait
      // deviendrait ambigu. Fait après coup, sur le nouvel enregistrement
      // déjà réussi — un échec ici ne doit pas annuler la création.
      if (dto.isDefault === true) {
        await this.clearOtherDefaults(merchant.fleetbaseVendorUuid, uuid);
      }

      this.logger.log(`Address saved: ${uuid}`);
      return projectPlace(response.place, 'full');
    } catch (error) {
      this.logger.error(`Failed to save address: ${error.message}`);
      badRequest('merchant.address_save_failed', 'Failed to save address');
    }
  }

  /**
   * Retire le drapeau « adresse principale » de toute autre entrée du carnet.
   *
   * ⚠️ `meta` est remplacé en entier à chaque écriture Fleetbase, jamais
   * fusionné côté serveur : réécrire l'ancien défaut exige donc de reprendre
   * tout son `meta` existant (label, contact, notes), pas seulement
   * `is_default` — sans quoi le nettoyage effacerait au passage le reste de
   * sa fiche.
   *
   * Best-effort : une ancienne adresse principale qui reste marquée en double
   * n'est pas grave au point de bloquer l'enregistrement de la nouvelle.
   */
  private async clearOtherDefaults(vendorUuid: string, exceptPlaceUuid?: string): Promise<void> {
    try {
      const places = await this.fleetbaseClient.getOwnedPlaces(vendorUuid);
      const others = places.filter(
        (p: any) => p?.meta?.is_default === true && p?.uuid !== exceptPlaceUuid,
      );

      for (const place of others) {
        const position = readDriverPosition(place);
        await this.fleetbaseClient.updateOwnedPlace(place.uuid, {
          name: place.name,
          latitude: position?.latitude ?? 0,
          longitude: position?.longitude ?? 0,
          // ⚠️ `place.street1`, pas `place.address` : `PUT /places` remplace
          // l'objet entier, et `address` est un accesseur non enregistrable.
          // Le relire pour le renvoyer aurait effacé la rue de toutes les
          // autres adresses à chaque changement d'adresse principale.
          street1: place.street1,
          neighborhood: place.neighborhood,
          city: place.city,
          district: place.district,
          province: place.province,
          postal_code: place.postal_code,
          country: place.country,
          phone: place.phone,
          meta: { ...place.meta, is_default: false },
          ownerUuid: vendorUuid,
        });
      }
    } catch (error: any) {
      this.logger.warn(`Nettoyage de l'ancienne adresse principale échoué : ${error.message}`);
    }
  }

  /**
   * Vérifie qu'un lieu appartient bien au carnet de ce commerçant.
   *
   * Le contrôle passe par `owner_uuid`, seul filtre que Fleetbase honore
   * réellement sur `/places` (vérifié par test direct : interroger un
   * propriétaire sans lieu renvoie une liste vide, pas la collection entière).
   * Sans lui, un identifiant deviné suffirait à modifier ou supprimer l'adresse
   * d'un autre commerçant — les lieux vivent tous dans la même organisation.
   */
  private async assertOwnsPlace(merchantId: string, placeId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);

    const places = await this.fleetbaseClient.getOwnedPlaces(merchant.fleetbaseVendorUuid);
    const place = places.find(
      (p: any) => p?.uuid === placeId || p?.public_id === placeId || p?.id === placeId,
    );

    if (!place) {
      this.audit.denied({
        actorType: 'merchant',
        actorId: merchantId,
        action: 'address.access',
        resourceType: 'Place',
        resourceId: placeId,
        reason: "Adresse inexistante ou appartenant au carnet d'un autre commerçant",
      });
      notFound('merchant.address_not_found', 'Adresse introuvable');
    }

    return place;
  }

  /**
   * Modifie une adresse du carnet.
   *
   * ── Pourquoi la modification importe plus qu'il n'y paraît ──────────────────
   *
   * Une adresse enregistrée est **réutilisée** : elle pré-remplit chaque
   * livraison qui la choisit. Un point mal placé ou un téléphone erroné ne gêne
   * donc pas une fois, il se répète — et sans moyen de corriger, la seule issue
   * était d'accumuler des doublons.
   */
  async updateAddress(merchantId: string, placeId: string, dto: SaveAddressDto) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    const place = await this.assertOwnsPlace(merchantId, placeId);

    try {
      const response = await this.fleetbaseClient.updateOwnedPlace(place.uuid, {
        name: dto.name,
        latitude: dto.latitude ?? 0,
        longitude: dto.longitude ?? 0,
        // Voir `saveAddress` : `address` est un accesseur, seul `street1` est
        // enregistrable.
        street1: dto.address,
        ...this.addressComponents(dto),
        phone: dto.contactPhone,
        meta: {
          label: dto.label ?? 'commerce',
          contact_name: dto.contactName,
          notes: dto.notes,
          is_default: dto.isDefault === true,
        },
        // Réintroduit après un bug réel : `PUT /places` remplace l'objet
        // entier, un `owner_uuid` absent désolidarisait le lieu du carnet
        // (voir le commentaire de `updateOwnedPlace`). Vient de `merchant`,
        // jamais de `dto` — l'appartenance est déjà vérifiée par
        // `assertOwnsPlace`, ce n'est pas une valeur cliente à laquelle faire
        // confiance.
        ownerUuid: merchant.fleetbaseVendorUuid,
      });

      if (dto.isDefault === true) {
        await this.clearOtherDefaults(merchant.fleetbaseVendorUuid, place.uuid);
      }

      this.logger.log(`Adresse ${place.uuid} modifiée`);
      return projectPlace(response?.place ?? response, 'full');
    } catch (error) {
      if (error instanceof HttpException) throw error;
      this.logger.error(`Modification d'adresse impossible : ${error.message}`);
      badRequest('merchant.address_update_failed', "Modification de l'adresse impossible");
    }
  }

  /**
   * Retire une adresse du carnet.
   *
   * ⚠️ Ne touche **pas** les livraisons passées : chaque commande a créé son
   * propre `Place`, distinct de l'entrée du carnet. Supprimer une adresse
   * n'efface donc aucun historique — ce qui est précisément la raison pour
   * laquelle on peut se permettre de la supprimer sans confirmation lourde.
   */
  async deleteAddress(merchantId: string, placeId: string) {
    const place = await this.assertOwnsPlace(merchantId, placeId);

    try {
      await this.fleetbaseClient.deletePlace(place.uuid);
      this.logger.log(`Adresse ${place.uuid} supprimée`);
      return { removed: true };
    } catch (error) {
      if (error instanceof HttpException) throw error;
      this.logger.error(`Suppression d'adresse impossible : ${error.message}`);
      badRequest('merchant.address_delete_failed', "Suppression de l'adresse impossible");
    }
  }

  /**
   * Helper: Get merchant and validate
   */
  private async getMerchantWithValidation(merchantId: string) {
    const merchant = await this.prisma.merchantAccount.findUnique({
      where: { id: merchantId },
    });

    if (!merchant) {
      notFound('merchant.not_found', 'Merchant not found');
    }

    if (!merchant.active) {
      forbidden('merchant.inactive', 'Merchant account is inactive');
    }

    return merchant;
  }
}
