import { HttpException, Injectable, Logger } from '@nestjs/common';
import { badRequest, serviceUnavailable } from '../errors/http-errors';
import { FleetbaseApiClient } from '../../fleetbase/fleetbase-api.client';
import { OrderCustomFieldsService } from '../../fleetbase/order-custom-fields.service';
import { ORDER_CUSTOM_FIELD_KEYS } from '../../fleetbase/order-custom-fields';
import { PricingService } from '../pricing/pricing.service';

/**
 * Le noyau **partagé** de la création d'une commande, extrait de
 * `CommerçantService` le 08/09/2026 pour que le transporteur puisse créer des
 * courses depuis ses dépôts (spec §3.3) **sans recopier** cette logique.
 *
 * ── Ce qui est ici, et ce qui reste chez l'appelant ────────────────────────
 *
 * Ici : construire `meta` (prix, encaissement, véhicule, colis), déclarer les
 * champs personnalisés durables, refuser si ils sont incomplets, et créer la
 * commande Fleetbase en nettoyant les `Place` orphelins si elle échoue.
 *
 * Chez l'appelant : résoudre QUI possède la commande (compte, favori, dépôt),
 * créer les `Place` d'enlèvement et de livraison, et — pour le commerçant —
 * écrire la ligne locale (`Order` Prisma exige un `merchantId`, donc une
 * commande de transporteur n'en a pas).
 *
 * ── Règle 5 ───────────────────────────────────────────────────────────────
 *
 * Deux personas créent désormais des commandes ; si la façon d'écrire un prix
 * ou de déclarer un champ personnalisé change, elle doit changer pour les deux.
 * Une seule copie l'assure.
 */
export interface OrderMetaInput {
  deliveryInstructions?: string;
  vehicleType?: string;
  items?: any[];
  pickupNotes?: string;
  dropoffNotes?: string;
  pickupProvince?: string;
  dropoffProvince?: string;
  pickupLatitude: number;
  pickupLongitude: number;
  dropoffLatitude: number;
  dropoffLongitude: number;
  scheduledAt?: string;
  price?: number;
  codAmount?: number;
  codIncludesDelivery?: boolean;
}

@Injectable()
export class OrderCreationHelpers {
  private readonly logger = new Logger(OrderCreationHelpers.name);

  constructor(
    private readonly pricing: PricingService,
    private readonly fleetbaseClient: FleetbaseApiClient,
    private readonly orderCustomFields: OrderCustomFieldsService,
  ) {}

  /**
   * Construit `meta` — instructions, véhicule, colis, wilayas figées, devis, et
   * le bloc d'encaissement (marchandise + rémunération réclamées à la porte).
   *
   * ⚠️ La CIBLE (`target_favourite_uuid`/`_kind`) n'est PAS posée ici : elle
   * exige une lecture asynchrone (valider un favori). L'appelant la pose après.
   */
  buildOrderMeta(dto: OrderMetaInput): Record<string, any> | undefined {
    const meta: Record<string, any> = {};
    if (dto.deliveryInstructions) meta.instructions = dto.deliveryInstructions;
    if (dto.vehicleType) meta.vehicle_type = dto.vehicleType;
    if (dto.items?.length) meta.items = dto.items;
    if (dto.pickupNotes) meta.pickup_notes = dto.pickupNotes;
    if (dto.dropoffNotes) meta.dropoff_notes = dto.dropoffNotes;

    // La wilaya vit sur le `Place`, mais la LISTE des commandes ne la sert pas
    // (ressource d'index à quinze clés). Le filtre du transporteur lit la liste
    // — d'où cette copie figée à la création, comme `vehicle_type`.
    if (dto.pickupProvince) meta.pickup_province = dto.pickupProvince;
    if (dto.dropoffProvince) meta.dropoff_province = dto.dropoffProvince;

    // Devis demandé sur TOUTE commande : distance, horaire, véhicule sont les
    // entrées de la future formule, non rattrapables après coup. Calculé AVANT
    // l'encaissement : quand la livraison n'est pas dans le prix marchandise,
    // c'est la rémunération qui s'ajoute au montant réclamé à la porte.
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
      meta.price_source = quote.source;
    }

    // ── Paiement à la livraison ───────────────────────────────────────────
    // `price` va du commanditaire au transporteur ; `cod_amount` va du
    // destinataire au commanditaire. Sens inverses, à ne jamais confondre.
    if (dto.codAmount) {
      const goods = dto.codAmount;
      const includesDelivery = dto.codIncludesDelivery === true;
      const fee = includesDelivery ? 0 : (meta.price ?? null);

      if (fee === null) {
        badRequest(
          'order.cod_requires_price',
          'Indiquez la rémunération du transporteur : elle sera réclamée au destinataire en plus de la marchandise.',
        );
      }

      meta.cod_amount = goods + fee;
      meta.cod_goods_amount = goods;
      meta.cod_currency = this.pricing.currency;
      meta.cod_includes_delivery = includesDelivery;
    }

    return Object.keys(meta).length ? meta : undefined;
  }

  /** Ce qui n'a PAS de champ personnalisé — la seule part de `meta` encore écrite. */
  metaOutsideCatalogue(
    meta: Record<string, any> | undefined,
  ): Record<string, any> | undefined {
    if (!meta) return undefined;
    const rest: Record<string, any> = {};
    for (const [key, value] of Object.entries(meta)) {
      if (!ORDER_CUSTOM_FIELD_KEYS.includes(key)) rest[key] = value;
    }
    return Object.keys(rest).length ? rest : undefined;
  }

  /**
   * Refuse si les champs personnalisés durables n'ont pas tous été déclarés :
   * une commande dont les montants ne sont pas stockés durablement serait
   * indiscernable d'une commande saine.
   */
  assertCustomFieldsComplete(
    meta: Record<string, any> | undefined,
    values: { custom_field_uuid: string }[],
  ): void {
    const expected = ORDER_CUSTOM_FIELD_KEYS.filter(
      (key) => meta?.[key] !== undefined && meta?.[key] !== null,
    );
    if (values.length >= expected.length) return;

    this.logger.error(
      `Champs personnalisés incomplets : ${values.length}/${expected.length} déclarés. `
        + 'Création refusée.',
    );
    badRequest(
      'order.custom_fields_unavailable',
      'Enregistrement impossible pour le moment : réessayez dans un instant.',
    );
  }

  /**
   * Crée la commande Fleetbase, et **nettoie les `Place` orphelins** si elle
   * échoue — il n'y a pas de transaction entre les deux systèmes (règle 2).
   *
   * ⚠️ `placeUuids` ne doit contenir QUE les `Place` créés pour cette commande.
   * Un `Place` préexistant (un dépôt, une adresse du carnet) ne s'y met jamais.
   */
  async createOrderOrCleanUp(order: any, placeUuids: string[]) {
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

  /** Résout et récupère les valeurs de champs personnalisés pour un `meta`. */
  customFieldValues(orderConfigUuid: string, meta: Record<string, any> | undefined) {
    return this.orderCustomFields.valuesFor(orderConfigUuid, meta);
  }

  defaultOrderConfigUuid() {
    return this.fleetbaseClient.getDefaultOrderConfigUuid();
  }

  // ── Tournée multi-arrêt (spec §4) ─────────────────────────────────────────
  //
  // Une tournée = **une** commande Fleetbase à `payload.waypoints[]` (liste
  // ordonnée de `Place`) + `payload.entities[]` (colis rattachés à leur arrêt
  // par `destination_uuid`). **Un seul `price`** pour toute la route, réglé par
  // le demandeur au conducteur — indépendamment des espèces perçues à chaque
  // porte. Le `codAmount` d'un arrêt est donc la **marchandise seule** : aucun
  // frais de livraison n'y est ajouté, contrairement à une course 1→1
  // (`buildOrderMeta`), où la rémunération se réclame à la porte.
  //
  // L'appelant résout d'abord chaque arrêt en `Place` (un dépôt à lui, ou un
  // lieu qu'il crée) et passe la liste ; la résolution diffère par persona
  // (favoris réseau côté commerçant, dépôts possédés côté transporteur), pas la
  // construction de la commande — c'est elle qui est ici (règle 5).

  /**
   * Construit le `meta` d'une tournée : instructions, véhicule, wilayas figées
   * (premier / dernier arrêt), devis à prix unique, et le bloc d'encaissement
   * **cumulé** — `cod_amount` = somme des `codAmount` d'arrêt, `stop_cod_amounts`
   * en portant le détail par `place_uuid`.
   *
   * `cod_amount` (le **total**, lu par le plafond de dette) et
   * `stop_cod_amounts` (le détail `[{ place_uuid, amount }]`) sont **tous deux
   * des champs personnalisés durables** — une affectation console écraserait
   * `meta`, pas eux (règle 1). `payload.waypoints` étant lui aussi structurel,
   * une tournée reste entièrement reconstituable après un tel écrasement.
   */
  buildTourneeMeta(input: TourneeInput): Record<string, any> | undefined {
    const meta: Record<string, any> = {};
    if (input.deliveryInstructions) meta.instructions = input.deliveryInstructions;
    if (input.vehicleType) meta.vehicle_type = input.vehicleType;

    // `createTournee` a déjà refusé une liste de moins de deux arrêts : les
    // deux extrémités existent.
    const first = input.stops[0];
    const last = input.stops[input.stops.length - 1];
    if (first.province) meta.pickup_province = first.province;
    if (last.province) meta.dropoff_province = last.province;

    // Devis à partir des deux extrémités de la route — un proxy de distance,
    // pas la longueur réelle du parcours. Le `price` est explicite sur une
    // tournée (le demandeur le fixe), donc `quote.amount` vaut ce prix ; le
    // devis sert surtout à figer `pricing_inputs` (règle : entrées non
    // rattrapables après coup).
    const quote = this.pricing.quote(
      {
        pickupLatitude: first.latitude,
        pickupLongitude: first.longitude,
        dropoffLatitude: last.latitude,
        dropoffLongitude: last.longitude,
        scheduledAt: input.scheduledAt,
        vehicleType: input.vehicleType,
      },
      input.price,
    );
    meta.pricing_inputs = quote.inputs;
    if (quote.amount !== null) {
      meta.price = quote.amount;
      meta.currency = quote.currency;
      meta.price_source = quote.source;
    }

    const stopCods = input.stops
      .filter((s) => s.codAmount && s.codAmount > 0)
      .map((s) => ({ place_uuid: s.placeUuid, amount: s.codAmount as number }));

    if (stopCods.length) {
      const total = stopCods.reduce((sum, c) => sum + c.amount, 0);
      meta.stop_cod_amounts = stopCods;
      meta.cod_amount = total;
      meta.cod_goods_amount = total;
      meta.cod_currency = this.pricing.currency;
      // Rien n'est ajouté à la porte : le prix de la tournée est réglé par le
      // demandeur, à part. `true` empêche tout calcul aval d'y greffer un frais.
      meta.cod_includes_delivery = true;
    }

    meta.is_tournee = true;
    meta.stop_count = input.stops.length;

    return Object.keys(meta).length ? meta : undefined;
  }

  /**
   * Crée la tournée chez Fleetbase, avec compensation des `Place` créés pour
   * ses arrêts (règle 2). Renvoie l'identifiant et le statut, comme
   * `createFleetOrder`.
   *
   * ⚠️ Les refus délibérés (`badRequest` de `assertCustomFieldsComplete`)
   * ressortent avec leur code — ils ne sont pas réemballés en « création
   * impossible » (règle 3).
   */
  async createTournee(
    input: TourneeInput,
  ): Promise<{ fleetbaseOrderId: string | null; status: string }> {
    if (input.stops.length < 2) {
      badRequest(
        'tournee.invalid_shape',
        'Une tournée demande au moins deux arrêts',
      );
    }
    if (!input.stops.some((s) => s.type === 'pickup')) {
      badRequest(
        'tournee.invalid_shape',
        'Une tournée doit comporter au moins un enlèvement',
      );
    }

    const meta = this.buildTourneeMeta(input);
    const createdPlaceUuids = input.stops
      .map((s) => s.createdPlaceUuid)
      .filter((u): u is string => typeof u === 'string');

    try {
      const orderConfigUuid = await this.defaultOrderConfigUuid();
      const customFieldValues = await this.customFieldValues(orderConfigUuid, meta);
      this.assertCustomFieldsComplete(meta, customFieldValues);
      const metaRest = this.metaOutsideCatalogue(meta);

      const waypoints = input.stops.map((s) => ({
        place_uuid: s.placeUuid,
        type: s.type,
      }));
      // Un colis listé sur un arrêt de **livraison** y est déposé
      // (`destination` = cet arrêt). Un colis listé sur un arrêt
      // d'**enlèvement** est collecté là et porté jusqu'au **dernier arrêt** —
      // le cas de la multi-collecte (N enlèvements → 1 dépôt). Les deux formes
      // canoniques de tournée sont ainsi couvertes sans champ supplémentaire.
      const lastStopUuid = input.stops[input.stops.length - 1].placeUuid;
      const entities = input.stops.flatMap((s, index) =>
        (s.items ?? []).map((item: any) => ({
          name: item?.label ?? item?.name ?? 'Colis',
          ...(item?.description ? { description: item.description } : {}),
          destination_uuid: s.type === 'pickup' ? lastStopUuid : s.placeUuid,
          meta: { stop_index: index, collected_at_stop: s.type === 'pickup' },
        })),
      );

      const response = await this.createOrderOrCleanUp(
        {
          order_config_uuid: orderConfigUuid,
          customer_uuid: input.customerUuid,
          customer_type: input.customerType,
          ...(input.facilitatorUuid
            ? {
                facilitator_uuid: input.facilitatorUuid,
                facilitator_type: input.facilitatorType,
              }
            : {}),
          type: 'transport',
          payload: {
            waypoints,
            ...(entities.length ? { entities } : {}),
          },
          meta: metaRest,
          custom_field_values: customFieldValues,
          scheduled_at: input.scheduledAt,
          ...(input.draft
            ? { adhoc: false, dispatched: false }
            : input.targetDriverUuid
              ? { driver_assigned_uuid: input.targetDriverUuid, adhoc: false }
              : input.adhocDistance
                // Diffusée au pool : n'importe quel conducteur peut la prendre.
                // Réservé au commerçant, qui garde son suivi par la ligne
                // `Order` locale ; une tournée transporteur diffusée serait
                // invisible de son créateur (pas de ligne locale, filtre
                // `facilitator`).
                ? { adhoc: true, adhoc_distance: input.adhocDistance }
                // Confiée sans conducteur nommé : le demandeur désignera le
                // sien ensuite. `adhoc` faux.
                : { adhoc: false }),
          pod_required: input.podMethod ? input.podMethod !== 'aucune' : undefined,
          pod_method:
            input.podMethod && input.podMethod !== 'aucune'
              ? input.podMethod
              : undefined,
        },
        createdPlaceUuids,
      );

      const order = response?.order ?? response?.data ?? response;
      return {
        fleetbaseOrderId: order?.uuid || order?.id || null,
        status: order?.status ?? 'created',
      };
    } catch (error: any) {
      if (error instanceof HttpException) throw error;
      this.logger.error(`createTournee failed: ${error.message}`);
      serviceUnavailable('order.create_failed', 'Failed to create tournee');
    }
  }
}

/** Un arrêt de tournée **déjà résolu en `Place`** par l'appelant. */
export interface ResolvedTourneeStop {
  /** L'uuid du `Place` de cet arrêt (un dépôt existant, ou un lieu créé). */
  placeUuid: string;
  /** Renseigné **uniquement** si ce `Place` a été créé pour cette tournée —
   *  il entre alors dans la compensation. Un dépôt préexistant : jamais. */
  createdPlaceUuid?: string;
  type: 'pickup' | 'dropoff';
  latitude: number;
  longitude: number;
  province?: string;
  notes?: string;
  items?: any[];
  /** Espèces à percevoir à cet arrêt — marchandise seule (spec §4.1). */
  codAmount?: number;
}

export interface TourneeInput {
  customerUuid: string;
  customerType: string;
  facilitatorUuid?: string;
  facilitatorType?: string;
  stops: ResolvedTourneeStop[];
  /** Un seul prix pour toute la route (spec §1). */
  price: number;
  scheduledAt?: string;
  vehicleType?: string;
  deliveryInstructions?: string;
  podMethod?: string;
  /** Conducteur ciblé (un conducteur du demandeur transporteur, ou un favori
   *  conducteur du commerçant). */
  targetDriverUuid?: string;
  /** Rayon de diffusion au pool, en mètres. Posé ⇒ `adhoc: true` (aucun
   *  `targetDriverUuid` ni `facilitatorUuid` alors). Réservé au commerçant. */
  adhocDistance?: number;
  draft?: boolean;
}
