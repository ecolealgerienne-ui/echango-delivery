import { Injectable, Logger } from '@nestjs/common';
import axios, { AxiosInstance } from 'axios';

/**
 * ── Filtres de requête Fleetbase — liste fermée, et volontairement fermée ────
 *
 * Fleetbase résout un filtre en cherchant une **méthode du même nom** sur sa
 * classe de filtre, sous le nom brut puis en camelCase. **Il n'y a aucun
 * repli** : un paramètre sans méthode correspondante est abandonné en silence,
 * sans erreur ni code 400 (`core-api/src/Http/Filter/Filter.php`).
 *
 * Conséquence, et c'est toute la raison d'être de ces types : **une faute de
 * frappe ne se voit pas**. Elle ne casse rien, elle élargit — la requête
 * renvoie toute la compagnie au lieu de la portée demandée, et le code qui suit
 * a l'air de fonctionner. C'est exactement ce qui s'est produit avec
 * `facilitator_uuid` (le vrai nom est `facilitator`), erreur restée en place
 * plusieurs jours et sur laquelle trois mécanismes de filtrage applicatif ont
 * été construits.
 *
 * Le compilateur remplace donc le 400 que Fleetbase ne renvoie pas.
 *
 * **N'ajouter un nom ici qu'après l'avoir vérifié par appel réel**, avec la
 * comparaison valide/inexistant de `scripts/verify-fleetbase-filters.sh` : un
 * filtre ignoré renvoie un sur-ensemble, donc il « a l'air » de marcher.
 *
 * Vérifiés le 29/07/2026 (`docs/architecture_bff_fleetbase.md` §4.2).
 */
export interface OrderFilters {
  /** uuid du Vendor client — le commerçant. */
  customer?: string;
  /** uuid du Vendor facilitateur — la petite flotte. */
  facilitator?: string;
  /** uuid du Driver assigné. Accepte aussi un public_id. */
  driver?: string;
  /** Non assignées **et** non terminées : `whereDoesntHave` + exclusion de completed/canceled/expired. */
  without_driver?: boolean;
  status?: string;
}

/**
 * ⚠️ `phone` est absent, et ce n'est pas un oubli : `DriverFilter::phone()`
 * renvoie **500** (`whereHas` sur un attribut calculé, bug amont confirmé par
 * appel réel). `query` couvre le téléphone par la bonne relation.
 */
export interface DriverFilters {
  /** Recherche libre sur nom, email et téléphone, via la relation `user`. */
  query?: string;
  /** uuid du Vendor propriétaire. */
  vendor?: string;
  fleet?: string;
  status?: string;
  page?: number;
  limit?: number;
}

@Injectable()
export class FleetbaseApiClient {
  private readonly logger = new Logger(FleetbaseApiClient.name);
  private readonly apiClient: AxiosInstance;

  constructor() {
    const baseURL = process.env.FLEETBASE_API_URL || 'http://localhost:8000';
    const apiKey = process.env.FLEETBASE_API_KEY;

    this.apiClient = axios.create({
      baseURL,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000,
    });

    this.apiClient.interceptors.response.use(
      (response) => response,
      (error) => {
        if (error.response) {
          this.logger.error(
            `Fleetbase API error: ${error.response.status} ${error.config?.method?.toUpperCase()} ${error.config?.url} - ${JSON.stringify(error.response.data)}`,
          );
        } else {
          this.logger.error(`Fleetbase API error: ${error.message}`);
        }
        throw error;
      },
    );
  }

  /**
   * Call Fleetbase customer-portal-api endpoint
   * Used for merchant operations (read/write orders, etc.)
   */
  async callCustomerPortal(method: string, path: string, data?: any, token?: string, params?: any) {
    const headers = token ? { 'Authorization': `Bearer ${token}` } : {};
    return this.apiClient({
      method,
      url: `/customer-portal/int/v1${path}`,
      data,
      params,
      headers,
    });
  }


  /**
   * Encode un identifiant destiné à un segment d'URL Fleetbase.
   *
   * ⚠️ Sans ça, un identifiant contrôlé par le client détourne la requête vers
   * une autre route, exécutée avec le token de service qui a tous les droits
   * sur l'organisation (revue E3/M8). Exemple réel :
   * `subjectId = "../../ORDER_X/cancel"` transforme
   * `/v1/orders/ORDER_A/capture-photo/<subjectId>` en
   * `/v1/orders/ORDER_X/cancel` après normalisation par le serveur amont — le
   * contrôle d'appartenance ayant porté sur ORDER_A.
   *
   * Deux barrières, volontairement redondantes : les DTO valident le format en
   * entrée, et cette fonction ré-encode à la sortie. Une seule des deux
   * suffirait aujourd'hui ; les deux garantissent qu'un nouvel appelant qui
   * oublierait la validation ne rouvre pas la faille.
   */
  private seg(value: string): string {
    return encodeURIComponent(value);
  }

  /**
   * Call the PUBLIC FleetOps API (`/v1`, middleware `fleetbase.api`) as
   * opposed to the internal one (`/int/v1`, middleware `fleetbase.protected`).
   *
   * Why this exists (verified 28/07/2026 by reading fleetbase/fleetops
   * server/src/routes.php and fleetbase/core-api CoreServiceProvider): the
   * driver-critical operations simply DO NOT EXIST on `int/v1`. Order activity
   * updates, start, proof capture, driver tracking and the online toggle are
   * only declared under the `v1` group. `int/v1` only carries bulk/dispatch
   * variants aimed at the console.
   *
   * Why the same Sanctum token still works, despite journal §2.2 concluding
   * the two auth schemes were separate: `fleetbase.api` maps to
   * `AuthenticateOnceWithBasicAuth`, whose name is misleading — it reads
   * `$request->bearerToken()` and tries `PersonalAccessToken::findToken()`
   * FIRST, falling back to an `ApiCredential` lookup on `key` only if that
   * misses. A Sanctum personal access token is therefore accepted on `v1`
   * exactly as it is on `int/v1`, and no second credential is needed.
   *
   * That corrects §2.2's "the flb_live_ key is nearly useless to us" framing:
   * the accurate statement is that BOTH credentials work on `v1`, while only
   * Sanctum works on `int/v1` — so a single Sanctum token covers everything.
   */
  async callFleetOpsPublic(method: string, path: string, data?: any, params?: any) {
    return this.apiClient({
      method,
      url: `/v1${path}`,
      data,
      params,
    });
  }

  /**
   * Call standard FleetOps API endpoint
   * Used for fleet operations (internal, with service account)
   */
  async callFleetOps(method: string, path: string, data?: any, params?: any) {
    return this.apiClient({
      method,
      url: `/int/v1${path}`,
      data,
      params,
    });
  }

  /**
   * Login to customer-portal for merchant
   */
  async merchantLogin(email: string, password: string) {
    try {
      const response = await this.callCustomerPortal('POST', '/auth/login', {
        email,
        password,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Merchant login failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Fleetbase Vendor for a merchant
   */
  /**
   * Crée un Vendor.
   *
   * ⚠️ `status` doit être transmis explicitement quand on ne veut PAS `active`.
   * Le modèle Fleetbase applique `$this->attributes['status'] = $status ?? 'active'`
   * — un vendor créé sans statut est donc **actif d'emblée**, ce qui rendrait
   * toute validation par un admin purement décorative.
   *
   * Le vocabulaire est celui de la console, et lui seul : `active`, `inactive`,
   * `suspended`. Le modèle accepte une chaîne libre, mais une valeur hors liste
   * s'afficherait vide dans le formulaire — un admin verrait un champ à
   * remplir sans savoir ce qu'il efface.
   */
  async createVendor(
    name: string,
    email: string,
    phone?: string,
    status?: 'active' | 'inactive' | 'suspended',
  ) {
    try {
      const response = await this.callFleetOps('POST', '/vendors', {
        name,
        email,
        phone,
        ...(status ? { status } : {}),
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Vendor creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Un Vendor par son uuid, ou `null`.
   *
   * ⚠️ **`GET /vendors/{uuid}` ignore son paramètre de chemin** et renvoie la
   * collection complète (journal §2.13, constaté par test réel). Contrairement
   * à `/drivers/{uuid}`, vérifié bon depuis. Cette méthode encaisse donc les
   * deux comportements : elle cherche l'uuid demandé dans ce qui revient, que
   * ce soit un objet unique ou une liste.
   *
   * L'uuid renvoyé est comparé au demandé dans les deux cas — sans quoi la
   * variante « liste » rendrait le premier vendor venu, et le statut d'un
   * commerçant serait lu sur celui de quelqu'un d'autre.
   */
  async getVendorByUuid(vendorUuid: string): Promise<any | null> {
    let data: any;
    try {
      data = (await this.callFleetOps('GET', `/vendors/${encodeURIComponent(vendorUuid)}`)).data;
    } catch (error: any) {
      if (error.response?.status === 404) return null;
      this.logger.error(`Lecture du vendor ${vendorUuid} échouée : ${error.message}`);
      throw error;
    }

    const single = data?.vendor ?? (data?.uuid ? data : null);
    if (single) return single.uuid === vendorUuid ? single : null;

    return (
      this.extractCollection(data, 'vendors').find((v: any) => v?.uuid === vendorUuid) ?? null
    );
  }

  /**
   * Supprime un Vendor. Utilisé en compensation quand une inscription
   * commerçant échoue après sa création.
   *
   * Best-effort par nature : si Fleetbase refuse la suppression, le Vendor
   * orphelin reste, mais l'inscription doit quand même signaler son échec à
   * l'appelant. L'appelant journalise, il ne relance pas.
   */
  async deleteVendor(vendorUuid: string) {
    const response = await this.callFleetOps('DELETE', `/vendors/${this.seg(vendorUuid)}`);
    return response.data;
  }

  /**
   * Attach a Contact as personnel of a Vendor, with type 'customer'.
   *
   * ⚠️ Fleetbase provisionne au passage un **User** lié (rôle « Fleet-Ops
   * Customer »), sauf si `create_login: false` est envoyé. Chaque inscription
   * commerçant crée donc un compte Fleetbase dont nous ne nous servons pas —
   * le module commerçant est passé au cache local et n'utilise plus
   * customer-portal-api. C'est une surface d'authentification gratuite (revue
   * archi #15).
   *
   * Non corrigé ici **délibérément** : l'inscription commerçant est un chemin
   * validé par test réel, et je ne peux pas éprouver l'effet de ce paramètre
   * dans ce bac à sable. Le passer à l'aveugle risquerait de casser un parcours
   * qui fonctionne. À traiter avec un test d'inscription sous la main.
   */
  async createCustomer(vendorUuid: string, email: string, firstName: string, lastName: string) {
    try {
      const response = await this.callFleetOps('POST', `/vendors/${this.seg(vendorUuid)}/personnels`, {
        email,
        name: `${firstName} ${lastName}`.trim(),
        type: 'customer',
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Customer creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Place (pickup/dropoff location) in Fleetbase.
   * Response shape: { place: { uuid, ... } }
   *
   * ⚠️ `contact` : le nom et le téléphone saisis par le commerçant étaient
   * **jetés** jusqu'au 29/07/2026 — la signature ne prenait que le nom et les
   * coordonnées. Le formulaire les demandait, les validait, les envoyait, et
   * ils s'arrêtaient au DTO. Le transporteur arrivait donc devant une adresse
   * sans savoir qui appeler, ce qui est précisément la situation que le
   * signalement « client absent » constate.
   *
   * Le téléphone va sur la colonne native `phone` ; le nom passe par `meta`,
   * le modèle `Place` n'ayant pas de champ dédié.
   */
  async createPlace(
    name: string,
    latitude: number,
    longitude: number,
    contact?: { name?: string; phone?: string; address?: string },
  ) {
    try {
      const response = await this.callFleetOps('POST', '/places', {
        name,
        location: {
          type: 'Point',
          coordinates: [longitude, latitude],
        },
        ...(contact?.address ? { address: contact.address } : {}),
        ...(contact?.phone ? { phone: contact.phone } : {}),
        ...(contact?.name ? { meta: { contact_name: contact.name } } : {}),
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Place creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a Place owned by a merchant's Vendor, used as a saved address-book
   * entry. Confirmed by direct testing that owner_uuid is a genuine filter
   * column on GET /places (querying by an owner_uuid with no owned Places
   * returns an empty list, not the full company-wide set) - this is what
   * makes per-merchant address scoping safe.
   */
  async createOwnedPlace(
    ownerUuid: string,
    data: { name: string; latitude: number; longitude: number; address?: string; phone?: string; meta?: Record<string, any> },
  ) {
    try {
      const response = await this.callFleetOps('POST', '/places', {
        name: data.name,
        location: {
          type: 'Point',
          coordinates: [data.longitude, data.latitude],
        },
        address: data.address,
        phone: data.phone,
        owner_uuid: ownerUuid,
        owner_type: 'fleet-ops:vendor',
        meta: data.meta,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Owned place creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Met à jour un lieu du carnet d'adresses.
   *
   * ⚠️ `owner_uuid` n'est **jamais** renvoyé dans la charge : le transmettre
   * permettrait, si un appelant oubliait le contrôle d'appartenance en amont,
   * de faire changer un lieu de propriétaire. L'appartenance se vérifie avant,
   * dans le service, contre la liste des lieux du commerçant.
   */
  async updateOwnedPlace(
    placeUuid: string,
    data: { name: string; latitude: number; longitude: number; address?: string; phone?: string; meta?: Record<string, any> },
  ) {
    const response = await this.callFleetOps('PUT', `/places/${this.seg(placeUuid)}`, {
      name: data.name,
      location: {
        type: 'Point',
        coordinates: [data.longitude, data.latitude],
      },
      address: data.address,
      phone: data.phone,
      meta: data.meta,
    });
    return response.data;
  }

  async deletePlace(placeUuid: string) {
    const response = await this.callFleetOps('DELETE', `/places/${this.seg(placeUuid)}`);
    return response.data;
  }

  /**
   * List Places owned by a given Vendor (a merchant's saved addresses).
   */
  async getOwnedPlaces(ownerUuid: string) {
    try {
      const response = await this.callFleetOps('GET', '/places', undefined, { owner_uuid: ownerUuid });
      return response.data;
    } catch (error) {
      this.logger.error(`Get owned places failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Resolve the default 'transport' OrderConfig UUID, required by order creation.
   */
  async getDefaultOrderConfigUuid(): Promise<string> {
    try {
      const response = await this.callFleetOps('GET', '/order-configs');
      const configs = response.data?.order_configs || [];
      const transportConfig = configs.find((c: any) => c.key === 'transport') || configs[0];
      if (!transportConfig) {
        throw new Error('No OrderConfig found in Fleetbase');
      }
      return transportConfig.uuid;
    } catch (error) {
      this.logger.error(`Get order configs failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a delivery Order. Fleetbase requires the entire payload nested
   * under a top-level 'order' key, with payload.pickup_uuid/dropoff_uuid
   * referencing pre-created Place records (or a payload.waypoints array).
   *
   * customer_uuid/customer_type (not a flat 'customer' string) are required:
   * confirmed by live test (28/07/2026) that OrderController's
   * normalizeCustomerType() only reads input['customer_uuid'] or
   * input['customer']['uuid'] - a flat string 'customer' value is silently
   * dropped and customer_uuid ends up null (see
   * docs/journal_implementation_bff.md §2.10). facilitator_uuid/
   * facilitator_type use the same direct-column pattern, confirmed working.
   */
  async createOrder(order: {
    order_config_uuid: string;
    customer_uuid: string;
    customer_type?: string;
    type?: string;
    payload: { pickup_uuid: string; dropoff_uuid: string };
    meta?: Record<string, any>;
    /** Livraison programmée (ISO 8601). Colonne native `scheduled_at`. */
    scheduled_at?: string;
    /** Assignation directe — utilisée pour un transporteur favori disponible. */
    driver_assigned_uuid?: string;
    /** Diffusion géospatiale aux transporteurs à proximité. */
    adhoc?: boolean;
    /** Rayon de diffusion en mètres. Colonne native `adhoc_distance`. */
    adhoc_distance?: number;
    /** Preuve exigée à la livraison. Colonnes natives. */
    pod_required?: boolean;
    pod_method?: string;
  }) {
    try {
      const response = await this.callFleetOps('POST', '/orders', { order });
      return response.data;
    } catch (error) {
      this.logger.error(`Order creation failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Get merchant's orders via customer-portal-api
   */
  async getMerchantOrders(token: string, page = 1, limit = 25) {
    try {
      const response = await this.callCustomerPortal('GET', '/orders', undefined, token, {
        page,
        limit,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Get merchant orders failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Commandes de la compagnie, filtrées côté serveur.
   *
   * ⚠️ Ne passer ici que des noms de `OrderFilters` — c'est-à-dire des filtres
   * **vérifiés par appel réel**. Un nom inventé serait abandonné en silence par
   * Fleetbase, et cette méthode renverrait toute la compagnie sans que rien ne
   * le signale : c'est très exactement ce qui s'est produit avec
   * `facilitator_uuid` et a coûté trois reconstructions
   * (`docs/architecture_bff_fleetbase.md` §4.3).
   */
  async getAllOrders(page = 1, limit = 100, filters: OrderFilters = {}) {
    try {
      const response = await this.callFleetOps('GET', '/orders', undefined, {
        page,
        limit,
        ...filters,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Get all orders failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Normalise the shapes Fleetbase wraps a collection in (journal §2.4):
   * sometimes a bare array, sometimes under `data`, sometimes under a
   * resource-named key. Never assume one — the same installation answers
   * differently depending on the endpoint.
   */
  extractCollection(response: any, ...resourceKeys: string[]): any[] {
    for (const key of [...resourceKeys, 'data']) {
      if (Array.isArray(response?.[key])) {
        return response[key];
      }
    }
    return Array.isArray(response) ? response : [];
  }

  /**
   * Every company order, across as many pages as it takes.
   *
   * `getAllOrders()` above returns ONE page, and its 100-item default silently
   * looks like "all of them" until the company crosses that count — after
   * which a caller scanning the result for a specific order stops finding
   * orders that exist and are legitimately assigned, and reports a 404. Since
   * every filter here is applied client-side (Fleetbase ignores the query
   * filters, see the note above), an incomplete fetch is an incorrect answer,
   * not merely a truncated list.
   *
   * The page cap is a runaway guard, not a limit anyone should hit; crossing
   * it is logged because past that point the results are wrong again.
   */
  async fetchEveryOrder(
    pageSize = 100,
    maxPages = 50,
    filters: OrderFilters = {},
  ): Promise<any[]> {
    const all: any[] = [];

    for (let page = 1; page <= maxPages; page++) {
      const orders = this.extractCollection(
        await this.getAllOrders(page, pageSize, filters),
        'orders',
      );

      if (orders.length === 0) {
        break;
      }

      all.push(...orders);

      if (orders.length < pageSize) {
        break;
      }

      if (page === maxPages) {
        this.logger.warn(
          `fetchEveryOrder a atteint le garde-fou de ${maxPages} pages — la liste est tronquée, ` +
            'les recherches par identifiant peuvent renvoyer un 404 à tort',
        );
      }
    }

    return all;
  }

  /**
   * Get a single order by uuid. Confirmed working (used for tracking, see
   * commercant.service.ts getOrderTracking).
   */
  async getOrder(orderUuid: string) {
    try {
      const response = await this.callFleetOps('GET', `/orders/${this.seg(orderUuid)}`);
      return response.data;
    } catch (error) {
      this.logger.error(`Get order failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Cancel an order. Note: no {id} in the path - the order UUID goes in
   * the request body as 'order', per OrderController::cancel().
   */
  async cancelOrder(orderUuid: string) {
    try {
      const response = await this.callFleetOps('PATCH', '/orders/cancel', { order: orderUuid });
      return response.data;
    } catch (error) {
      this.logger.error(`Cancel order failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Assign an order to a driver. Confirmed shape by reading
   * DriverController::assignOrder() - route is `/drivers/{id}/assign-order`,
   * body key is `order` (not `order_id`/`orderId`).
   */
  async assignOrderToDriver(driverUuid: string, orderUuid: string) {
    try {
      const response = await this.callFleetOps('POST', `/drivers/${driverUuid}/assign-order`, {
        order: orderUuid,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Assign order to driver failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Détache le transporteur d'une commande et la remet en diffusion.
   *
   * Utilisé quand un transporteur refuse une course qui lui avait été assignée
   * — typiquement un favori sollicité en premier. Les deux écritures vont
   * ensemble et ne se séparent pas : détacher sans rediffuser laisserait la
   * commande en suspens, sans transporteur ni personne à qui la proposer, ce
   * qui est un état pire que celui dont on part.
   *
   * `driver_assigned_uuid`, `adhoc` et `adhoc_distance` sont tous trois dans le
   * `$fillable` du modèle `Order` (vérifié dans le source fleetops), et
   * l'enveloppe `{ order: ... }` reprend celle de la création — même
   * contrôleur, même lecture par `$request->input('order')`.
   *
   * ⚠️ **Non validé par un appel réel** : aucune instance Fleetbase n'est
   * joignable depuis ce bac à sable. La forme repose sur l'analogie avec la
   * création, qui a tenu jusqu'ici (journal §5.6), mais l'analogie n'est pas une
   * preuve. À éprouver au premier refus d'une course assignée.
   */
  async releaseOrderToPool(orderUuid: string, adhocDistance: number) {
    const response = await this.callFleetOps('PUT', `/orders/${this.seg(orderUuid)}`, {
      order: {
        driver_assigned_uuid: null,
        adhoc: true,
        adhoc_distance: adhocDistance,
      },
    });
    return response.data;
  }

  /**
   * Conducteurs de la compagnie, filtrés côté serveur.
   *
   * ⚠️ **`phone` est absent de `DriverFilters`, et ce n'est pas un oubli** :
   * `DriverFilter::phone()` fait un `whereHas('phone', …)` alors que `phone` est
   * un attribut calculé et non une relation sur `Driver` — Laravel lève, la
   * réponse est un **500**, confirmé par appel réel le 29/07/2026. `query`
   * couvre le téléphone en passant par la relation `user`, c'est-à-dire ce que
   * `phone()` aurait dû faire.
   *
   * ⚠️ **Sans `limit`, cette route pagine au défaut de Fleetbase.** Un appel
   * sans filtre ne voit donc pas tous les conducteurs — panne silencieuse de la
   * même famille que le plafond de 100 sur les commandes. Filtrer, ou
   * paginer explicitement.
   *
   * Détail : `docs/architecture_bff_fleetbase.md` §5.
   */
  /**
   * Un conducteur par son uuid, ou `null` s'il n'existe pas.
   *
   * ── Pourquoi cette méthode a mis deux tours à arriver ─────────────────────
   *
   * `DriverFilter` n'expose aucun filtre par uuid, donc retrouver le `Driver`
   * derrière un compte Echango passait par un parcours de toute la liste — et
   * ce parcours s'arrêtait à la première page, laissant « inconnu » un
   * transporteur pourtant provisionné (journal §21.8, §22).
   *
   * La lecture unitaire était le remède évident, et elle a été écartée un
   * temps : §2.13 a montré que `GET /vendors/{uuid}` **ignore son paramètre de
   * chemin** et renvoie la collection. Le même défaut ici ne lèverait aucune
   * erreur — il rattacherait un compte au **mauvais** transporteur. Vérifié
   * depuis (V9, en demandant délibérément le *dernier* conducteur de la liste :
   * un endpoint qui ignore le chemin se trahit en renvoyant le premier).
   *
   * ── La garde qui rend cette méthode sûre quoi qu'il arrive ────────────────
   *
   * L'uuid renvoyé est comparé à celui demandé. Cette ligne coûte deux
   * comparaisons et couvre **tout** : une enveloppe de réponse différente de ce
   * qu'on croit, une régression amont sur la résolution du chemin, un endpoint
   * qui se remettrait à renvoyer la liste. Le pire cas devient « non trouvé »,
   * jamais « quelqu'un d'autre ».
   */
  async getDriverByUuid(driverUuid: string): Promise<any | null> {
    let data: any;
    try {
      data = (await this.callFleetOps('GET', `/drivers/${encodeURIComponent(driverUuid)}`)).data;
    } catch (error: any) {
      if (error.response?.status === 404) return null;
      // Toute autre erreur remonte : la confondre avec une absence ferait dire
      // « ce transporteur n'existe pas » à une panne réseau.
      this.logger.error(`Lecture du conducteur ${driverUuid} échouée : ${error.message}`);
      throw error;
    }

    // Les trois enveloppes que Fleetbase emploie selon l'endpoint (§2.4).
    const candidate =
      data?.driver ?? (data?.uuid ? data : this.extractCollection(data, 'drivers')[0]);

    return candidate?.uuid === driverUuid ? candidate : null;
  }

  async getAllDrivers(filters: DriverFilters = {}) {
    try {
      const response = await this.callFleetOps('GET', '/drivers', undefined, filters);
      return response.data;
    } catch (error) {
      this.logger.error(`Get all drivers failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create a new Driver record in Fleetbase.
   * Confirmed by live test (28/07/2026) that a flat payload crashes
   * DriverController::createRecord() with the exact same PHP TypeError as
   * flat order payloads crashed OrderController (see
   * docs/journal_implementation_bff.md §2.5): `Validator::make($request->
   * input(...), $rules)` receives `null`. Wrapping under a `driver` key
   * (mirroring the `order` envelope for /orders) is the fix by analogy -
   * NOT yet independently confirmed to be the correct key name; re-test
   * and, if it still 400s, check `DriverController.php` line 67 directly.
   */
  async createDriver(data: { name: string; email?: string; phone?: string }) {
    try {
      const response = await this.callFleetOps('POST', '/drivers', { driver: data });
      return response.data;
    } catch (error) {
      this.logger.error(`Create driver failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Attach a Driver to a Vendor's fleet. Confirmed shape by reading
   * VendorController::assignDriver() - route is `/vendors/{id}/assign-driver`,
   * body key is `driver`; this sets the Driver's `vendor_uuid`.
   */
  async assignDriverToVendor(vendorUuid: string, driverUuid: string) {
    try {
      const response = await this.callFleetOps('POST', `/vendors/${vendorUuid}/assign-driver`, {
        driver: driverUuid,
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Assign driver to vendor failed: ${error.message}`);
      throw error;
    }
  }

  /**
   * Create or update a push-notification device record for a Fleetbase user.
   *
   * IMPORTANT, discovered 28/07/2026 while implementing driver auth (reading
   * the public fleetbase/fleetops and fleetbase/core-api source, no local
   * Fleetbase instance was available to test against in this sandbox): the
   * `Driver` model has NO fcm/apn token column at all. `Driver::
   * routeNotificationForFcm()`/`routeNotificationForApn()` (used by the
   * OrderPing notification, docs/specs_echango_delivery.md §3.2) instead read
   * a `devices()` HasMany relation to `UserDevice`, joined on `user_uuid` (not
   * `driver_uuid`) - a separate core-api model/table entirely. This
   * contradicts the assumption in docs/specs_app_transporteur.md §2.1/§11.1
   * that the BFF "writes the push token onto the Driver record" - it must
   * instead write a UserDevice keyed by the Driver's `user_uuid`.
   *
   * Route confirmed by reading core-api's routes.php: `$router->
   * fleetbaseRoutes('user-devices')`, the same macro used by `/vendors` and
   * `/places` (both take a flat, non-enveloped payload) rather than the
   * custom `/orders`/`/drivers` controllers (which require an enveloped
   * payload, see docs/journal_implementation_bff.md §2.5/§2.12) - a flat
   * payload is used here by that analogy.
   *
   * VALIDATED end-to-end 28/07/2026 via scripts/test-driver-auth.sh against a
   * live local Fleetbase: the flat payload and the response key both work, and
   * the returned UserDevice uuid is persisted. The analogy above held.
   *
   * Still unconfirmed: whether repeat calls with the same token upsert or
   * append a row on the Fleetbase side. It matters in practice - Firebase
   * hands back the same token on every app start, so this route gets called
   * repeatedly, and duplicate rows would mean duplicate pushes.
   */
  async upsertDriverDeviceToken(userUuid: string, token: string, platform: string) {
    try {
      const response = await this.callFleetOps('POST', '/user-devices', {
        user_uuid: userUuid,
        token,
        platform,
        status: 'active',
      });
      return response.data;
    } catch (error) {
      this.logger.error(`Upsert driver device token failed: ${error.message}`);
      throw error;
    }
  }

  // ── Opérations driver (API publique v1) ────────────────────────────────
  // Formes de payload lues dans fleetops server/src/Http/Controllers/Api/v1/
  // {Order,Driver}Controller.php le 28/07/2026, pas supposées.
  //
  // ⚠️ TOUTES ces routes s'adressent par **public_id** (`driver_xxx`,
  // `order_xxx`), jamais par uuid — `findRecordOrFail()` (core-api,
  // HasApiModelBehavior) matche `public_id`/`internal_id` et rien d'autre.
  // Passer un uuid donne un 404 « resource not found » parfaitement
  // trompeur, puisque l'enregistrement existe. Vérifié par test réel le
  // 28/07/2026 (journal §6.7). Les paramètres sont nommés en conséquence.

  /**
   * Push a GPS fix. `track()` accepts latitude/longitude plus optional
   * altitude/heading/speed, and resolves {id} through findRecordOrFail, which
   * takes either a public_id or a uuid.
   */
  async trackDriver(
    driverPublicId: string,
    position: { latitude: number; longitude: number; altitude?: number; heading?: number; speed?: number },
  ) {
    const response = await this.callFleetOpsPublic('POST', `/drivers/${this.seg(driverPublicId)}/track`, position);
    return response.data;
  }

  /**
   * Flip driver availability. Passing `online` sets it explicitly; omitting it
   * makes Fleetbase toggle whatever is current — we always pass it, since a
   * blind toggle would desync if a request were retried.
   */
  async toggleDriverOnline(driverPublicId: string, online: boolean) {
    const response = await this.callFleetOpsPublic('POST', `/drivers/${this.seg(driverPublicId)}/toggle-online`, { online });
    return response.data;
  }

  /**
   * Récupère un fichier stocké par Fleetbase, à partir de l'URL qu'il a émise.
   *
   * ⚠️ **Seul le chemin de l'URL est conservé**, et il est résolu contre
   * `FLEETBASE_API_URL`. Deux raisons, l'une pratique et l'autre de sécurité :
   *
   * - Fleetbase construit ses URL depuis son propre `APP_URL`, qui vaut
   *   `localhost:8000` en développement. Cet hôte ne désigne ni le conteneur
   *   BFF ni le téléphone — il n'est joignable depuis nulle part sauf la
   *   machine Fleetbase elle-même.
   * - Une URL absolue lue en base et suivie telle quelle est une porte de
   *   sortie : quiconque parviendrait à y écrire ferait émettre au BFF, avec
   *   ses accès réseau, une requête vers l'hôte de son choix.
   */
  async fetchStoredFile(fileUrl: string): Promise<{ data: Buffer; contentType: string }> {
    let path: string;
    try {
      const parsed = new URL(fileUrl);
      path = parsed.pathname + parsed.search;
    } catch {
      // Chemin relatif déjà stocké : l'accepter tel quel, sans le rendre
      // absolu ailleurs que sur Fleetbase.
      path = fileUrl.startsWith('/') ? fileUrl : `/${fileUrl}`;
    }

    const response = await this.apiClient({
      method: 'GET',
      url: path,
      responseType: 'arraybuffer',
    });

    return {
      data: Buffer.from(response.data),
      contentType: String(response.headers['content-type'] || 'application/octet-stream'),
    };
  }

  /**
   * Fiche complète d'un driver, par son public_id.
   *
   * Pourquoi pas la liste : la ressource Fleetbase expose
   * `'online' => data_get($this, 'online', false)`, donc elle renvoie `false`
   * aussi bien pour « hors ligne » que pour « attribut non chargé ». Un
   * `false` lu dans une collection ne distingue pas les deux, et se lit à tort
   * comme une disponibilité. Une fiche unique hydrate l'enregistrement.
   *
   * `v1` et non `int/v1` : le GET par identifiant de `int/v1` ignore le
   * paramètre de chemin et renvoie toute la collection (journal §2.13).
   */
  async getDriverByPublicId(driverPublicId: string) {
    const response = await this.callFleetOpsPublic('GET', `/drivers/${this.seg(driverPublicId)}`);
    return response.data;
  }

  /**
   * Start an order. `assign` is how an adhoc order gets claimed — and it is
   * validated as a **public_id** (the controller requires the `driver_`
   * prefix), NOT the uuid used everywhere else. Hence DriverAccount stores
   * both identifiers.
   */
  async startOrder(orderPublicId: string, assignDriverPublicId?: string) {
    const body = assignDriverPublicId ? { assign: assignDriverPublicId } : {};
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/start`, body);
    return response.data;
  }

  /**
   * The activities the order can legally transition to right now.
   *
   * Needed because the order detail carries no activity data at all — verified
   * 28/07/2026 on a live order: it exposes `order_config_uuid` but neither the
   * flow nor the current step (journal §6.9). This route resolves the flow
   * against the order's current state and returns ready-to-use Activity
   * objects, so neither the BFF nor the app has to reimplement the state
   * machine.
   *
   * Each entry carries at least: code, status, details, complete, and
   * require_pod/pod_method when the step demands proof — which is also how the
   * app knows to route to the POD screen (specs_app_transporteur.md §5).
   *
   * `waypoint` selects a specific stop on a multi-stop order.
   */
  async getNextActivities(orderPublicId: string, waypoint?: string) {
    const response = await this.callFleetOpsPublic(
      'GET',
      `/orders/${this.seg(orderPublicId)}/next-activity`,
      undefined,
      waypoint ? { waypoint } : undefined,
    );
    return response.data;
  }

  /**
   * Advance the order through its state machine. `activity` must be a full
   * Activity object as returned by getNextActivities() — not a status string.
   */
  async updateOrderActivity(orderPublicId: string, activity: any, proof?: string) {
    const body: any = { activity };
    if (proof) body.proof = proof;
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/update-activity`, body);
    return response.data;
  }

  /**
   * Attach photo proof. The controller accepts `photos` as multipart uploads
   * OR as an array of base64 strings — we use base64, which keeps the BFF a
   * plain JSON service with no multipart handling.
   */
  async captureOrderPhoto(orderPublicId: string, photos: string[], remarks?: string, subjectId?: string) {
    const path = subjectId
      ? `/orders/${this.seg(orderPublicId)}/capture-photo/${this.seg(subjectId)}`
      : `/orders/${this.seg(orderPublicId)}/capture-photo`;

    // ── Contournement d'un bug amont Fleetbase ──────────────────────────
    // capturePhoto() résout le bucket ainsi :
    //
    //   $bucket = $request->input("filesystems.disks.{$disk}.bucket",
    //                             config('filesystems.disks.s3.bucket'));
    //
    // La première ligne devrait être `config(...)` : elle lit une clé de la
    // REQUÊTE, jamais présente, donc le repli S3 s'applique toujours — et vaut
    // null sans S3 configuré. `storeProofPhoto()` typant ce paramètre `string`,
    // l'appel meurt en TypeError 500. Tout upload de preuve est donc cassé sur
    // une installation non-S3, quel que soit l'appelant (constaté en réel le
    // 28/07/2026, journal §6.12).
    //
    // Le bug est aussi son propre remède : la valeur venant de la requête, on
    // l'y place. Le disque et le bucket restent surchargeables par
    // environnement pour un déploiement S3 réel.
    // Le bucket doit être NON VIDE : `ConvertEmptyStringsToNull` est dans la
    // pile Laravel, donc une chaîne vide arrive à `null` au contrôleur et
    // reproduit exactement le TypeError qu'on cherche à éviter (constaté au
    // 2e essai, 28/07). Le disque `local` ignore la valeur de toute façon.
    // Disque `public` et non `local` : la racine de `local` est
    // `storage/app`, qu'aucun serveur web ne sert. Fleetbase construit
    // pourtant une URL `/storage/...`, qui suppose le disque public et son
    // lien symbolique vers `public/storage`. Avec `local`, le fichier était
    // donc bien écrit — et introuvable par HTTP, avec le 404 masqué
    // « There is nothing to see here » (constaté en réel le 28/07/2026).
    //
    // ⚠️ Prérequis côté Fleetbase : `php artisan storage:link`. Sans ce lien,
    // le disque public écrit correctement mais reste tout aussi inaccessible.
    const disk = process.env.FLEETBASE_PROOF_DISK || 'public';
    const bucket = process.env.FLEETBASE_PROOF_BUCKET || 'fleetbase';

    const body: any = {
      photos,
      disk,
      filesystems: { disks: { [disk]: { bucket } } },
    };
    if (remarks) body.remarks = remarks;

    const response = await this.callFleetOpsPublic('POST', path, body);
    return response.data;
  }

  /**
   * Mark an order complete. Distinct from updateActivity: this is the
   * dedicated terminal transition, and it is what the app's "delivered"
   * button maps to.
   */
  async completeOrder(orderPublicId: string) {
    const response = await this.callFleetOpsPublic('POST', `/orders/${this.seg(orderPublicId)}/complete`, {});
    return response.data;
  }

  async getOrderPublic(orderPublicId: string) {
    const response = await this.callFleetOpsPublic('GET', `/orders/${this.seg(orderPublicId)}`);
    return response.data;
  }

  /**
   * Delete a UserDevice, used to retire a push token the driver no longer has.
   *
   * Firebase rotates tokens (reinstall, cleared app data, restored backup) and
   * nothing removes the old record on its own, while
   * Driver::routeNotificationForFcm() returns EVERY device on the user_uuid.
   * Left alone, Fleetbase keeps pushing to dead tokens forever — a failure
   * that produces no error anywhere, just notifications that never arrive.
   *
   * DELETE /{resource}/{id} confirmed as part of what the fleetbaseRoutes()
   * macro generates (core-api RESTRegistrar).
   */
  async deleteUserDevice(userDeviceId: string) {
    const response = await this.callFleetOps('DELETE', `/user-devices/${this.seg(userDeviceId)}`);
    return response.data;
  }

  /**
   * Find a UserDevice by its push token, returning the record so callers can
   * pick whichever identifier the route they need actually resolves.
   *
   * Exists because the mirror only captured a uuid, and record resolution in
   * Fleetbase is not uniform: §6.7 established that `findRecordOrFail()`
   * matches public_id and never uuid. Rather than assume which one DELETE
   * accepts, look the device up and try the public_id first.
   */
  async findUserDeviceByToken(token: string) {
    try {
      const response = await this.callFleetOps('GET', '/user-devices');
      const devices =
        response.data?.user_devices || response.data?.data ||
        (Array.isArray(response.data) ? response.data : []);
      return (devices || []).find((d: any) => d?.token === token) || null;
    } catch (error) {
      this.logger.warn(`UserDevice lookup by token failed: ${error.message}`);
      return null;
    }
  }

  /**
   * List ALL company Position records, unfiltered. Confirmed by reading
   * PositionFilter.php (28/07/2026) that there is no `driver_uuid` (or any
   * per-driver) query filter on this endpoint - it only supports a free-text
   * `query` search, `createdAt`, and automatic company-wide scoping. `GET
   * /int/v1/driver-positions` (previously assumed here) does not exist at
   * all - confirmed 404 ("There is nothing to see here", the masked
   * NotFoundHttpException pattern from docs/journal_implementation_bff.md
   * §2.1). The real resource is the generic `/int/v1/positions` endpoint.
   * Callers MUST filter the result client-side by `driver_uuid`.
   *
   * ⚠️ Plus utilisé par la carte de flotte : télécharger tout l'historique de
   * la compagnie pour n'afficher qu'un point par driver ne tenait pas à
   * l'échelle. `FlotteService.getDriverPositions()` sert désormais le miroir
   * local alimenté par `POST /transporteur/position`. Cette méthode reste pour
   * un besoin d'historique — ne pas la rebrancher sur la carte.
   */
  async getAllPositions() {
    try {
      const response = await this.callFleetOps('GET', '/positions');
      return response.data;
    } catch (error) {
      this.logger.error(`Get all positions failed: ${error.message}`);
      throw error;
    }
  }
}
