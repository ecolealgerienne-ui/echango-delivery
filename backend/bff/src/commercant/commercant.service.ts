import { Injectable, Logger, HttpException, BadRequestException } from '@nestjs/common';
import { badRequest, notFound, forbidden } from '../common/errors/http-errors';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { CreateOrderDto, ListOrdersQueryDto } from './dto/create-order.dto';
import { SaveAddressDto } from './dto/address.dto';
import { QuoteRequestDto } from './dto/quote.dto';
import { projectOrderForMerchant, projectPlace } from '../common/projections/order.projection';
import { PricingService } from '../common/pricing/pricing.service';
import { CashService } from '../cash/cash.service';
import { readDriverPosition, readPositionSeenAt } from '../common/geo/driver-position';

@Injectable()
export class CommerçantService {
  private readonly logger = new Logger(CommerçantService.name);

  constructor(
    private prisma: PrismaService,
    private fleetbaseClient: FleetbaseApiClient,
    private configService: ConfigService,
    private audit: AuditService,
    private pricing: PricingService,
    private cash: CashService,
  ) {}

  /**
   * Get merchant's orders from Fleetbase via customer-portal-api
   */
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

    const byId = new Map(live.map((o: any) => [o?.uuid, o]));

    return cached.map((c) => {
      const order = byId.get(c.fleetbaseOrderId);
      if (!order) {
        // Order vanished from Fleetbase (deleted, or another organization).
        return { uuid: c.fleetbaseOrderId, bff_order_id: c.id, missing: true };
      }
      // Projection en liste d'autorisation : le BFF décide de ce qui sort, et
      // non Fleetbase (revue M10). L'identifiant local est conservé pour que
      // l'app puisse encore adresser la ligne dont il provient.
      return projectOrderForMerchant(order, { bff_order_id: c.id });
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
   * Fleetbase porte nativement `adhoc_distance` : inutile de reconstruire un
   * filtre de proximité côté BFF, c'est son dispatch géospatial qui l'applique.
   *
   * ⚠️ La valeur par défaut est un **repli, pas une décision produit** : 15 km
   * couvre une agglomération sans noyer les transporteurs de courses hors de
   * portée. À régler au pilote, avec de vraies distances.
   */
  private adhocRadiusMetres(): number {
    const configured = Number(this.configService.get('ADHOC_RADIUS_METRES'));
    return Number.isFinite(configured) && configured > 0 ? configured : 15000;
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
    // Reproduit à l'identique par « refaire cette livraison » — sans lui, la
    // duplication retombait systématiquement sur la valeur par défaut du
    // formulaire (`true`), jamais sur le choix réel de la commande d'origine.
    meta.prefer_favourites = dto.preferFavourites === true;

    // Montant à encaisser. Porté dans `meta` et non confondu avec `price` :
    // c'est ce que le destinataire doit au commerçant, tandis que `price` est
    // ce que le commerçant doit au transporteur. Sens inverses.
    if (dto.codAmount) {
      meta.cod_amount = dto.codAmount;
      meta.cod_currency = this.pricing.currency;
      meta.cod_includes_delivery = dto.codIncludesDelivery === true;
    }

    // Le devis est demandé sur TOUTE commande, même quand le commerçant a
    // saisi son montant : ce qui est enregistré au passage — distance, horaire,
    // catégorie de véhicule — sont les entrées de la future formule de calcul.
    // Elles ne sont pas rattrapables après coup : la distance dépend du
    // géocodage et du réseau routier du moment, et une commande rejouée plus
    // tard ne donnerait pas le même chiffre. Sans elles, les courses du pilote
    // ne serviront pas à calibrer le barème.
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

    return Object.keys(meta).length ? meta : undefined;
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
    merchantId: string,
    vehicleType?: string,
    codAmount?: number,
  ) {
    const favourites = await this.prisma.driverFavourite.findMany({
      where: { merchantId },
    });
    if (!favourites.length) return null;

    const uuids = favourites.map((f: any) => f.fleetbaseDriverUuid);

    // Le compte Echango porte la catégorie de véhicule et sert de garde : un
    // favori sans compte applicatif ne peut de toute façon pas recevoir la
    // course, faute de jeton push et d'application.
    const accounts = await this.prisma.driverAccount.findMany({
      where: {
        fleetbaseDriverUuid: { in: uuids },
        active: true,
        // Non déclaré = compatible : un transporteur ne doit pas être écarté
        // du réseau par un champ qu'il n'a pas rempli.
        ...(vehicleType
          ? {
              OR: [
                { vehicleType: null },
                { vehicleType: this.compatibleVehicleTypes(vehicleType) },
              ],
            }
          : {}),
      },
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

    const available = accounts.filter((a: any) => online.has(a.fleetbaseDriverUuid));

    if (!codAmount) return available[0] ?? null;

    // Course encaissée : on écarte en plus ceux dont la dette atteindrait le
    // plafond. Le premier garde-fou du modèle — sans dépôt physique, cesser de
    // confier des espèces à qui en doit déjà trop est le seul instrument de
    // limitation du risque dont nous disposions.
    for (const account of available) {
      const { allowed, debt, ceiling } = await this.cash.canTakeCashOrder(
        account.id,
        merchantId,
        codAmount,
      );
      if (allowed) return account;
      this.logger.log(
        `Favori ${account.id} écarté d'une course encaissée : dette ${debt} + ${codAmount} > ${ceiling}`,
      );
    }

    return null;
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
    await this.getMerchantWithValidation(merchantId);
    const favourites = await this.prisma.driverFavourite.findMany({
      where: { merchantId },
      orderBy: { createdAt: 'desc' },
    });
    return {
      data: favourites.map((f: any) => ({
        id: f.id,
        driver_uuid: f.fleetbaseDriverUuid,
        name: f.driverName,
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
      return { data: [] };
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
    // Le téléphone se cherche par ses chiffres : la saisie contient souvent des
    // espaces ou un indicatif que l'enregistrement n'a pas.
    const digits = q.replace(/\D/g, '');

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
    if (matches.length === 0 && digits.length >= 4) {
      try {
        const response = await this.fleetbaseClient.getAllDrivers({ limit: 100 });
        matches = this.fleetbaseClient
          .extractCollection(response, 'drivers')
          .filter((d: any) => {
            const phone = String(d?.phone ?? '').replace(/\D/g, '');
            return phone.length > 0 && phone.includes(digits);
          });
      } catch {
        // Le repli est un bonus : son échec ne doit pas casser la recherche.
      }
    }

    if (matches.length > 10) {
      return { data: [], too_many: true };
    }

    // Le compte applicatif, quand il existe, apporte la catégorie de véhicule
    // — et surtout son absence est une information : un transporteur sans
    // compte ne recevra aucune course, et le taire ferait d'une mise en favori
    // un geste sans effet.
    const accounts = await this.prisma.driverAccount.findMany({
      where: { fleetbaseDriverUuid: { in: matches.map((d: any) => d.uuid) } },
      select: { fleetbaseDriverUuid: true, vehicleType: true, active: true },
    });
    const byUuid = new Map<string, any>(
      accounts.map((a: any) => [a.fleetbaseDriverUuid, a]),
    );

    return {
      data: matches.map((d: any) => {
        const account = byUuid.get(d.uuid);
        return {
          driver_uuid: d.uuid,
          name: d.name ?? null,
          vehicle_type: account?.vehicleType ?? null,
          // Le téléphone n'est jamais renvoyé : celui qui cherche le connaît
          // déjà, c'est par là qu'il cherche.
          has_account: Boolean(account?.active),
        };
      }),
      too_many: false,
    };
  }

  async addFavourite(merchantId: string, fleetbaseDriverUuid: string, driverName?: string) {
    await this.getMerchantWithValidation(merchantId);

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

    return this.prisma.driverFavourite.upsert({
      where: { merchantId_fleetbaseDriverUuid: { merchantId, fleetbaseDriverUuid } },
      create: { merchantId, fleetbaseDriverUuid, driverName: resolvedName },
      update: { driverName: resolvedName },
    });
  }

  async removeFavourite(merchantId: string, favouriteId: string) {
    await this.getMerchantWithValidation(merchantId);

    // `deleteMany` avec le merchantId dans le filtre : un `delete` par id seul
    // permettrait de supprimer le favori d'un autre commerçant.
    const { count } = await this.prisma.driverFavourite.deleteMany({
      where: { id: favouriteId, merchantId },
    });

    if (count === 0) {
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
    const [merged] = await this.mergeWithFleetbase([order], merchant.fleetbaseVendorUuid);
    // Aucune donnée de facturation interne ne sort ici : la rémunération du
    // transporteur et la commission Echango vivent dans `DriverEarning`, et
    // n'ont pas d'usage dans l'app commerçant.
    return {
      ...(merged as any),
      ...(await this.failuresFor(order.fleetbaseOrderId)),
      ...(await this.collectionFor(order.fleetbaseOrderId)),
    };
  }

  /**
   * Encaissement enregistré sur cette livraison, s'il y en a un.
   *
   * Sans lui, le commerçant voit ce qu'il a *demandé* d'encaisser et jamais ce
   * qui l'a réellement été : le montant annoncé resterait affiché sur une
   * livraison où le client n'a payé que la moitié. C'est exactement l'écart que
   * le registre existe pour rendre visible, et le cacher sur la fiche de la
   * commande concernée le rendrait introuvable là où on le cherche.
   */
  private async collectionFor(fleetbaseOrderUuid: string) {
    const collection = await this.prisma.cashCollection.findUnique({
      where: { fleetbaseOrderUuid },
    });

    if (!collection) return {};

    return {
      cash_collection: {
        id: collection.id,
        expected_amount: collection.expectedAmount,
        collected_amount: collection.collectedAmount,
        discrepancy_reason: collection.discrepancyReason,
        notes: collection.notes,
        currency: collection.currency,
        collected_at: collection.collectedAt.toISOString(),
      },
    };
  }

  /**
   * Signalements d'échec attachés à une commande, du plus récent au plus
   * ancien.
   *
   * ── Pourquoi le commerçant doit les voir ────────────────────────────────────
   *
   * Il recevait « Échec de livraison : client absent » en notification, et rien
   * de plus : ni la précision écrite par le transporteur, ni la photo. Or c'est
   * lui qui devra répondre à son propre client, et éventuellement le
   * rembourser. Le seul destinataire du justificatif était jusqu'ici celui qui
   * l'avait produit.
   *
   * Le filtre porte sur la commande et non sur un transporteur : plusieurs
   * peuvent s'y être succédé, et le commerçant a droit à la série complète —
   * une livraison tentée trois fois n'est pas celle tentée une fois.
   *
   * La photo n'est jamais servie par son URL Fleetbase : celle-ci n'est
   * protégée par rien. Le chemin renvoyé pointe sur le BFF, qui vérifie
   * l'appartenance avant de relayer les octets.
   */
  private async failuresFor(fleetbaseOrderUuid: string) {
    const failures = await this.prisma.deliveryFailure.findMany({
      where: { fleetbaseOrderUuid },
      orderBy: { reportedAt: 'desc' },
    });

    if (!failures.length) return {};

    const project = (f: any) => ({
      id: f.id,
      reason: f.reason,
      notes: f.notes,
      photo_url: f.proofUrl ? `/commercant/preuves/${f.id}` : null,
      created_at: f.reportedAt.toISOString(),
    });

    return {
      delivery_failure: project(failures[0]),
      delivery_failures: failures.map(project),
    };
  }

  /**
   * Photo d'un signalement d'échec, servie au commerçant propriétaire.
   *
   * L'appartenance se vérifie en deux temps — le signalement porte l'uuid de la
   * commande, et c'est le cache local qui dit à quel commerçant elle est.
   * L'appartenance ne se demande jamais à Fleetbase — non parce qu'il ne
   * saurait pas répondre (l'affirmation §2.8 est corrigée depuis le
   * 29/07/2026), mais parce qu'un contrôle d'accès ne se délègue pas à un
   * paramètre de requête.
   */
  async getFailureProof(merchantId: string, failureId: string) {
    await this.getMerchantWithValidation(merchantId);

    const failure = await this.prisma.deliveryFailure.findUnique({
      where: { id: failureId },
    });

    const owned = failure
      ? await this.prisma.order.findFirst({
          where: { fleetbaseOrderId: failure.fleetbaseOrderUuid, merchantId },
          select: { id: true },
        })
      : null;

    if (!failure || !owned) {
      // Un signalement inexistant et celui d'un autre commerçant donnent la
      // même réponse ; seul le second est journalisé.
      if (failure) {
        this.audit.denied({
          actorType: 'merchant',
          actorId: merchantId,
          action: 'proof.access',
          resourceType: 'DeliveryFailure',
          resourceId: failureId,
          reason: 'Signalement portant sur la commande d\'un autre commerçant',
        });
      }
      notFound('order.proof_not_found', 'Aucune preuve pour ce signalement');
    }

    if (!failure.proofUrl) {
      notFound('order.proof_not_found', 'Aucune preuve pour ce signalement');
    }

    try {
      return await this.fleetbaseClient.fetchStoredFile(failure.proofUrl);
    } catch (error) {
      this.logger.warn(`Preuve ${failureId} illisible : ${error.message}`);
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

    let live: any;
    try {
      live = await this.liveOrderFor(merchant.fleetbaseVendorUuid, order);
    } catch (error) {
      this.logger.warn(`Preuve de commande indisponible : ${error.message}`);
      notFound('order.proof_not_found', 'Preuve indisponible');
    }

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

    let live: any;
    try {
      live = await this.liveOrderFor(merchant.fleetbaseVendorUuid, order);
    } catch (error) {
      this.logger.warn(`Position indisponible (${orderId}) : ${error.message}`);
      return { position: null };
    }

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

    let live: any;
    try {
      live = await this.liveOrderFor(merchant.fleetbaseVendorUuid, cached);
    } catch (error) {
      this.logger.warn(`Modèle de commande indisponible : ${error.message}`);
      badRequest('order.template_failed', 'Impossible de relire cette commande pour l\'instant');
    }

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
      codAmount: typeof meta.cod_amount === 'number' ? meta.cod_amount : null,
      codIncludesDelivery: meta.cod_includes_delivery === true,
    };
  }

  /**
   * Create a new delivery order
   */
  async createOrder(merchantId: string, dto: CreateOrderDto) {
    this.logger.log(`Creating order for merchant ${merchantId}`);

    const merchant = await this.getMerchantWithValidation(merchantId);

    try {
      // Fleetbase orders require pre-created Place records for pickup/dropoff,
      // referenced by UUID, plus a resolved order_config_uuid.
      const [pickupPlace, dropoffPlace, orderConfigUuid] = await Promise.all([
        // Les contacts sont bien transmis : ils étaient saisis, validés, puis
        // jetés (voir createPlace). Un transporteur devant une porte sans
        // numéro à appeler ne peut que constater l'échec.
        this.fleetbaseClient.createPlace(
          dto.pickupLocationName,
          dto.pickupLatitude,
          dto.pickupLongitude,
          { name: dto.pickupContactName, phone: dto.pickupContactPhone },
        ),
        this.fleetbaseClient.createPlace(
          dto.dropoffLocationName,
          dto.dropoffLatitude,
          dto.dropoffLongitude,
          { name: dto.dropoffContactName, phone: dto.dropoffContactPhone },
        ),
        this.fleetbaseClient.getDefaultOrderConfigUuid(),
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
      const favourite = dto.preferFavourites && !dto.draft
        ? await this.pickAvailableFavourite(merchantId, dto.vehicleType, dto.codAmount)
        : null;

      const response = await this.fleetbaseClient.createOrder({
        order_config_uuid: orderConfigUuid,
        customer_uuid: merchant.fleetbaseVendorUuid,
        customer_type: 'vendor',
        type: 'transport',
        payload: {
          pickup_uuid: pickupPlace.place.uuid,
          dropoff_uuid: dropoffPlace.place.uuid,
        },
        meta: this.buildOrderMeta(dto),
        scheduled_at: dto.scheduledAt,
        // Un brouillon n'envoie NI `adhoc` NI `driver_assigned_uuid` : c'est
        // cette absence, et rien de plus, qui le distingue d'une commande
        // publiée — Fleetbase ne connaît aucun statut « brouillon » natif
        // (vérifié dans ce projet, aucune occurrence dans le vocabulaire de
        // statuts observé). `publishOrder` referme cette absence après coup.
        ...(dto.draft
          ? {}
          : favourite
            ? { driver_assigned_uuid: favourite.fleetbaseDriverUuid }
            : { adhoc: true, adhoc_distance: this.adhocRadiusMetres() }),
        pod_required: dto.podMethod ? dto.podMethod !== 'aucune' : undefined,
        pod_method: dto.podMethod && dto.podMethod !== 'aucune' ? dto.podMethod : undefined,
      });

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
          driverAssignedUuid: favourite?.fleetbaseDriverUuid ?? null,
          // Le montant à encaisser n'est plus recopié ici (Lot 2) : il vit dans
          // `meta.cod_amount` chez Fleetbase, où tous ses lecteurs allaient déjà
          // le chercher, et il est figé dans `CashCollection` au moment où il
          // devient un fait comptable.
        },
        fleetbaseOrderId,
      );

      if (favourite) {
        this.logger.log(
          `Commande ${order.id} confiée au favori ${favourite.fleetbaseDriverUuid}`,
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
   * ⚠️ **Chemin non éprouvé par un appel réel** : `assignOrderDirectly` et
   * `releaseOrderToPool` reposent sur la même analogie de payload que le
   * reste de ce fichier, jamais rejouée contre une vraie instance Fleetbase
   * depuis ce bac à sable.
   */
  async publishOrder(merchantId: string, orderId: string) {
    const merchant = await this.getMerchantWithValidation(merchantId);
    const cached = await this.resolveOwnedOrder(merchantId, orderId);

    let live: any;
    try {
      live = await this.liveOrderFor(merchant.fleetbaseVendorUuid, cached);
    } catch (error: any) {
      this.logger.warn(`Publication impossible (${orderId}) : ${error.message}`);
      badRequest('order.publish_failed', 'Impossible de publier cette commande pour le moment');
    }

    if (!live) {
      notFound('order.not_found_upstream', 'Commande introuvable chez Fleetbase');
    }

    if (['completed', 'canceled', 'cancelled'].includes(live.status)) {
      badRequest('order.already_terminal', `Commande déjà ${live.status}, publication impossible`);
    }

    if (live.adhoc === true || live.driver_assigned_uuid) {
      badRequest('order.already_published', 'Cette commande a déjà été publiée');
    }

    const meta = live.meta ?? {};
    const preferFavourites = meta.prefer_favourites !== false;
    const favourite = preferFavourites
      ? await this.pickAvailableFavourite(merchantId, meta.vehicle_type, meta.cod_amount)
      : null;

    try {
      if (favourite) {
        await this.fleetbaseClient.assignOrderDirectly(
          cached.fleetbaseOrderId,
          favourite.fleetbaseDriverUuid,
        );
      } else {
        await this.fleetbaseClient.releaseOrderToPool(
          cached.fleetbaseOrderId,
          this.adhocRadiusMetres(),
        );
      }
    } catch (error: any) {
      this.logger.error(`Publication échouée (${orderId}) : ${error.message}`);
      badRequest('order.publish_failed', 'Impossible de publier cette commande pour le moment');
    }

    // Reflète tout de suite l'assignation côté cache : sans ça, l'écran
    // afficherait encore « brouillon » jusqu'au prochain passage du
    // réconciliateur, alors que la publication vient de réussir.
    await this.prisma.order.update({
      where: { id: cached.id },
      data: { driverAssignedUuid: favourite?.fleetbaseDriverUuid ?? null },
    });

    if (favourite) {
      this.logger.log(`Brouillon ${cached.id} publié vers le favori ${favourite.fleetbaseDriverUuid}`);
    } else {
      this.logger.log(`Brouillon ${cached.id} publié vers le pool commun`);
    }

    const [merged] = await this.mergeWithFleetbase([cached], merchant.fleetbaseVendorUuid);
    return merged;
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

    if (liveStatus && ['completed', 'canceled', 'cancelled'].includes(liveStatus)) {
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
      const response = await this.fleetbaseClient.getOwnedPlaces(merchant.fleetbaseVendorUuid);
      // Projeté comme partout ailleurs (revue M10) : cette route servait les
      // objets `Place` Fleetbase **bruts**, seul reliquat de la fuite corrigée
      // le 28/07. Ce qui sortait était donc décidé par Fleetbase — dont
      // `owner_uuid`, `company_uuid` et toute relation qu'une mise à jour
      // amont y ajouterait.
      const places = this.fleetbaseClient.extractCollection(response, 'places');
      return { data: places.map((p: any) => projectPlace(p, 'full')) };
    } catch (error) {
      this.logger.error(`Failed to fetch addresses: ${error.message}`);
      return { data: [] };
    }
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
        address: dto.address,
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
      const response = await this.fleetbaseClient.getOwnedPlaces(vendorUuid);
      const places = this.fleetbaseClient.extractCollection(response, 'places');
      const others = places.filter(
        (p: any) => p?.meta?.is_default === true && p?.uuid !== exceptPlaceUuid,
      );

      for (const place of others) {
        const position = readDriverPosition(place);
        await this.fleetbaseClient.updateOwnedPlace(place.uuid, {
          name: place.name,
          latitude: position?.latitude ?? 0,
          longitude: position?.longitude ?? 0,
          address: place.address,
          phone: place.phone,
          meta: { ...place.meta, is_default: false },
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

    const response = await this.fleetbaseClient.getOwnedPlaces(merchant.fleetbaseVendorUuid);
    const places = this.fleetbaseClient.extractCollection(response, 'places');
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
    const place = await this.assertOwnsPlace(merchantId, placeId);

    try {
      const response = await this.fleetbaseClient.updateOwnedPlace(place.uuid, {
        name: dto.name,
        latitude: dto.latitude ?? 0,
        longitude: dto.longitude ?? 0,
        address: dto.address,
        phone: dto.contactPhone,
        meta: {
          label: dto.label ?? 'commerce',
          contact_name: dto.contactName,
          notes: dto.notes,
          is_default: dto.isDefault === true,
        },
      });

      if (dto.isDefault === true) {
        const merchant = await this.getMerchantWithValidation(merchantId);
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
