import { Injectable, Logger } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';
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
}
