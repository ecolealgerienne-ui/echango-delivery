import { Injectable, Logger } from '@nestjs/common';
import { randomUUID } from 'crypto';

import { badRequest, conflict, forbidden, notFound } from '../common/errors/http-errors';
import { isOrderClaimable, isTerminalOrderStatus } from '../common/orders/order-status';
import { findFailure, projectFailures } from '../common/orders/delivery-failures';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { AuditService } from '../common/audit/audit.service';
import { NotificationsService } from '../notifications/notifications.service';
import { assertCollectedAmount } from '../common/money/collection';
import { platformCurrency } from '../common/money/currency';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { OrderCustomFieldsService } from '../fleetbase/order-custom-fields.service';
import { DriverZoneService } from '../fleetbase/driver-zone.service';
import { DEFAULT_ZONE_RADIUS_KM, zoneAllows } from '../common/orders/driver-zone';
import {
  effectiveOrderMeta,
  projectOrderForDriver,
} from '../common/projections/order.projection';
import { adhocRadiusMetres as configuredAdhocRadius } from '../common/orders/adhoc-radius';
import {
  UpdatePositionDto,
  ToggleOnlineDto,
  UpdateActivityDto,
  ReportDeliveryFailureDto,
  DeclineOrderDto,
  CashCollectionDto,
  CapturePhotoDto,
  ListDriverOrdersQueryDto,
} from './dto/transporteur.dto';

@Injectable()
export class TransporteurService {
  private readonly logger = new Logger(TransporteurService.name);

  constructor(
    private readonly prisma: PrismaService,
    private readonly fleetbaseClient: FleetbaseApiClient,
    private readonly audit: AuditService,
    private readonly notifications: NotificationsService,
    private readonly orderCustomFields: OrderCustomFieldsService,
    private readonly configService: ConfigService,
    private readonly driverZone: DriverZoneService,
  ) {}

  /**
   * Load the Echango driver account and its Fleetbase identifiers.
   *
   * Every method below starts here rather than trusting the JWT payload: the
   * token carries an account id, and the mapping to a Fleetbase driver has to
   * come from the database each time, so a deactivated account stops working
   * immediately instead of at token expiry.
   */
  private async getDriverOrFail(driverId: string) {
    const driver = await this.prisma.driverAccount.findUnique({
      where: { id: driverId },
    });

    if (!driver || !driver.active) {
      forbidden('driver.inactive', 'Driver account not found or inactive');
    }

    return driver;
  }

  /**
   * The Fleetbase Driver record behind an Echango account.
   *
   * Lecture unitaire depuis la validation de V9 (journal §24) : elle vérifie
   * elle-même que l'uuid renvoyé est celui demandé, donc elle ne peut pas
   * rendre un autre conducteur.
   */
  private async findFleetbaseDriver(fleetbaseDriverUuid: string) {
    return this.fleetbaseClient.getDriverByUuid(fleetbaseDriverUuid);
  }

  /**
   * Resolve the driver's Fleetbase public_id, backfilling it if absent.
   *
   * Accounts registered before the column existed have it null, and
   * POST /v1/orders/{id}/start is the one call that refuses a uuid.
   */
  private async getDriverPublicId(driver: { id: string; fleetbaseDriverUuid: string; fleetbaseDriverPublicId: string | null }) {
    if (driver.fleetbaseDriverPublicId) {
      return driver.fleetbaseDriverPublicId;
    }

    const match = await this.findFleetbaseDriver(driver.fleetbaseDriverUuid);

    if (!match?.public_id) {
      badRequest('driver.public_id_unresolved', 'Could not resolve this driver public_id in Fleetbase');
    }

    await this.prisma.driverAccount.update({
      where: { id: driver.id },
      data: { fleetbaseDriverPublicId: match.public_id },
    });

    return match.public_id;
  }

  /**
   * Resolve an order by whichever identifier the app sent, from the company
   * order list.
   *
   * Why not a direct GET by id: the public `v1` API addresses records by
   * public_id only — `findRecordOrFail()` matches `public_id`/`internal_id`
   * and never `uuid` (verified 28/07/2026 in core-api HasApiModelBehavior,
   * after a 404 on a perfectly valid uuid). Meanwhile `int/v1` works in uuids,
   * and §2.13 showed its by-id GET ignores the path param entirely. Matching
   * both identifiers here means the app can send either and neither quirk
   * leaks into the rest of the module.
   *
   * Cost: one list fetch per operation. Acceptable at this scale, and the
   * ownership check below needs the record anyway.
   */
  private async resolveOrder(orderId: string) {
    let orders: any[];
    try {
      orders = await this.fleetbaseClient.fetchEveryOrder();
    } catch (error) {
      this.logger.error(`Order lookup failed (${orderId}): ${error.message}`);
      badRequest('order.fetch_failed', 'Failed to fetch orders');
    }

    const found = orders.find((o) => o?.uuid === orderId || o?.public_id === orderId);

    // ⚠️ Rechargée avant d'être rendue : la liste ne porte aucun champ
    // personnalisé, donc une fiche servie telle quelle n'aurait ni prix, ni
    // montant à encaisser, ni signalement d'échec. Une lecture unitaire de plus
    // sur une fiche est sans conséquence — c'est une commande, pas cinquante.
    if (!found?.uuid) return found;
    try {
      return (await this.fleetbaseClient.readOrderFull(found.uuid)) ?? found;
    } catch (error: any) {
      this.logger.warn(
        `Commande ${found.uuid} non rechargée (${error?.message}) — servie sans ses montants`,
      );
      return found;
    }
  }

  /**
   * The identifier to use when calling the public v1 API for this order.
   * Fails loudly rather than sending a uuid that would 404 confusingly.
   */
  private orderPublicId(order: any): string {
    if (!order?.public_id) {
      badRequest('order.missing_public_id', 'This order has no public_id — cannot address it on the v1 API');
    }
    return order.public_id;
  }

  /**
   * Recompose `meta` depuis les champs personnalisés de la commande.
   *
   * ⚠️ Nécessaire parce qu'une affectation de transporteur **depuis la console
   * Fleetbase efface `meta`** (constaté le 30/07/2026). Pour le transporteur,
   * ce n'est pas un affichage dégradé — `cod_amount` disparu signifie qu'aucun
   * montant ne lui est annoncé, et `price` disparu qu'il ne sait pas ce que la
   * course rapporte. Il accepterait à l'aveugle une course encaissée.
   *
   * ⚠️ **Interrogeait la base locale jusqu'au 03/08/2026**, pour y lire
   * `Order.specMeta`. C'est désormais une projection pure, sans entrée/sortie
   * et sans possibilité d'échouer.
   */
  private withEffectiveMeta(orders: any[]): any[] {
    return orders.map((o) => ({ ...o, meta: effectiveOrderMeta(o) }));
  }

  /**
   * Projette les courses assignées, signalements d'échec compris.
   *
   * ⚠️ **Ne fait plus aucune requête depuis le 03/08/2026** : les échecs vivent
   * sur la commande, donc ils arrivent avec elle. La version précédente
   * interrogeait la base une fois par liste servie.
   *
   * ⚠️ **Et elle rendait la commande Fleetbase BRUTE jusqu'au 03/08/2026** —
   * `{...o, meta: effectiveOrderMeta(o)}`, sans jamais traverser
   * `projectOrderForDriver`. La liste d'autorisation existait, s'accordait avec
   * le catalogue, était testée — et **ce chemin ne l'appelait pas**. Sortaient
   * donc `meta.declines[]` en entier (uuid Fleetbase, motif, notes libres et
   * **prix offert** à chaque transporteur qui avait refusé), `proof_url`, et
   * `custom_field_values[]` brut.
   *
   * Le motif de l'oubli est instructif : la branche adhoc d'à côté projetait
   * bien (`{unclaimed: true}`), et les deux autres modules aussi. C'est
   * l'**exception** qui avait l'air d'une règle — une fonction nommée « attache
   * les échecs » ne se lit pas comme une frontière de sortie.
   *
   * ⚠️ Et le test qui devait l'attraper accordait le catalogue avec la liste
   * d'autorisation **sans jamais exécuter le chemin** : deux listes d'accord
   * pendant qu'un appelant sautait les deux. Règle 8 — un contrôle qui n'a
   * jamais eu l'occasion de refuser. Le banc de non-régression est désormais
   * dans `transporteur-projection.spec.ts`, et il part de la commande brute.
   */
  private attachFailures(orders: any[]): any[] {
    if (!orders.length) return orders;

    return this.withEffectiveMeta(orders).map((o) =>
      projectOrderForDriver(o, { extra: projectFailures(o, 'transporteur') }),
    );
  }

  /**
   * Sert la photo d'un signalement, après contrôle d'appartenance.
   *
   * ── L'appartenance est STRUCTURELLE depuis le 03/08/2026 ─────────────────
   *
   * La route porte l'uuid de la **commande**, plus un identifiant global de
   * signalement. Servir la preuve exige donc de résoudre la commande — donc de
   * traverser le contrôle de visibilité, qui vérifie déjà qu'elle concerne ce
   * transporteur. La version précédente cherchait le signalement par son seul
   * identifiant et devait re-vérifier le propriétaire à la main : la discipline
   * anti-IDOR reposait sur le fait que son auteur y avait pensé.
   *
   * ⚠️ **`mine` est exigé EXPLICITEMENT, et il ne l'était pas.** La visibilité
   * couvre deux cas — la course est à moi, ou c'est une adhoc que je peux
   * encore réclamer. Seul le premier donne droit aux preuves. Ça tenait
   * jusqu'ici par un **effet de bord** : la fiche d'une adhoc non réclamée
   * repartait projetée, donc sans `meta.delivery_failures`, donc `findFailure`
   * ne trouvait rien. Une protection qui repose sur ce qu'une projection efface
   * disparaît le jour où l'on déplace la projection — c'est exactement ce que
   * fait le correctif d'à côté. Elle est donc écrite.
   *
   * ⚠️ On ne distingue toujours PAS « pas de preuve » de « preuve d'un autre » :
   * même réponse, et seul le second cas est journalisé. Distinguer serait un
   * oracle.
   */
  async getProofImage(driverId: string, orderId: string, failureId: string) {
    const { order, mine } = await this.resolveVisibleOrder(driverId, orderId);
    const [hydrated] = this.withEffectiveMeta([order]);
    const failure = mine ? findFailure(hydrated ?? order, failureId) : undefined;

    if (!failure) {
      this.audit.denied({
        actorType: 'transporteur',
        actorId: driverId,
        action: 'proof.access',
        resourceType: 'DeliveryFailure',
        resourceId: failureId,
        reason: 'Signalement inexistant sur cette course',
      });
      notFound('order.proof_not_found', 'Aucune preuve pour ce signalement');
    }

    if (!failure.proof_url) {
      notFound('order.proof_not_found', 'Aucune preuve pour ce signalement');
    }

    try {
      return await this.fleetbaseClient.fetchStoredFile(failure.proof_url);
    } catch (error) {
      this.logger.warn(
        `Lecture de la preuve ${failureId} impossible (${failure.proof_url}) : ${error.message}. ` +
          'Si Fleetbase répond « There is nothing to see here », le fichier existe mais ' +
          'aucune route ne le sert : vérifier FLEETBASE_PROOF_DISK=public et que ' +
          '`php artisan storage:link` a bien été exécuté côté Fleetbase.',
      );
      notFound('order.proof_not_found', 'Preuve indisponible');
    }
  }

  /**
   * Extrait la ressource Proof de la réponse de `capture-photo`.
   *
   * Deux pièges, tous deux constatés en réel (28/07/2026) sur un upload qui
   * réussissait pourtant sans erreur :
   *
   * 1. **`uuid` n'existe pas sur l'API publique.** `Http/Resources/v1/Proof`
   *    place `uuid` et `public_id` derrière `Http::isInternalRequest()` ; sur
   *    `v1`, seul `id` est présent, et il porte le public_id. Lire `uuid`
   *    renvoyait donc toujours `null`, et l'app en concluait — logiquement —
   *    que la photo n'avait pas été jointe.
   *
   * 2. **La ressource expose elle-même un champ `data`.** Déballer
   *    aveuglément le premier `data` rencontré, pour traverser l'enveloppe
   *    Laravel, renvoie donc la charge utile de la preuve au lieu de la
   *    preuve. D'où la discrimination sur `url`/`id` plutôt que sur la seule
   *    présence de `data`.
   */
  private extractProof(response: any) {
    for (const candidate of [response?.data, response]) {
      if (candidate && (candidate.url !== undefined || candidate.id !== undefined)) {
        return candidate;
      }
    }
    return response;
  }

  private isAssignedTo(order: any, driverUuid: string) {
    return (
      order?.driver_assigned_uuid === driverUuid ||
      order?.driver_assigned?.uuid === driverUuid
    );
  }

  /**
   * Profil du transporteur, disponibilité comprise.
   *
   * `online` vient de Fleetbase et non d'un état mémorisé côté app : c'est
   * Fleetbase qui décide à qui le dispatch géospatial diffuse une course, donc
   * lui seul sait si ce driver est réellement joignable. Sans ce champ, l'app
   * afficherait au redémarrage la position par défaut de son interrupteur —
   * un driver rouvrant l'app se croirait hors ligne tout en continuant de
   * recevoir des courses, ou l'inverse.
   *
   * `null` quand Fleetbase est injoignable : l'app doit alors afficher un état
   * indéterminé plutôt que d'affirmer « hors ligne », qui serait un mensonge
   * dans le sens dangereux (le driver ne réagit pas à une course reçue).
   */
  /**
   * Les entreprises de ce conducteur — rattachements et demandes en attente.
   *
   * ── Pourquoi le conducteur doit voir ça, et pas seulement l'entreprise ────
   *
   * Un rattachement n'est pas administratif : il décide **à qui il devra les
   * espèces** d'une course. `driverCounterparty()` prend le facilitateur de la
   * commande, donc travailler pour deux entreprises, c'est porter deux dettes
   * distinctes. Un conducteur qui ne sait pas pour qui il roule ne peut pas
   * savoir à qui remettre l'argent.
   *
   * ⚠️ L'entreprise d'origine (`Driver.vendor_uuid`) est incluse et marquée
   * comme telle. La laisser de côté aurait montré une liste où l'employeur
   * principal manque — la moitié la plus importante, et celle qu'on ne pense
   * pas à vérifier parce qu'elle « va de soi ».
   */
  async listMemberships(driverId: string) {
    const driver = await this.getDriverOrFail(driverId);

    const memberships = await this.prisma.driverMembership.findMany({
      where: { fleetbaseDriverUuid: driver.fleetbaseDriverUuid },
      include: { fleet: true },
      orderBy: { requestedAt: 'desc' },
    });

    const rows = memberships.map((m: any) => ({
      id: m.id,
      fleet_id: m.fleetId,
      // Le nom commercial, pas l'email : c'est sous ce nom que le conducteur
      // connaît l'entreprise.
      name: m.fleet?.businessName ?? null,
      status: m.status,
      origin: false,
      requested_at: m.requestedAt,
    }));

    const origin = await this.originFleet(driver.fleetbaseDriverUuid);
    return { data: origin ? [origin, ...rows] : rows };
  }

  /**
   * L'entreprise d'origine, lue chez Fleetbase et non dans notre table.
   *
   * `Driver.vendor_uuid` en est la source de vérité (règle 1) ; le `FleetAccount`
   * n'est là que pour lui donner un nom lisible. Injoignable, on renvoie `null`
   * plutôt qu'une entrée à moitié remplie : une ligne sans nom dans la liste des
   * employeurs se lit comme une entreprise inconnue, ce qui est pire qu'une
   * ligne absente.
   */
  private async originFleet(driverUuid: string): Promise<any | null> {
    let vendorUuid: string | null = null;
    try {
      const driver = await this.fleetbaseClient.getDriverByUuid(driverUuid);
      vendorUuid = driver?.vendor_uuid ?? null;
    } catch (error: any) {
      this.logger.warn(`Entreprise d'origine illisible pour ${driverUuid} : ${error.message}`);
      return null;
    }

    if (!vendorUuid) return null;

    const fleet = await this.prisma.fleetAccount.findUnique({
      where: { fleetbaseVendorUuid: vendorUuid },
    });
    if (!fleet) return null;

    // ⚠️ Le nom vient du `Vendor` : le compte local ne porte plus que le lien
    // et le secret (03/08/2026). Un appel de plus sur un chemin déjà en train
    // d'interroger Fleetbase pour trouver ce vendor.
    const identite = await this.fleetbaseClient.getVendorIdentity(vendorUuid);

    return {
      id: null,
      fleet_id: fleet.id,
      name: identite?.name ?? null,
      status: 'active',
      // Ce qui distingue l'origine d'une adhésion : elle ne se refuse pas et ne
      // se suspend pas depuis l'application. L'écran doit le savoir pour ne pas
      // offrir un bouton sans effet.
      origin: true,
      requested_at: null,
    };
  }

  /**
   * Accepter ou refuser un rattachement.
   *
   * ── Ce que l'acceptation engage réellement ───────────────────────────────
   *
   * Elle autorise l'entreprise à confier des courses — donc à faire porter au
   * conducteur les espèces d'un commerçant, sous forme d'une dette envers elle.
   * C'est pour cela que le rattachement naît `pending` et non `active` : sans ce
   * passage, une entreprise imposerait une obligation financière à quelqu'un qui
   * n'a rien accepté.
   */
  async respondToMembership(driverId: string, membershipId: string, accept: boolean) {
    const driver = await this.getDriverOrFail(driverId);

    const membership = await this.prisma.driverMembership.findUnique({
      where: { id: membershipId },
    });

    // Un seul refus pour « inexistante » et « pas la vôtre » : les distinguer
    // apprendrait au conducteur qu'une adhésion existe pour quelqu'un d'autre.
    if (!membership || membership.fleetbaseDriverUuid !== driver.fleetbaseDriverUuid) {
      notFound('membership.not_found', 'Membership not found');
    }

    if (membership.status !== 'pending') {
      conflict(
        'membership.not_pending',
        'Cette demande a déjà reçu une réponse.',
      );
    }

    const updated = await this.prisma.driverMembership.update({
      where: { id: membership.id },
      data: {
        status: accept ? 'active' : 'declined',
        respondedAt: new Date(),
      },
    });

    this.logger.log(
      `Adhésion ${membershipId} ${accept ? 'acceptée' : 'refusée'} par ${driverId}`,
    );

    return { id: updated.id, status: updated.status };
  }

  /**
   * Quitter une entreprise.
   *
   * ── Pourquoi il faut une sortie, et pas seulement une entrée ─────────────
   *
   * La première version n'avait que l'acceptation : un conducteur ayant dit oui
   * une fois restait rattaché **indéfiniment**, et l'entreprise pouvait
   * continuer à lui confier des courses encaissées. Seule elle pouvait
   * suspendre. Le principe posé par ce chantier — « l'acceptation est une
   * condition de l'engagement » — n'avait alors aucun pendant en sortie, ce qui
   * en fait un consentement à sens unique.
   *
   * ⚠️ **La dette n'est pas éteinte par le départ.** L'adhésion passe à
   * `declined`, le lien reste écrit, et le registre continue de dire ce qui est
   * dû — c'est tout le motif de l'absence de suppression. Partir coupe les
   * courses à venir, pas ce qu'on doit.
   */
  async leaveFleet(driverId: string, membershipId: string) {
    const driver = await this.getDriverOrFail(driverId);

    const membership = await this.prisma.driverMembership.findUnique({
      where: { id: membershipId },
    });

    if (!membership || membership.fleetbaseDriverUuid !== driver.fleetbaseDriverUuid) {
      notFound('membership.not_found', 'Membership not found');
    }

    if (membership.status !== 'active') {
      conflict('membership.not_active', 'Ce rattachement n\'est pas actif.');
    }

    const updated = await this.prisma.driverMembership.update({
      where: { id: membership.id },
      data: { status: 'declined', respondedAt: new Date() },
    });

    this.logger.log(`Conducteur ${driverId} a quitté l'adhésion ${membershipId}`);
    return { id: updated.id, status: updated.status };
  }

  async getProfile(driverId: string) {
    const driver = await this.getDriverOrFail(driverId);

    let online: boolean | null = null;
    try {
      const publicId = await this.getDriverPublicId(driver);
      const record = await this.fleetbaseClient.getDriverByPublicId(publicId);
      const payload = record?.data ?? record?.driver ?? record;
      if (payload?.online !== undefined && payload?.online !== null) {
        online = Boolean(payload.online);
      }
    } catch (error) {
      this.logger.warn(`Could not read online status for driver ${driverId}: ${error.message}`);
    }

    // ⚠️ **Nom, téléphone et véhicule viennent de Fleetbase**, plus d'une copie
    // locale figée à l'inscription. Mesuré le 03/08/2026 : les deux divergeaient
    // sur **trois conducteurs sur trois** — l'application affichait « Test
    // Transporteur » là où la console affichait « Amar BENGHARBI ». Deux copies,
    // et personne ne les comparait.
    //
    // ⚠️ `name` est un seul champ chez Fleetbase ; le contrat servi garde
    // `firstName`/`lastName` pour ne pas casser l'écran, en découpant au
    // premier espace. Le découpage est une **présentation**, pas une donnée :
    // il ne repart jamais en écriture.
    const profil = await this.driverZone.read(driver.fleetbaseDriverUuid);
    const [prenom, ...reste] = (profil.name ?? '').trim().split(/\s+/);

    return {
      id: driver.id,
      email: driver.email,
      firstName: prenom || null,
      lastName: reste.length ? reste.join(' ') : null,
      phone: profil.phone,
      fleetbaseDriverUuid: driver.fleetbaseDriverUuid,
      vehicleType: profil.vehicleType,
      online,
    };
  }

  /**
   * Déclare la catégorie de véhicule du transporteur.
   *
   * Elle filtre les opportunités qu'il voit : une course exigeant un
   * utilitaire ne lui est pas proposée s'il roule en moto. Ne rien déclarer
   * reste le comportement le plus ouvert — il voit tout.
   */
  /**
   * La zone déclarée, et le rayon **proposé** à qui n'a rien réglé.
   *
   * ⚠️ `suggestedRadiusKm` n'est pas `radiusKm`, et les confondre viderait la
   * liste de tous ceux qui n'ont jamais ouvert le réglage. Le premier est une
   * valeur d'écran, le second une décision de l'utilisateur — seul le second
   * filtre quoi que ce soit.
   */
  async readZone(driverId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const { zone, point } = await this.driverZone.read(driver.fleetbaseDriverUuid);
    return {
      wilaya: zone?.wilaya ?? null,
      radius_km: zone?.radiusKm ?? null,
      suggested_radius_km: DEFAULT_ZONE_RADIUS_KM,
      // Dire si la position est connue : sans elle le rayon ne s'applique pas,
      // et l'écran doit pouvoir l'expliquer plutôt que de laisser croire à un
      // filtre qui ne filtre rien.
      position_known: point != null,
    };
  }

  async saveZone(driverId: string, dto: { wilaya?: string | null; radiusKm?: number | null }) {
    const driver = await this.getDriverOrFail(driverId);
    const wilaya = typeof dto.wilaya === 'string' && dto.wilaya.trim() ? dto.wilaya.trim() : null;
    const radiusKm = typeof dto.radiusKm === 'number' ? dto.radiusKm : null;

    // L'identifiant public est indispensable à l'écriture (voir `write`) ; il
    // est résolu et mémorisé par ce helper, donc il ne coûte qu'une fois.
    const publicId = await this.getDriverPublicId(driver);
    await this.driverZone.write(driver.fleetbaseDriverUuid, publicId, { wilaya, radiusKm });

    // Relu plutôt que déduit : le stockage est chez Fleetbase, et rendre ce
    // qu'on vient d'envoyer masquerait un refus silencieux — le mode d'échec
    // habituel de cette API.
    return this.readZone(driverId);
  }

  async updateVehicleType(driverId: string, vehicleType?: string) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);
    // ⚠️ Écrit chez Fleetbase depuis le 03/08/2026, plus dans une colonne du
    // BFF : un opérateur en console peut désormais lire et corriger la
    // catégorie d'un transporteur venu s'en plaindre.
    await this.driverZone.writeVehicleType(
      driver.fleetbaseDriverUuid,
      publicId,
      vehicleType ?? null,
    );
    return { vehicleType: vehicleType ?? null };
  }

  // Note on identifiers below: every /v1 call takes the driver's public_id,
  // never the uuid — see resolveOrder() for why.

  async updatePosition(driverId: string, dto: UpdatePositionDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      await this.fleetbaseClient.trackDriver(publicId, dto);
    } catch (error) {
      this.logger.error(`Position update failed for driver ${driverId}: ${error.message}`);
      badRequest('driver.position_update_failed', 'Failed to update position');
    }

    // Le miroir local a été supprimé (Lot 6) : `track` écrit déjà
    // `Driver.location` chez Fleetbase, et c'est de là que les cartes le lisent
    // désormais. Recopier le point ici revenait à stocker une donnée qu'on
    // venait d'envoyer à sa source.

    return { success: true };
  }

  async toggleOnline(driverId: string, dto: ToggleOnlineDto) {
    const driver = await this.getDriverOrFail(driverId);
    const publicId = await this.getDriverPublicId(driver);

    try {
      const response = await this.fleetbaseClient.toggleDriverOnline(publicId, dto.online);

      // On rapporte ce que Fleetbase dit, pas ce qu'on lui a demandé.
      // L'ancienne version renvoyait `dto.online` tel quel : la réponse était
      // donc toujours celle attendue, y compris si l'écriture n'avait aucun
      // effet. Un test vert sur cette route ne prouvait rien.
      const payload = response?.data ?? response?.driver ?? response;
      const confirmed = payload?.online;

      if (confirmed !== undefined && confirmed !== null) {
        const applied = Boolean(confirmed);
        if (applied !== dto.online) {
          this.logger.warn(
            `Fleetbase a répondu online=${applied} pour une demande de ${dto.online} (driver ${publicId})`,
          );
        }
        return { online: applied };
      }

      // Réponse sans le champ : on ne peut ni confirmer ni infirmer.
      this.logger.warn(`toggle-online sans champ 'online' en réponse (driver ${publicId})`);
      return { online: null as boolean | null, requested: dto.online };
    } catch (error) {
      this.logger.error(`Online toggle failed for driver ${driverId}: ${error.message}`);
      badRequest('driver.online_toggle_failed', 'Failed to update online status');
    }
  }

  /**
   * List the driver's orders.
   *
   * ⚠️ Le contrôle d'appartenance se fait **ici**, dans le BFF.
   *
   * **Correction du 29/07/2026** : la raison invoquée jusqu'ici — « Fleetbase
   * ignore les filtres » — était fausse (nom de paramètre erroné, voir
   * `docs/architecture_bff_fleetbase.md` §4.3). `GET /orders?driver=<uuid>`
   * filtre réellement.
   *
   * **La pratique reste pourtant la bonne, pour une meilleure raison** : un
   * paramètre de requête exprime une demande, pas une garantie. Le jour où le
   * filtre serveur sera utilisé, ce sera pour ne pas rapatrier toute la
   * compagnie — la vérification d'appartenance, elle, restera locale, parce
   * qu'une frontière de sécurité ne se délègue pas à un paramètre d'URL.
   */
  async listOrders(driverId: string, query: ListDriverOrdersQueryDto) {
    const driver = await this.getDriverOrFail(driverId);

    // ── Deux populations sans recouvrement, donc deux requêtes ────────────────
    //
    // Les courses de ce transporteur et les opportunités non réclamées n'ont
    // aucune commande en commun : une course assignée n'est pas libre. Une
    // seule requête ne peut donc pas les couvrir toutes les deux — d'où
    // `?driver=` d'un côté et `?without_driver=true` de l'autre, au lieu du
    // balayage de toute la compagnie qui servait les deux.
    //
    // Chaque onglet ne demande que ce qu'il affiche : ouvrir « mes courses » ne
    // déclenche plus la requête des opportunités, et réciproquement.
    const wantsAssigned = query.type !== 'adhoc';
    const wantsAdhoc = !query.type || query.type === 'adhoc';

    let assignedRaw: any[] = [];
    let adhocRaw: any[] = [];
    try {
      [assignedRaw, adhocRaw] = await Promise.all([
        wantsAssigned
          ? this.fleetbaseClient.fetchEveryOrder(100, 50, {
              driver: driver.fleetbaseDriverUuid,
            })
          : Promise.resolve([]),
        // `without_driver` couvre aussi l'exclusion des états terminaux
        // (completed/canceled/expired), que le filtre en mémoire ci-dessous
        // refaisait partiellement. Les deux sont conservés : le serveur allège,
        // le code décide.
        wantsAdhoc
          ? this.fleetbaseClient.fetchEveryOrder(100, 50, { without_driver: true })
          : Promise.resolve([]),
      ]);
    } catch (error) {
      this.logger.error(`Order list failed for driver ${driverId}: ${error.message}`);
      badRequest('order.fetch_failed', 'Failed to fetch orders');
    }

    // Revérifié en mémoire : le filtre serveur allège la requête, il n'autorise
    // pas. Un nom de filtre qui régresserait serait abandonné en silence par
    // Fleetbase, et cette ligne est ce qui fait qu'une telle régression vide la
    // liste au lieu d'exposer les courses des autres.
    // ⚠️ **Rechargées une par une, et ce n'est pas une optimisation manquée.**
    //
    // `fetchEveryOrder` passe par `GET /orders`, servi par la ressource d'index :
    // `meta` y vaut `{_index_resource: true}` et `custom_field_values` est
    // **absent**. Sans ce rechargement, le transporteur verrait ses courses sans
    // prix, sans montant à encaisser et sans exigence de véhicule — et les
    // filtres ci-dessous décideraient sur du vide.
    //
    // Le filtre d'appartenance passe AVANT : on ne recharge que ce qu'on va
    // servir, jamais toute la compagnie.
    const assigned = await this.fleetbaseClient.hydrateOrders(
      assignedRaw.filter((o) => this.isAssignedTo(o, driver.fleetbaseDriverUuid)),
    );

    // Adhoc opportunities: broadcast, not yet claimed by anyone. Fleetbase's
    // geospatial dispatch decides who gets pinged (specs_echango_delivery §3.2);
    // the BFF only avoids showing orders already taken.
    // Une exigence de véhicule est un MINIMUM, pas une égalité : une course
    // demandant une voiture reste faisable en utilitaire. Et un transporteur
    // qui n'a pas déclaré son véhicule voit tout — être écarté du réseau par un
    // champ non rempli serait le pire des défauts silencieux.
    const ladder = ['moto', 'voiture', 'utilitaire'];
    // ⚠️ **Une seule lecture Fleetbase pour les trois critères.** Catégorie de
    // véhicule, zone déclarée et position sortent de la même réponse : les
    // séparer coûterait trois appels par affichage de liste, sur un
    // environnement où chacun prend ~3 s.
    //
    // ⚠️ La catégorie vivait dans `DriverAccount.vehicleType` jusqu'au
    // 03/08/2026 — une colonne du BFF, donc invisible d'un opérateur.
    const { zone, point, vehicleType } = await this.driverZone.read(
      driver.fleetbaseDriverUuid,
    );
    const mine = ladder.indexOf(vehicleType ?? '');
    // ⚠️ Le filtre lit le `meta` **recomplété**, pas le brut. Sur une commande
    // dont `meta` a été écrasé, `vehicle_type` serait absent et la course
    // passerait pour « sans exigence » : un transporteur en moto se verrait
    // proposer une course qui demande un utilitaire, et le découvrirait devant
    // le colis.
    const suits = (order: any) => {
      if (mine < 0) return true;
      const required = ladder.indexOf(order?.meta?.vehicle_type ?? '');
      return required < 0 || required <= mine;
    };

    // Recomplété AVANT le filtre, pas après : `suits()` lit
    // `meta.vehicle_type`, et le filtrer sur un `meta` effacé reviendrait à
    // traiter la course comme sans exigence.
    //
    // ⚠️ **Le refus se lit désormais SUR la commande**, plus dans une table du
    // BFF (03/08/2026). L'ordre a donc changé : il fallait auparavant une
    // requête en base *avant* de recomposer `meta` ; maintenant le refus **est
    // dans** `meta`, donc il se lit une fois les courses recomposées — sans
    // aucune entrée/sortie supplémentaire, puisqu'elles sont déjà en main.
    //
    // Les courses que CE transporteur a refusées ne lui sont plus proposées.
    // Sans ce filtre, le refus n'aurait aucun effet visible : la course
    // reviendrait au rafraîchissement suivant, et l'écran serait indiscernable
    // d'une fonctionnalité en panne.
    // ⚠️ Rechargement AVANT `withEffectiveMeta`, pour la même raison que
    // ci-dessus : `isClaimableAdhoc` se décide sur des champs que la liste
    // porte (statut, `adhoc`, conducteur), donc il réduit d'abord l'ensemble ;
    // tout ce qui suit lit `meta`, que seule la lecture unitaire fournit.
    const adhocFull = await this.fleetbaseClient.hydrateOrders(
      adhocRaw.filter((o) => this.isClaimableAdhoc(o)),
    );
    const adhocHydrated = this.withEffectiveMeta(adhocFull).filter(
      (o) => !this.hasDeclined(o, driver.fleetbaseDriverUuid),
    );

    // ⚠️ **La zone du transporteur filtre APRÈS le véhicule, et jamais avant.**
    //
    // C'est lui qui choisit sa course (décision produit du 02/08/2026) : la
    // liste ne s'aligne donc pas sur `adhoc_distance`, qui gouverne les
    // sollicitations, mais sur ce qu'il a **déclaré vouloir voir**.
    //
    // `zoneAllows` laisse passer tout ce qu'il ignore — course sans wilaya,
    // course sans point, transporteur sans position, transporteur sans
    // préférence. Motif complet dans `common/orders/driver-zone.ts` : un filtre
    // trop large se remarque et s'ajuste, un filtre trop étroit vide une liste
    // sans que personne ne puisse constater ce qui manque.
    const adhoc = adhocHydrated
      .filter(suits)
      .filter((o) => zoneAllows(o, zone, point));

    // ⚠️ `cancelled` à deux « l » compris : sans lui, une course annulée par le
    // chemin qui emploie cette orthographe restait dans les courses actives du
    // transporteur, indéfiniment.
    const isFinished = (o: any) => isTerminalOrderStatus(o?.status);
    // Projection en liste d'autorisation : le BFF décide de ce qui sort, et
    // non Fleetbase (revue M10). `unclaimed` retire le nom et le téléphone du
    // destinataire, et rien d'autre ; l'enlèvement, qui est un commerce, passe
    // en entier.
    // Déjà complété ci-dessus — une opportunité dont `meta` a été effacé
    // n'annoncerait ni prix ni montant à encaisser, donc rien sur quoi décider
    // de la prendre.
    const publicAdhoc = adhoc.map((o) => projectOrderForDriver(o, { unclaimed: true }));

    if (query.type === 'adhoc') return { orders: publicAdhoc };
    if (query.type === 'history') {
      return { orders: this.attachFailures(assigned.filter(isFinished)) };
    }
    if (query.type === 'assigned') {
      return { orders: this.attachFailures(assigned.filter((o) => !isFinished(o))) };
    }

    return {
      active: this.attachFailures(assigned.filter((o) => !isFinished(o))),
      adhoc: publicAdhoc,
      history: this.attachFailures(assigned.filter(isFinished)),
    };
  }

  /**
   * Fetch one order, enforcing that the driver may see it.
   *
   * Allowed when the order is assigned to them, or when it is an unclaimed
   * adhoc order (a broadcast opportunity they are entitled to consider).
   * Anything else is a 404 rather than a 403 — a driver has no business
   * learning that a given order id exists at all.
   */
  /**
   * La garde d'accès à une course, **écrite une seule fois**.
   *
   * Un transporteur peut ouvrir une course si elle lui est assignée, ou si
   * c'est une adhoc encore libre. Tout le reste est un `404` — jamais un `403`,
   * qui confirmerait l'existence de la commande à qui n'y a pas droit.
   *
   * ⚠️ **Ces dix lignes existaient en deux copies** (détecteur de corps
   * similaires, 01/08/2026, 97 %), ne différant que par l'`action` inscrite au
   * journal d'audit. C'est exactement la forme du défaut fondateur de la
   * règle 5 : `isClaimable` et `isClaimableAdhoc`, deux copies d'une même
   * décision d'accès, qui ont divergé sur `completed` et affiché une course
   * livrée dans « Courses libres » avec un bouton pour la prendre. Une garde de
   * sécurité recopiée est une garde qui finira par ne plus protéger qu'un
   * chemin sur deux.
   */
  private assertOrderVisible(
    order: any,
    driverId: string,
    driverUuid: string,
    orderId: string,
    action: string,
  ): { mine: boolean; claimableAdhoc: boolean } {
    if (!order) {
      notFound('order.not_found', 'Order not found');
    }

    const mine = this.isAssignedTo(order, driverUuid);
    const claimableAdhoc = this.isClaimableAdhoc(order);

    if (!mine && !claimableAdhoc) {
      this.audit.denied({
        actorType: 'transporteur',
        actorId: driverId,
        action,
        resourceType: 'Order',
        resourceId: orderId,
        reason: 'Commande ni assignée à ce driver ni adhoc disponible',
      });
      notFound('order.not_found', 'Order not found');
    }

    return { mine, claimableAdhoc };
  }

  /**
   * La commande **brute**, après contrôle de visibilité — usage INTERNE.
   *
   * ⚠️ **Ne jamais rendre ça par une route.** C'est l'objet Fleetbase entier :
   * `declines`, `proof_url`, `custom_field_values`, toutes les relations. Les
   * écritures en ont besoin (`orderPublicId`, `isAssignedTo`, la liste courante
   * des signalements avant un ajout) ; un client, non.
   *
   * ── Pourquoi c'est une fonction séparée depuis le 03/08/2026 ──────────────
   *
   * `getOrder()` servait les deux rôles : résolveur pour huit écritures, et
   * gestionnaire de `GET /transporteur/commandes/:id`. Une seule valeur de
   * retour ne pouvait donc pas être à la fois brute et projetée — et c'est le
   * **brut** qui gagnait, puisque c'est ce dont le code interne avait besoin
   * pour fonctionner. La fuite était la conséquence silencieuse de ce partage :
   * rien ne cassait, la route servait simplement plus que prévu.
   */
  private async resolveVisibleOrder(
    driverId: string,
    orderId: string,
  ): Promise<{ order: any; mine: boolean }> {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.resolveOrder(orderId);

    const { mine } = this.assertOrderVisible(
      order,
      driverId,
      driver.fleetbaseDriverUuid,
      orderId,
      'order.access',
    );

    return { order, mine };
  }

  /**
   * La fiche d'une course, **telle qu'elle sort du BFF**.
   *
   * Seule frontière HTTP de la lecture unitaire : tout ce qui est rendu ici est
   * passé par une liste d'autorisation.
   */
  async getOrder(driverId: string, orderId: string) {
    const { order, mine } = await this.resolveVisibleOrder(driverId, orderId);

    // Une adhoc que ce driver n'a pas encore réclamée passe par la même
    // expurgation que la liste. Sans ça, la protection ne tiendrait pas une
    // seconde : il suffirait d'ouvrir la fiche pour obtenir le nom, l'adresse
    // exacte et le téléphone que la liste venait de retirer.
    if (!mine) {
      const [hydrated] = this.withEffectiveMeta([order]);
      return projectOrderForDriver(hydrated ?? order, { unclaimed: true });
    }

    const [withFailure] = this.attachFailures([order]);
    return withFailure;
  }

  /**
   * Refuse une course, avec un motif.
   *
   * ── Deux effets, selon d'où vient la course ────────────────────────────────
   *
   * **Diffusée et non réclamée** : elle disparaît de la liste de ce
   * transporteur, et de lui seul. Rien ne change pour les autres, ni pour le
   * commerçant — refuser une proposition n'est pas un évènement.
   *
   * **Assignée à lui** (favori sollicité en premier) : elle est détachée et
   * remise en diffusion, et le commerçant est prévenu. Sans ce chemin, une
   * course confiée à un favori indisponible restait bloquée jusqu'à
   * intervention manuelle — la limite explicitement signalée par
   * `pickAvailableFavourite()`. Le refus ne la lève pas entièrement (un favori
   * qui ignore la course sans rien dire la bloque toujours), mais il traite le
   * cas où le transporteur, lui, sait qu'il ne la prendra pas.
   *
   * ── Ce qui n'est pas refusable ─────────────────────────────────────────────
   *
   * Une course déjà démarrée. À ce stade le transporteur est engagé, souvent en
   * route : la sortie est le signalement d'échec (`/echec`), qui laisse une
   * trace et une preuve. Rendre une course en cours par un simple refus
   * effacerait cette obligation.
   */
  async declineOrder(driverId: string, orderId: string, dto: DeclineOrderDto) {
    const driver = await this.getDriverOrFail(driverId);
    const order = await this.resolveOrder(orderId);

    const { mine, claimableAdhoc } = this.assertOrderVisible(
      order,
      driverId,
      driver.fleetbaseDriverUuid,
      orderId,
      'order.decline',
    );

    if (mine && !['created', 'dispatched'].includes(order?.status)) {
      badRequest(
        'order.already_started',
        'Cette course est déjà démarrée : signalez un échec de livraison plutôt que de la refuser.',
      );
    }

    // Le détachement AVANT l'enregistrement : si Fleetbase refuse, la course
    // reste assignée, et prétendre l'avoir refusée serait un mensonge visible
    // à l'écran suivant. On échoue bruyamment plutôt que d'enregistrer un
    // refus sans effet.
    if (mine) {
      try {
        await this.fleetbaseClient.releaseOrderToPool(
          order.uuid,
          this.adhocRadiusMetres(),
        );
      } catch (error: any) {
        this.logger.error(`Remise au pool impossible (${orderId}) : ${error.message}`);
        badRequest(
          'order.release_failed',
          error.response?.data?.errors?.[0] ||
            "Impossible de rendre cette course pour l'instant",
        );
      }
    }

    // Entrées tarifaires copiées, pas référencées : c'est l'appariement « ce
    // qui était offert » / « refusé pour tel motif » qui a de la valeur, et il
    // disparaît dès que la commande change ou est supprimée.
    //
    // Recomplété d'abord : sans ça, un refus sur une commande dont `meta` a été
    // écrasé enregistrerait un motif sans le prix qui l'explique — c'est-à-dire
    // précisément la moitié inutile de la paire.
    const [hydratedForDecline] = this.withEffectiveMeta([order]);
    const meta = hydratedForDecline?.meta ?? order?.meta ?? {};

    // ⚠️ Le refus est écrit SUR LA COMMANDE depuis le 03/08/2026, plus dans une
    // table du BFF. Motif : la console est utilisée en exploitation, et un
    // opérateur qui ouvre une course immobile doit pouvoir lire « six refus,
    // prix trop bas » sans nous appeler. Une donnée qui explique un blocage et
    // qui n'est lisible que du BFF est une donnée qui manque là où on la
    // cherche.
    //
    // L'unicité par (conducteur, course) était tenue par un `@@unique` ; elle
    // l'est maintenant par le dédoublonnage passé à `appendToOrderList`, dont
    // la fenêtre de concurrence est documentée là-bas.
    const written = await this.orderCustomFields.appendToOrderList(
      this.orderPublicId(order),
      hydratedForDecline ?? order,
      'declines',
      {
        driver_uuid: driver.fleetbaseDriverUuid,
        reason: dto.reason,
        notes: dto.notes ?? null,
        was_assigned: mine,
        // Copiées, pas référencées : c'est l'appariement « ce qui était
        // offert » / « refusé pour tel motif » qui a de la valeur, et il
        // disparaît dès que la commande change.
        pricing_inputs: meta.pricing_inputs ?? null,
        offered_price: typeof meta.price === 'number' ? meta.price : null,
        currency: typeof meta.currency === 'string' ? meta.currency : null,
        declined_at: new Date().toISOString(),
      },
      (e) => e?.driver_uuid === driver.fleetbaseDriverUuid,
    );

    if (!written) {
      // ⚠️ Refuser plutôt que de laisser croire au refus. Un refus non
      // enregistré, c'est la course qui revient au rafraîchissement suivant :
      // l'écran devient indiscernable d'une fonctionnalité en panne, et c'est
      // exactement ce que ce chemin existe pour empêcher.
      badRequest(
        'order.decline_not_recorded',
        'Votre refus n\'a pas pu être enregistré. Réessayez dans un instant.',
      );
    }

    if (mine) {
      // Le cache est aligné AVANT de notifier, et c'est ce qui évite un
      // doublon : le réconciliateur détecte le désistement en comparant le
      // transporteur assigné qu'il a mémorisé à celui de Fleetbase. Laisser
      // l'ancien en place lui ferait voir la même transition au passage
      // suivant, et le commerçant recevrait deux fois le même message — une
      // fois d'ici, une fois de là.
      //
      // `updateMany` et non `update` : la commande peut ne pas être dans le
      // cache (créée depuis la console par un opérateur), auquel cas il n'y a
      // rien à aligner et rien à signaler.
      await this.prisma.order
        .updateMany({
          where: { fleetbaseOrderId: order.uuid },
          data: { driverAssignedUuid: null },
        })
        .catch((error: any) =>
          this.logger.warn(`Cache non aligné après refus (${orderId}) : ${error.message}`),
        );

      await this.notifications.notifyOrderOwner(order.uuid, {
        type: 'order.released',
        title: 'Transporteur désisté',
        body: 'Votre livraison a été proposée à nouveau aux transporteurs du réseau.',
      });
    }

    this.logger.log(
      `Course ${orderId} refusée par ${driverId} (${dto.reason}${mine ? ', remise au pool' : ''})`,
    );

    return {
      // ⚠️ Plus d'`id` : le refus n'est plus une ligne, c'est un élément d'une
      // liste portée par la commande. Il n'avait aucun lecteur — l'application
      // ne se sert que de `releasedToPool`, qui décide du message affiché.
      reason: dto.reason,
      /** La course est-elle repartie au réseau, ou seulement masquée ? */
      releasedToPool: mine,
    };
  }

  /**
   * Rayon de rediffusion d'une course rendue.
   *
   * ⚠️ **La même valeur qu'à la création, et c'est maintenant tenu plutôt
   * qu'affirmé.** Une course rendue doit être proposée exactement comme elle
   * l'aurait été si le favori n'avait pas été sollicité — sans quoi le refus
   * changerait silencieusement sa portée. Ce commentaire disait déjà cet
   * invariant tout en le laissant à deux copies : c'est le signal même de la
   * règle 5, et il a fallu le lire pour le voir.
   */
  private adhocRadiusMetres(): number {
    // Aliasé à l'import : sans alias, l'appel se lirait comme une récursion
    // sur la méthode du même nom. Il n'en est pas une — un identifiant nu
    // résout le module et non la méthode — mais rien ne le dit à la lecture.
    return configuredAdhocRadius(this.configService.get('ADHOC_RADIUS_METRES'));
  }

  /**
   * Claim an adhoc order. Fleetbase does this in a single call: start with
   * `assign` set, which both assigns the driver and starts the order — the
   * behaviour §4.2 describes for "Accepter" ("assigne le driver et démarre
   * immédiatement").
   */
  async acceptOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (order?.driver_assigned_uuid && !this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.already_taken', 'This order has already been taken by another driver');
    }

    // ⚠️ Un plafond de dette était vérifié ici, et il a été retiré le
    // 03/08/2026 avec le registre de caisse — pas par négligence, par
    // impossibilité : ce qu'un transporteur détient, c'est l'argent encaissé
    // **et pas encore remis**, et sans registre des remises nous ne savons pas
    // ce qui a été rendu. Un plafond calculé sur autre chose aurait borné une
    // exposition qui n'est pas celle qui compte.
    //
    // Le risque n'a pas disparu, il a changé de porteur : l'entreprise pour
    // ses conducteurs, le commerçant pour un indépendant (décision produit du
    // 03/08/2026, `docs/registre_caisse_precis.md`).

    const publicId = await this.getDriverPublicId(driver);

    try {
      const result = await this.fleetbaseClient.startOrder(this.orderPublicId(order), publicId);
      this.logger.log(`Driver ${driverId} accepted order ${orderId}`);
      return result;
    } catch (error) {
      this.logger.error(`Accept failed (${orderId}): ${error.message}`);
      // Losing a race for an adhoc order is expected, not exceptional.
      badRequest('order.accept_failed', error.response?.data?.errors?.[0] || 'Failed to accept this order');
    }
  }

  async startOrder(driverId: string, orderId: string) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    // ⚠️ Second point de vérification du plafond de dette, retiré avec le
    // premier le 03/08/2026 — même motif (`docs/registre_caisse_precis.md`).

    try {
      return await this.fleetbaseClient.startOrder(this.orderPublicId(order));
    } catch (error) {
      this.logger.error(`Start failed (${orderId}): ${error.message}`);
      badRequest('order.start_failed', error.response?.data?.errors?.[0] || 'Failed to start this order');
    }
  }

  /**
   * Clôture la livraison.
   *
   * ── L'encaissement fait partie de la clôture, il ne la suit pas ─────────────
   *
   * Sur une course payée à la réception, l'appel est **refusé sans déclaration
   * d'encaissement**. En faire une étape distincte et facultative garantirait
   * qu'elle soit oubliée un jour de pluie — et un encaissement non déclaré est
   * exactement ce que le registre existe pour empêcher. « Livré » et « perçu X »
   * sont un seul fait (`specs_paiement_livraison.md` §4.2).
   *
   * L'ordre importe : le registre est écrit **avant** la clôture Fleetbase. Si
   * l'écriture du registre échoue, la commande reste ouverte et le transporteur
   * peut réessayer ; dans l'ordre inverse, on aurait une livraison close dont
   * l'argent n'est comptabilisé nulle part — c'est-à-dire une somme perdue pour
   * le commerçant, sans trace de qui la détient.
   */
  async completeOrder(driverId: string, orderId: string, cash?: CashCollectionDto) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    await this.recordCollectionIfDue(order, cash);

    try {
      return await this.fleetbaseClient.completeOrder(this.orderPublicId(order));
    } catch (error) {
      this.logger.error(`Complete failed (${orderId}): ${error.message}`);
      badRequest('order.complete_failed', error.response?.data?.errors?.[0] || 'Failed to complete this order');
    }
  }

  /**
   * The transitions available on this order right now.
   *
   * The app needs this before it can call updateActivity at all: the order
   * detail carries no activity data (§6.9), so there is nothing to hand back
   * without asking for it. Entries flagged require_pod are what tell the app
   * to route through the proof screen first.
   */
  async getNextActivities(driverId: string, orderId: string, waypoint?: string) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    try {
      return await this.fleetbaseClient.getNextActivities(this.orderPublicId(order), waypoint);
    } catch (error) {
      this.logger.error(`Next activities failed (${orderId}): ${error.message}`);
      badRequest('order.activities_fetch_failed', 'Failed to fetch available activities');
    }
  }


  /**
   * Consigne ce qui s'est passé à la porte, avant de clôturer la livraison.
   *
   * ── Appelée depuis les DEUX chemins de clôture, et c'est essentiel ─────────
   *
   * `POST /terminer` n'est pas le seul moyen de clore une livraison :
   * l'application suit en réalité les transitions que le serveur lui propose
   * (`next-activity`), et la transition terminale passe par `update-activity`.
   * Poser la garde sur le seul `terminer` l'aurait rendue décorative — le
   * chemin réellement emprunté par l'app l'aurait contournée, et une livraison
   * encaissée se serait close sans que le montant perçu figure nulle part.
   *
   * ── L'ordre n'est pas indifférent ─────────────────────────────────────────
   *
   * La déclaration s'écrit **avant** la clôture Fleetbase. Si l'écriture
   * échoue, la commande reste ouverte et le transporteur peut réessayer ; dans
   * l'ordre inverse, on obtiendrait une livraison close et un encaissement
   * dont rien ne garde trace. C'est la règle 2 : sans transaction entre les
   * deux systèmes, la plus réversible d'abord.
   *
   * ── Ce que cette fonction ne fait plus, et pourquoi ────────────────────────
   *
   * Elle écrivait dans un registre de caisse — dette du conducteur, part du
   * facilitateur, rémunération, commission. Ce registre est retiré depuis le
   * 03/08/2026 : tenir des soldes est de la trésorerie, pas de la logistique
   * (`docs/registre_caisse_precis.md`). Ce qui reste est le **fait** : combien
   * a été perçu, quand, et pourquoi ça diffère de ce qui était annoncé.
   *
   * ⚠️ **La reprise devient sûre sans garde d'idempotence, et c'est un gain.**
   * Le registre accumulait des lignes, donc un réessai après échec réseau
   * exigeait une logique explicite pour ne pas compter deux fois — celle des
   * remises manquait, et trois déclarations pour une même dette étaient
   * acceptées (mesuré le 03/08/2026). Ici la même valeur écrite deux fois
   * donne le même état : il n'y a rien à garder.
   */
  private async recordCollectionIfDue(order: any, cash?: CashCollectionDto): Promise<void> {
    // ⚠️ `meta` recomplété AVANT toute lecture de montant. Une affectation
    // depuis la console l'efface, et lire le `meta` brut donnerait ici
    // `codAmount = 0` : la course se clôturerait sans déclaration, alors que
    // le transporteur tient l'argent.
    const [hydrated] = this.withEffectiveMeta([order]);
    const meta = hydrated?.meta ?? order?.meta;

    const codAmount = Number(meta?.cod_amount) || 0;

    // Rien n'était à percevoir à la porte : rien à consigner.
    if (codAmount <= 0) return;

    const currency = platformCurrency(this.configService.get('CURRENCY'));

    if (!cash) {
      badRequest(
        'cash.cod_declaration_required',
        `Cette livraison est payée à la réception (${codAmount} ${currency}) : ` +
          'déclarez le montant encaissé pour la clôturer.',
      );
    }

    const collected = assertCollectedAmount(
      cash.collectedAmount,
      codAmount,
      cash.discrepancyReason,
      currency,
    );

    const written = await this.orderCustomFields.writeToOrder(this.orderPublicId(order), {
      collected_amount: collected,
      collected_at: new Date().toISOString(),
      // Absent quand les deux montants coïncident : poser un motif sur une
      // déclaration sans écart rendrait illisible celle qui en a un.
      ...(collected !== codAmount ? { collection_reason: cash.discrepancyReason } : {}),
    });

    if (!written) {
      // ⚠️ Le pire des deux mondes serait un succès muet : la livraison se
      // clôture, le transporteur repart avec l'argent, et rien n'en garde
      // trace. Refuser laisse la course reprenable — c'est la règle 10, un
      // défaut n'a pas de valeur par défaut.
      badRequest(
        'cash.collection_not_recorded',
        "L'encaissement n'a pas pu être enregistré. Ne clôturez pas cette livraison : réessayez.",
      );
    }

    this.logger.log(
      `Encaissement ${order.uuid} : ${collected} ${currency} perçus sur ${codAmount} annoncés`,
    );
  }

  /**
   * Cette course est-elle **libre**, donc réclamable par un indépendant ?
   *
   * ── Un seul prédicat, et c'est l'énumération qui est la spécification ─────
   *
   * Ce test était redérivé à quatre endroits — la liste, la fiche, le refus et
   * l'acceptation — et aucun ne regardait le facilitateur. Le jour où une
   * course porte `facilitator_uuid` sans conducteur, **tous les indépendants du
   * réseau la verraient et pourraient la prendre** (défaut D4).
   *
   * Corriger la liste seule aurait laissé la fiche et la prise ouvertes à qui
   * connaît l'uuid — et l'uuid, c'est précisément ce que la liste donnait la
   * veille. C'est la leçon du 28/07, où l'expurgation des opportunités avait dû
   * couvrir la liste **et** la fiche pour la même raison.
   *
   * ⚠️ Le facilitateur est un critère **d'exclusion**, pas d'appartenance :
   * une course confiée à une entreprise n'est pas libre, point. Savoir si le
   * conducteur appartient à cette entreprise ne change rien — elle lui sera
   * affectée par son employeur, elle ne se réclame pas.
   */
  /**
   * Ce transporteur a-t-il déjà refusé cette course ?
   *
   * ⚠️ **Lu sur la commande, et donc gratuit** : `meta.declines` arrive avec la
   * course, il n'y a rien à interroger. La version précédente faisait une
   * requête en base par liste servie.
   *
   * ⚠️ **Laisse passer ce qu'il ne comprend pas**, comme le filtre de zone et
   * pour la même raison : une course montrée à tort est un désagrément qui se
   * remarque et se corrige ; une course jamais montrée est un manque à gagner
   * que personne ne peut constater.
   */
  private hasDeclined(order: any, driverUuid?: string | null): boolean {
    if (!driverUuid) return false;
    const declines = order?.meta?.declines;
    if (!Array.isArray(declines)) return false;
    return declines.some((d: any) => d?.driver_uuid === driverUuid);
  }

  private isClaimableAdhoc(order: any): boolean {
    return isOrderClaimable(order);
  }

  /**
   * Cette transition clôt-elle la livraison ?
   *
   * ── Pourquoi ce n'est plus un littéral (revue du 01/08/2026, S4) ──────────
   *
   * La garde « pas de clôture sans déclaration d'encaissement » était accrochée
   * à la chaîne `'completed'`, alors que la source de vérité est le `flow` de
   * l'`OrderConfig` — **modifiable depuis la console**, et choisie par
   * `configs.find(key === 'transport') || configs[0]`. Le jour où l'activité
   * terminale d'une configuration porte un autre code, une livraison encaissée
   * se clôturait sans que `recordCollectionIfDue()` ne s'exécute : livraison close,
   * argent dans la poche du conducteur, aucune `CashCollection`, aucune dette,
   * et rien pour le dire. C'est le mode d'échec exact du §16, où la même garde
   * était décorative pour une autre raison.
   *
   * Chaque entrée du `flow` porte un drapeau `complete` — vérifié le 01/08/2026
   * sur la configuration réelle : `created/enroute/started/dispatched` à
   * `false`, `completed` à `true`. Et `next-activity`, d'où l'application tire
   * l'objet qu'elle nous renvoie, sert ces entrées telles quelles ; le DTO les
   * laisse passer intactes (`Record<string, any>`).
   *
   * Le drapeau **fait donc autorité dans les deux sens** : `false` veut dire que
   * la configuration ne clôt pas ici, quel que soit le code. Le littéral ne
   * subsiste qu'en repli, pour un client qui enverrait une activité amputée — et
   * il le dit, plutôt que de décider en silence.
   */
  private isTerminalActivity(activity: any): boolean {
    if (typeof activity?.complete === 'boolean') return activity.complete;

    this.logger.warn(
      `Activité « ${activity?.code ?? '?'} » reçue sans son drapeau « complete » — ` +
        'la clôture est déduite du code, ce qui est faux dès que la configuration ' +
        'de commande emploie un autre vocabulaire',
    );
    return activity?.code === 'completed' || activity?.status === 'completed';
  }

  async updateActivity(driverId: string, orderId: string, dto: UpdateActivityDto) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    // La transition terminale exige la déclaration d'encaissement au même titre
    // que `POST /terminer` : c'est ce chemin-ci que l'application emprunte.
    if (this.isTerminalActivity(dto.activity)) {
      await this.recordCollectionIfDue(order, dto.cash);
    }

    try {
      return await this.fleetbaseClient.updateOrderActivity(
        this.orderPublicId(order),
        dto.activity,
        dto.proof,
      );
    } catch (error) {
      this.logger.error(`Activity update failed (${orderId}): ${error.message}`);
      badRequest('order.activity_update_failed', error.response?.data?.errors?.[0] || 'Failed to update activity');
    }
  }

  async capturePhoto(driverId: string, orderId: string, dto: CapturePhotoDto) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    try {
      return await this.fleetbaseClient.captureOrderPhoto(
        this.orderPublicId(order),
        dto.photos,
        dto.remarks,
        dto.subjectId,
      );
    } catch (error) {
      this.logger.error(`Proof capture failed (${orderId}): ${error.message}`);
      // Surface Fleetbase's own message: a proof upload can fail for reasons
      // the driver can act on (image rejected) or not at all (storage disk
      // misconfigured), and a flat "failed" hides which.
      const detail =
        error.response?.data?.errors?.[0] ||
        error.response?.data?.error ||
        error.response?.data?.message;
      badRequest('order.proof_upload_failed', detail ? `Failed to upload proof: ${detail}` : 'Failed to upload proof');
    }
  }

  /**
   * Report a failed delivery (docs/specs_app_transporteur.md §4.3).
   *
   * The failure record lives in the BFF because a native per-waypoint "failed"
   * status is still unconfirmed on the Fleetbase side (§4.3 lists it as
   * to-verify). What we can do today is make it visible to whoever is watching
   * the order in Fleetbase, which is why an attached photo is pushed as a Proof
   * carrying the reason in its remarks.
   *
   * The photo upload is deliberately best-effort: a driver standing at a closed
   * door must be able to record the failure even on a bad connection, so an
   * upload error must not discard the report itself.
   */
  async reportDeliveryFailure(driverId: string, orderId: string, dto: ReportDeliveryFailureDto) {
    const driver = await this.getDriverOrFail(driverId);
    const { order } = await this.resolveVisibleOrder(driverId, orderId);
    // Recompose avant l'ecriture : `appendToOrderList` lit la liste actuelle
    // dans `meta` ; la lire sur un `meta` efface par la console repartirait
    // d'une liste vide, et les signalements precedents disparaitraient.
    const [hydrated] = this.withEffectiveMeta([order]);

    if (!this.isAssignedTo(order, driver.fleetbaseDriverUuid)) {
      badRequest('order.not_assigned_to_driver', 'This order is not assigned to you');
    }

    let fleetbaseProofUuid: string | null = null;
    let proofUrl: string | null = null;

    // Tracé explicitement, y compris l'absence : sans cette ligne, « aucune
    // photo envoyée » et « photo envoyée mais rejetée » ne se distinguent que
    // par la présence d'un avertissement — donc pas du tout, dès que les logs
    // ont défilé. Le diagnostic a coûté un aller-retour pour cette raison.
    this.logger.log(
      `Delivery failure report on ${orderId}: photo ${
        dto.photo ? `présente (${Math.round(dto.photo.length / 1024)} ko base64)` : 'absente'
      }`,
    );

    if (dto.photo) {
      try {
        const remarks = `Échec de livraison : ${dto.reason}${dto.notes ? ` — ${dto.notes}` : ''}`;
        const proof = await this.fleetbaseClient.captureOrderPhoto(
          this.orderPublicId(order),
          [dto.photo],
          remarks.slice(0, 255),
          dto.waypointUuid,
        );
        const record = this.extractProof(proof);
        // `uuid` n'est PAS exposé sur l'API publique (voir extractProof) :
        // `id` y porte le public_id, seul identifiant disponible. On garde le
        // premier des deux qui existe — cette référence n'est qu'opaque.
        fleetbaseProofUuid = record?.uuid || record?.id || null;
        proofUrl = record?.url || null;

        // Tracer ce qu'on a réellement su extraire : c'est cette information
        // qui manquait pour comprendre pourquoi un upload réussi ressortait
        // comme « photo non jointe ». Les clés brutes en dernier recours,
        // quand rien n'a été trouvé — la forme de la réponse est alors la
        // seule chose à regarder.
        if (proofUrl || fleetbaseProofUuid) {
          this.logger.log(`Preuve enregistrée : url=${proofUrl ?? '—'} ref=${fleetbaseProofUuid ?? '—'}`);
        } else {
          this.logger.warn(
            `Preuve acceptée par Fleetbase mais illisible dans la réponse. ` +
              `Clés reçues : ${Object.keys(record ?? {}).join(', ') || '(aucune)'}`,
          );
        }
      } catch (error) {
        // `error` d'axios porte le détail utile dans response.data ; le
        // `message` seul dit « Request failed with status code 500 », ce qui
        // n'aide à rien quand c'est justement le serveur amont qui refuse.
        const detail = error?.response?.data
          ? JSON.stringify(error.response.data)
          : error.message;
        this.logger.warn(
          `Delivery failure photo upload failed (${orderId}), keeping the report: ${detail}`,
        );
      }
    }

    // ⚠️ Écrit SUR LA COMMANDE depuis le 03/08/2026, plus dans une table du
    // BFF : c'est la donnée qui explique le mieux pourquoi une livraison
    // n'aboutit pas, et un opérateur en console devait nous appeler pour
    // l'obtenir (`docs/registre_caisse_precis.md` pour le motif général).
    const failureId = randomUUID();
    const reportedAt = new Date().toISOString();
    const written = await this.orderCustomFields.appendToOrderList(
      this.orderPublicId(order),
      hydrated ?? order,
      'delivery_failures',
      {
        id: failureId,
        driver_uuid: driver.fleetbaseDriverUuid,
        waypoint_uuid: dto.waypointUuid ?? null,
        reason: dto.reason,
        notes: dto.notes ?? null,
        proof_url: proofUrl,
        proof_ref: fleetbaseProofUuid,
        reported_at: reportedAt,
      },
      // Chaque signalement est un fait distinct — trois échecs successifs sur
      // la même course sont trois lignes. Rien à dédoublonner, donc.
      () => false,
    );

    if (!written) {
      badRequest(
        'order.failure_not_recorded',
        'Le signalement n\'a pas pu être enregistré. Réessayez dans un instant.',
      );
    }

    this.logger.log(`Delivery failure reported: order ${orderId}, reason ${dto.reason}`);

    // Le commerçant est prévenu tout de suite, sans attendre le
    // réconciliateur : un échec de livraison ne change pas le statut Fleetbase
    // de la commande (§6.5 — pas de statut « failed » natif confirmé), donc
    // rien d'observable ne le trahirait. C'est aussi la notification la plus
    // urgente des cinq : c'est la seule qui demande au commerçant d'agir.
    await this.notifications.notifyOrderOwner(order.uuid || orderId, {
      type: 'order.failed',
      title: 'Échec de livraison',
      body: `Le transporteur n'a pas pu livrer : ${dto.reason.replace(/_/g, ' ')}.`,
    });

    return {
      id: failureId,
      reason: dto.reason,
      // Ce qui compte pour l'appelant est que Fleetbase ait bien stocké la
      // photo, pas qu'on ait su en relire tel identifiant : l'URL est le
      // signal fiable, l'identifiant dépend de l'API empruntée.
      photoUploaded: Boolean(proofUrl || fleetbaseProofUuid),
      photoUrl: proofUrl ? `/transporteur/commandes/${order.uuid}/preuves/${failureId}` : null,
      reportedAt,
    };
  }
}
