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
  /**
   * Non assignées **et** non terminées : `whereDoesntHave` + exclusion de
   * completed/canceled/expired.
   *
   * ⚠️ Typé `true`, jamais `boolean`. C'est un filtre **à présence**, pas un
   * booléen : mesuré le 01/08/2026, `?without_driver=true` rend 53 commandes et
   * `?without_driver=false` en rend **178**, c'est-à-dire la totalité. Un
   * `false` n'exclut donc pas, **il élargit**.
   *
   * Le type `boolean` invitait à écrire `{ without_driver: uneVariable }` — et
   * ce jour-là la requête serait passée de « les courses libres » à « toutes
   * les courses de la compagnie », sans erreur. C'est exactement le mode de
   * panne que ces interfaces fermées existent pour empêcher (`facilitator_uuid`),
   * reproduit à l'intérieur d'un nom pourtant valide.
   */
  without_driver?: true;
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

/**
 * Alias de morphologie polymorphe d'un `Vendor` chez Fleetbase.
 *
 * **Mesuré, pas déduit** : `scripts/verify-facilitator.sh` (31/07/2026) montre
 * que `facilitator_type` est stocké `fleet-ops:vendor`. La valeur `vendor` est
 * acceptée et normalisée, mais on écrit ce que le serveur stocke.
 */
export const FACILITATOR_TYPE_VENDOR = 'fleet-ops:vendor';

@Injectable()
export class FleetbaseApiClient {
  private readonly logger = new Logger(FleetbaseApiClient.name);
  private readonly apiClient: AxiosInstance;

  /** Base Fleetbase, mémorisée pour la sonde `ping()` de /health. */
  private readonly baseURL: string;

  constructor() {
    this.baseURL = process.env.FLEETBASE_API_URL || 'http://localhost:8000';
    const apiKey = process.env.FLEETBASE_API_KEY;

    this.apiClient = axios.create({
      baseURL: this.baseURL,
      headers: {
        'Authorization': `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000,
    });

    // ── LE point où une erreur Fleetbase est journalisée ────────────────────
    //
    // ⚠️ **Ne rajoutez pas de `try/catch` pour journaliser dans les méthodes.**
    // Dix-huit d'entre elles le faisaient, et c'était une pure duplication :
    // l'erreur passait déjà ici, donc chaque échec produisait **deux lignes** —
    // celle-ci, qui porte le statut, la méthode, l'URL et la charge utile
    // renvoyée, et une seconde écrite à la main qui ne portait que
    // `error.message`. La moins informative des deux masquait l'autre dans le
    // journal, et les six lignes de plomberie par méthode donnaient à croire
    // que les vingt-cinq méthodes SANS `try/catch` ne journalisaient rien —
    // alors qu'elles passent par ici comme les autres.
    //
    // Un `catch` dans une méthode ne se justifie donc que s'il fait autre chose
    // que journaliser : rendre `null` sur un 404, réessayer, replier. Les cinq
    // qui subsistent sont exactement dans ce cas.
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
   * Fleetbase répond-il ? Sonde pour `/health`, qui la RAPPORTE sans échouer.
   *
   * ── Pourquoi elle ne passe pas par `this.apiClient` ──────────────────────────
   *
   * Un axios NU, hors intercepteur, et pour deux raisons : `validateStatus` laisse
   * passer n'importe quel statut — un `401` ou un `404` prouve que Fleetbase
   * **répond**, ce qui est toute la question ; et l'intercepteur du client
   * journalise chaque erreur en `error`, or ici un amont à terre est un état
   * qu'on mesure, pas un incident à crier à chaque `/health`. Timeout court
   * (2,5 s) : la sonde ne doit pas hériter des 30 s du client, sinon `/health`
   * traînerait autant qu'un vrai appel quand Fleetbase est lent.
   *
   * Ne lève jamais : une panne de la dépendance est un `reachable: false`, pas
   * une exception qui ferait échouer la sonde (`docs/status_v1.md`, « /health ne
   * peut pas échouer » — la bonne forme est de rapporter l'état, pas de tomber).
   */
  async ping(timeoutMs = 2500): Promise<{ reachable: boolean; latency_ms: number | null }> {
    const start = Date.now();
    try {
      await axios.get(this.baseURL, { timeout: timeoutMs, validateStatus: () => true });
      return { reachable: true, latency_ms: Date.now() - start };
    } catch {
      return { reachable: false, latency_ms: null };
    }
  }

  // ⚠️ `callCustomerPortal()` a été SUPPRIMÉ le 03/08/2026 — jamais appelé.
  //
  // Vestige de l'époque où le module commerçant passait par
  // `customer-portal-api` ; il est passé au cache local et à l'API interne
  // depuis. Une méthode qui construit une URL vers un chemin qu'on n'emprunte
  // plus laisse croire que ce chemin est encore une option.



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
    const response = await this.callFleetOps('POST', '/vendors', {
      name,
      email,
      phone,
      ...(status ? { status } : {}),
    });
    return response.data;
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
      throw error;
    }

    const single = data?.vendor ?? (data?.uuid ? data : null);
    if (single) return single.uuid === vendorUuid ? single : null;

    // ── Le repli sur collection doit paginer, sinon le garde s'éteint tout seul
    //
    // La variante « liste » de cet endpoint renvoie une **page**, pas la
    // totalité. Chercher l'uuid dans cette seule page marche tant que le réseau
    // est petit, puis cesse de marcher sans rien signaler : la méthode rend
    // `null`, et `assertVendorApproved()` a décidé qu'un vendor introuvable
    // **laisse passer** (à raison — un vendor supprimé à la main ne doit pas
    // priver quelqu'un de son compte). Le garde de validation se désactiverait
    // donc de lui-même à mesure que des commerçants et des entreprises
    // s'inscrivent, ce qui est exactement le mode de panne qu'on ne remarque
    // jamais : rien n'échoue, tout devient permissif.
    //
    // Même famille que les plafonds silencieux des §21.5/§22 — le premier
    // lecteur voyait ses données, donc personne ne cherchait plus loin.
    const first = this.extractCollection(data, 'vendors');
    const found = first.find((v: any) => v?.uuid === vendorUuid);
    if (found || first.length === 0) return found ?? null;

    this.logger.warn(
      `GET /vendors/${vendorUuid} a rendu une COLLECTION sans le fournisseur demandé — ` +
        'le tampon de compatibilité sert, contrairement à ce qui a été mesuré sur 0.7.52',
    );
    return this.findVendorAcrossPages(vendorUuid);
  }

  /**
   * Parcourt les pages de `/vendors` à la recherche d'un uuid.
   *
   * Appelé seulement quand la première réponse était une **collection** ne le
   * contenant pas.
   *
   * ⚠️ **Mesuré le 01/08/2026 : ce chemin ne sert plus.** Sur Fleetbase 0.7.52,
   * `GET /int/v1/vendors/{uuid}` honore bien son paramètre — vérifié avec le
   * test durci « demander le DERNIER élément, pas le premier », sans quoi un
   * endpoint qui ignore son paramètre passerait au vert (la leçon de V9).
   *
   * Il est **conservé quand même** : c'est un tampon de compatibilité, et le
   * retirer ferait échouer toute lecture de fournisseur sur une installation où
   * l'ancien comportement existe — donc empêcher des commerçants de se
   * connecter, pour supprimer soixante lignes.
   *
   * Ce qui change, c'est qu'il **le dit** quand il sert. Un tampon silencieux
   * dont on croit qu'il ne sert jamais est indiscernable d'un tampon qui sert
   * tous les jours (règle 9) : le jour où la mesure ci-dessus cesse d'être
   * vraie, on veut le lire dans un journal, pas le redécouvrir.
   */
  private async findVendorAcrossPages(
    vendorUuid: string,
    pageSize = 200,
    maxPages = 25,
  ): Promise<any | null> {
    // ⚠️ La condition d'arrêt ne suppose PAS que `limit` est honoré.
    //
    // Écrire `if (vendors.length < pageSize) return null` paraît naturel et
    // rendrait ce correctif **entièrement inerte** si le serveur plafonne
    // `limit` en dessous de la valeur demandée : la première page renverrait
    // moins que `pageSize`, on sortirait aussitôt, et le garde resterait aussi
    // auto-désarmant qu'avant — avec cinquante lignes de commentaire expliquant
    // qu'il ne l'est plus. C'est la leçon fondatrice du projet : Fleetbase
    // **abandonne un paramètre inconnu sans erreur**, donc aucune supposition
    // sur un paramètre de requête ne se vérifie toute seule.
    //
    // On s'arrête donc sur une page **vide**, et on détecte séparément le cas
    // où `page` serait ignoré — sans quoi on relirait la même page vingt-cinq
    // fois avant de conclure « introuvable », c'est-à-dire « laisse passer ».
    let previousFirstUuid: string | null = null;

    for (let page = 1; page <= maxPages; page++) {
      let vendors: any[];
      try {
        const response = await this.callFleetOps('GET', '/vendors', undefined, {
          page,
          limit: pageSize,
        });
        vendors = this.extractCollection(response.data, 'vendors');
      } catch (error: any) {
        this.logger.error(`Parcours des vendors échoué (page ${page}) : ${error.message}`);
        throw error;
      }

      const found = vendors.find((v: any) => v?.uuid === vendorUuid);
      if (found) return found;

      if (vendors.length === 0) return null;

      const firstUuid = vendors[0]?.uuid ?? null;
      if (page > 1 && firstUuid !== null && firstUuid === previousFirstUuid) {
        this.logger.warn(
          `/vendors semble ignorer le paramètre « page » (page ${page} identique à la ` +
            `précédente) — recherche de ${vendorUuid} abandonnée, le statut renvoyé ne fait pas foi`,
        );
        return null;
      }
      previousFirstUuid = firstUuid;

      if (page === maxPages) {
        // Ne pas rendre `null` en silence : au-delà du garde-fou, « introuvable »
        // ne veut plus dire « n'existe pas », et l'appelant en tire une décision
        // d'accès.
        this.logger.warn(
          `Vendor ${vendorUuid} non trouvé après ${maxPages} pages — la recherche est tronquée, ` +
            'le statut renvoyé ne fait pas foi',
        );
      }
    }

    return null;
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
    const response = await this.callFleetOps('POST', `/vendors/${this.seg(vendorUuid)}/personnels`, {
      email,
      name: `${firstName} ${lastName}`.trim(),
      type: 'customer',
    });
    return response.data;
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
   *
   * ⚠️ **L'adresse s'écrit dans `street1`, jamais dans `address`** — voir la
   * note de `PLACE_ADDRESS_COLUMN` ci-dessous.
   */
  async createPlace(
    name: string,
    latitude: number,
    longitude: number,
    contact?: {
      name?: string;
      phone?: string;
      address?: string;
      /**
       * Commune et quartier issus du géocodage inverse.
       *
       * ⚠️ **Le lieu n'avait, jusqu'au 31/07/2026, que son nom et un point.**
       * Aucune colonne d'adresse structurée n'était renseignée, alors que
       * l'application les avait sous la main. Sur une course non réclamée,
       * `projectPlace(…, 'anonymous')` recompose l'adresse à partir de ces
       * colonnes-là uniquement : il n'y en avait aucune, donc l'entreprise
       * lisait un identifiant technique en titre de ligne.
       */
      city?: string;
      neighborhood?: string;
      /**
       * Wilaya, ajoutée le 02/08/2026.
       *
       * ⚠️ Le lieu d'une **course** ne la recevait pas, alors que le lieu du
       * **carnet d'adresses** l'écrivait déjà (`addressComponents`). Les deux
       * chemins créent pourtant le même objet `Place`, et la projection sert
       * `province` au transporteur depuis le 31/07 : elle arrivait donc
       * toujours vide sur une course. C'est la règle 5 dans sa forme la plus
       * banale — deux chemins vers un même enregistrement, un seul tenu à
       * jour.
       */
      province?: string;
    },
  ) {
    const response = await this.callFleetOps('POST', '/places', {
      name,
      location: {
        type: 'Point',
        coordinates: [longitude, latitude],
      },
      ...(contact?.address ? { street1: contact.address } : {}),
      ...(contact?.city ? { city: contact.city } : {}),
      ...(contact?.province ? { province: contact.province } : {}),
      ...(contact?.neighborhood ? { neighborhood: contact.neighborhood } : {}),
      ...(contact?.phone ? { phone: contact.phone } : {}),
      ...(contact?.name ? { meta: { contact_name: contact.name } } : {}),
    });
    return response.data;
  }

  /**
   * Corrige le point d'un `Place` déjà créé (PUT `/places/:uuid`).
   *
   * Sert à `docs/specs_localisation_client_et_optimisation_parcours.md` §1.6 :
   * une fiche client mise à jour après coup doit pouvoir corriger le point de
   * dépose d'une commande déjà créée. `dropoff_uuid`/`pickup_uuid` référencent
   * un `Place` séparé (voir `createOrder` ci-dessous) — il n'y a donc aucun
   * champ `payload` à écrire sur l'ordre lui-même, seulement ce `Place`.
   */
  async updatePlace(placeUuid: string, latitude: number, longitude: number) {
    const response = await this.callFleetOps('PUT', `/places/${this.seg(placeUuid)}`, {
      location: {
        type: 'Point',
        coordinates: [longitude, latitude],
      },
    });
    return response.data;
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
    data: {
      name: string;
      latitude: number;
      longitude: number;
      street1?: string;
      neighborhood?: string;
      city?: string;
      district?: string;
      province?: string;
      postal_code?: string;
      /** Code ISO-2 : la colonne stocke un code, pas un nom. */
      country?: string;
      phone?: string;
      meta?: Record<string, any>;
    },
  ) {
    const response = await this.callFleetOps('POST', '/places', {
      name: data.name,
      location: {
        type: 'Point',
        coordinates: [data.longitude, data.latitude],
      },
      street1: data.street1,
      neighborhood: data.neighborhood,
      city: data.city,
      district: data.district,
      province: data.province,
      postal_code: data.postal_code,
      country: data.country,
      phone: data.phone,
      owner_uuid: ownerUuid,
      owner_type: 'fleet-ops:vendor',
      meta: data.meta,
    });
    return response.data;
  }

  /**
   * Met à jour un lieu du carnet d'adresses.
   *
   * ⚠️ **Correction du 30/07/2026, par test réel** : `owner_uuid` était
   * délibérément omis (voir l'historique git), au motif qu'un appelant qui
   * oublierait le contrôle d'appartenance en amont ne devait pas pouvoir
   * changer un lieu de propriétaire en le transmettant. Le raisonnement
   * sécurité tenait, mais supposait à tort que `PUT /places/{uuid}` **fusionne**
   * la charge avec l'existant. Un commerçant a modifié une adresse et l'a vue
   * disparaître du carnet ensuite — même famille de piège que `meta`
   * (`docs/architecture_bff_fleetbase.md`) : Fleetbase remplace l'objet
   * entier, et un `owner_uuid` absent de la charge repart vide, désolidarisant
   * le lieu du Vendor qui le filtre (`GET /places?owner_uuid=`).
   *
   * `ownerUuid` est réintroduit ici, mais reste sûr : l'appelant
   * (`commercant.service.ts`) le prend sur le `place` déjà vérifié par
   * `assertOwnsPlace`, jamais sur une valeur fournie par le client — la
   * propriété de sécurité originale (ne jamais faire confiance à un
   * `owner_uuid` non vérifié) est donc préservée, pas contournée.
   *
   * ⚠️ **Hypothèse, pas une certitude établie** : aucune instance Fleetbase
   * n'est joignable depuis ce bac à sable pour confirmer que c'est bien
   * l'absence d'`owner_uuid`, et non un autre champ silencieusement réinitialisé
   * de la même façon, qui causait la disparition. À revalider par un nouveau
   * test réel de modification d'adresse.
   */
  async updateOwnedPlace(
    placeUuid: string,
    data: {
      name: string;
      latitude: number;
      longitude: number;
      street1?: string;
      neighborhood?: string;
      city?: string;
      district?: string;
      province?: string;
      postal_code?: string;
      /** Code ISO-2 : la colonne stocke un code, pas un nom. */
      country?: string;
      phone?: string;
      meta?: Record<string, any>;
      ownerUuid?: string;
    },
  ) {
    const response = await this.callFleetOps('PUT', `/places/${this.seg(placeUuid)}`, {
      name: data.name,
      location: {
        type: 'Point',
        coordinates: [data.longitude, data.latitude],
      },
      street1: data.street1,
      neighborhood: data.neighborhood,
      city: data.city,
      district: data.district,
      province: data.province,
      postal_code: data.postal_code,
      country: data.country,
      phone: data.phone,
      meta: data.meta,
      ...(data.ownerUuid ? { owner_uuid: data.ownerUuid, owner_type: 'fleet-ops:vendor' } : {}),
    });
    return response.data;
  }

  async deletePlace(placeUuid: string) {
    const response = await this.callFleetOps('DELETE', `/places/${this.seg(placeUuid)}`);
    return response.data;
  }

  /**
   * Le carnet d'adresses d'un commerçant, **en entier**.
   *
   * ── Le plafond invisible que ceci ferme (revue du 01/08/2026, F1) ────────
   *
   * L'appel n'envoyait ni `page` ni `limit`, et **Fleetbase pagine `/places` à
   * 30 par défaut** (mesuré le 01/08/2026 : `meta.per_page = 30`). Au 31ᵉ lieu
   * enregistré, trois choses cassaient d'un coup, toutes en silence :
   *
   *   · le carnet affichait 30 adresses sans dire qu'il en manquait ;
   *   · `assertOwnsPlace()` ne trouvait plus les adresses au-delà de la page 1
   *     et refusait `PUT`/`DELETE` sur une adresse **qui existe et lui
   *     appartient**, avec un message qui l'envoyait chercher une faute de
   *     saisie ;
   *   · `clearOtherDefaults()` laissait deux « adresse principale » coexister.
   *
   * Fail-closed, donc aucune fuite — mais la panne arrive par le simple usage,
   * et rien ne la nomme. Troisième occurrence du même plafond dans ce dépôt
   * après `/orders` et `/vendors`.
   *
   * ⚠️ La borne haute est **100 et non 200** : au-delà, Fleetbase plafonne sans
   * le dire (`?limit=200` et `?limit=500` rendent l'un et l'autre 100), donc
   * demander plus donne l'illusion que la question est traitée.
   */
  async getOwnedPlaces(ownerUuid: string) {
    const pageSize = 100;
    const maxPages = 20;
    const all: any[] = [];

    for (let page = 1; page <= maxPages; page++) {
      const response = await this.callFleetOps('GET', '/places', undefined, {
        owner_uuid: ownerUuid,
        page,
        limit: pageSize,
      });
      const batch = this.extractCollection(response.data, 'places');
      all.push(...batch);

      // On s'arrête sur ce que le serveur a SERVI, jamais sur un total annoncé :
      // un total supérieur à ce qu'il sait rendre ferait boucler jusqu'au
      // garde-fou.
      if (batch.length < pageSize) return all;
    }

    this.logger.warn(
      `getOwnedPlaces a atteint le garde-fou de ${maxPages} pages pour ${ownerUuid} — ` +
        'le carnet est tronqué, et une adresse au-delà sera déclarée introuvable',
    );
    return all;
  }

  /**
   * Définitions de champs personnalisés attachées à un sujet.
   *
   * Pour une commande, le sujet est l'**`OrderConfig`** et non la commande :
   * les définitions décrivent le formulaire, les valeurs vivent sur chaque
   * commande. C'est ce que fait la console
   * (`custom-fields.js` : `store.query('custom-field', { subject_uuid: config.id })`).
   */
  async listCustomFields(subjectUuid: string) {
    // ⚠️ 100 et non 200 : Fleetbase plafonne `limit` à 100 **en silence**
    // (mesuré — `?limit=200` et `?limit=500` rendent l'un et l'autre 100).
    // Demander davantage donnait l'impression que la borne était traitée alors
    // qu'elle était ignorée. Treize définitions aujourd'hui, donc la marge est
    // large ; ce qui se corrige ici, c'est la fausse assurance.
    const response = await this.callFleetOps('GET', '/custom-fields', undefined, {
      subject_uuid: subjectUuid,
      limit: 100,
    });
    return response.data;
  }

  /**
   * Déclare un champ personnalisé.
   *
   * ⚠️ Le corps est **à plat**, sans enveloppe : `getApiPayloadFromRequest()`
   * cherche la clé au singulier (`custom_field`) puis retombe sur
   * `$request->all()`. Les règles de `CreateCustomFieldRequest` sont elles
   * aussi à plat, donc une enveloppe ferait échouer la validation.
   */
  async createCustomField(field: {
    label: string;
    name: string;
    type: string;
    subject_uuid: string;
    subject_type: string;
    category_uuid?: string;
    description?: string;
    help_text?: string;
    required?: boolean;
    editable?: boolean;
    order?: number;
  }) {
    const response = await this.callFleetOps('POST', '/custom-fields', field);
    return response.data;
  }

  /**
   * Groupes de champs personnalisés d'un `OrderConfig`.
   *
   * Ce sont des `Category` avec `for = 'custom_field_group'`. La console range
   * chaque champ dans un groupe et affiche la fiche groupe par groupe : un
   * champ sans groupe risque de n'apparaître nulle part, ce qui viderait de
   * son sens l'idée qu'un admin puisse corriger un montant.
   */
  async listCustomFieldGroups(ownerUuid: string) {
    const response = await this.callFleetOps('GET', '/categories', undefined, {
      owner_uuid: ownerUuid,
      for: 'custom_field_group',
      limit: 100,
    });
    return response.data;
  }

  async createCustomFieldGroup(ownerUuid: string, name: string) {
    const response = await this.callFleetOps('POST', '/categories', {
      owner_uuid: ownerUuid,
      owner_type: 'order-config',
      for: 'custom_field_group',
      name,
    });
    return response.data;
  }

  /**
   * Resolve the default 'transport' OrderConfig UUID, required by order creation.
   */
  async getDefaultOrderConfigUuid(): Promise<string> {
    const response = await this.callFleetOps('GET', '/order-configs');
    const configs = response.data?.order_configs || [];
    const transportConfig = configs.find((c: any) => c.key === 'transport') || configs[0];
    if (!transportConfig) {
      throw new Error('No OrderConfig found in Fleetbase');
    }
    return transportConfig.uuid;
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
    /**
     * Explicite pour un brouillon (30/07/2026), à `false`.
     *
     * ⚠️ **Corrige une hypothèse fausse** : un précédent essai forçait
     * `status: 'created'`, sans effet — la commande passait quand même en
     * `Dispatched` à la création (constaté par test réel, journal d'activité
     * montrant les deux évènements à la même minute). Capture réseau de la
     * console (30/07/2026) : un formulaire de création y envoie `status: null`
     * (jamais de chaîne explicite) mais **`dispatched: false` et `adhoc:
     * false` explicites** — deux champs que notre appel omettait purement et
     * simplement pour un brouillon. L'hypothèse retenue : Fleetbase traite
     * l'absence de ces deux champs comme un défaut permissif (dispatch
     * immédiat), et seule une valeur `false` explicite l'empêche.
     */
    dispatched?: boolean;
    /** Preuve exigée à la livraison. Colonnes natives. */
    pod_required?: boolean;
    pod_method?: string;
    /**
     * Valeurs des champs personnalisés, dans le stockage **durable**.
     *
     * `createRecord()` les lit sous `order.custom_field_values` puis appelle
     * `syncCustomFieldValues()`. Contrairement à `meta`, elles vivent dans une
     * table séparée qu'une mise à jour ne mentionnant pas les efface pas.
     */
    custom_field_values?: { custom_field_uuid: string; value: any; value_type: string }[];
  }) {
    const response = await this.callFleetOps('POST', '/orders', { order });
    return response.data;
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
    const response = await this.callFleetOps('GET', '/orders', undefined, {
      page,
      limit,
      // ⚠️ **CE PARAMÈTRE EST SANS EFFET, ET LA LISTE NE PORTE AUCUN MONTANT.**
      //
      // Le commentaire qui vivait ici affirmait qu'il chargeait les valeurs
      // « en une fois ». C'est faux, mesuré le 01/08/2026 :
      //
      //   GET /int/v1/orders?limit=2&with[]=customFieldValues.customField
      //     → meta = {"_index_resource": true}
      //       custom_field_values ABSENT · meta.price = null
      //   GET /int/v1/orders/{uuid}   (sans aucun with[])
      //     → meta réel · 8 valeurs de champs personnalisés
      //
      // Fleetbase sert une **ressource d'index allégée** (`Http/Resources/v1/
      // Index/Order.php`), qui remplace `meta` par un drapeau signalant que
      // l'enregistrement est partiel. Aucun paramètre ne la rend complète.
      //
      // Le paramètre est conservé : il ne coûte rien, et il redeviendra utile si
      // l'amont enrichit la ressource d'index. Mais **tout appelant qui a besoin
      // d'un montant doit recharger la commande unitairement** — c'est ce que
      // fait `FlotteService.hydratePage()`, et ce que les modules commerçant et
      // transporteur obtiennent autrement, par `Order.specMeta`.
      //
      // Cette phrase fausse a servi d'argument, textuellement, pour écrire une
      // hydratation qui ne recomposait rien : une donnée d'appui fausse ne dort
      // pas dans un commentaire, elle fait conclure (cf. la borne du `pubspec`).
      with: ['customFieldValues.customField'],
      ...filters,
    });
    return response.data;
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
   * **Une** page de commandes, découpée par Fleetbase, avec son total.
   *
   * ── Ce que cette méthode évite ──────────────────────────────────────────────
   *
   * `fetchEveryOrder(100, 50)` rapatrie jusqu'à cinquante pages — 5 000
   * commandes — pour en afficher vingt-cinq. C'est correct et ça le restera :
   * le coût grandit simplement avec le réseau, et il grandit chez nous.
   *
   * Quand **tous** les critères d'une liste sont honorés par Fleetbase, il n'y a
   * aucune raison de faire ce voyage : il pagine nativement et sert `meta.total`.
   *
   * ── La condition d'emploi, et elle n'est pas négociable ─────────────────────
   *
   * ⚠️ **N'employer cette méthode que si le découpage est fait sur des filtres
   * intégralement honorés.** Un critère évalué en mémoire après coup (statut
   * combiné, course réclamable, préférence de zone) rendrait des pages
   * incomplètes et un total faux : Fleetbase compterait des commandes que le
   * BFF retire ensuite. Dans ce cas-là, `fetchEveryOrder` reste la bonne
   * réponse — c'est un coût, pas un défaut.
   *
   * ⚠️ **Et chaque filtre déplacé se vérifie contre un témoin inventé.**
   * Fleetbase abandonne **en silence** un filtre qu'il ne reconnaît pas : un
   * nom erroné ne produit ni erreur ni journal, seulement toute la compagnie
   * servie comme si c'était le résultat. Mesuré le 02/08/2026 sur 422
   * commandes — `facilitator` 26 contre 0 pour un uuid inventé, `status=created`
   * 37 contre 0, `without_driver` 123 contre 422. ⚠️ Le premier banc comparait
   * le **nombre de lignes** et non les totaux : plafonné à `limit`, il concluait
   * « ignoré » sur un filtre qui marchait.
   *
   * ── `total` peut être `null`, et il ne faut pas le remplacer ────────────────
   *
   * Si `meta.total` manque, **on ne le devine pas** : `orders.length` dirait
   * « voilà tout » sur une page pleine, donc une liste tronquée en silence — le
   * défaut que le total servi corrige justement. L'appelant reçoit `null` et
   * retombe sur le parcours complet, qui est lent mais juste.
   */
  async getOrderPage(
    page: number,
    limit: number,
    filters: OrderFilters = {},
  ): Promise<{ orders: any[]; total: number | null }> {
    const response = await this.getAllOrders(page, limit, filters);
    const orders = this.extractCollection(response, 'orders');

    const raw = (response as any)?.meta?.total;
    const total = typeof raw === 'number' && Number.isFinite(raw) ? raw : null;

    if (total === null) {
      this.logger.warn(
        'Fleetbase n’a pas servi meta.total sur cette page : impossible de dire ' +
          'combien de commandes existent, l’appelant doit reprendre le parcours complet',
      );
    }

    return { orders, total };
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
    const response = await this.callFleetOps('GET', `/orders/${this.seg(orderUuid)}`);
    return response.data;
  }

  /**
   * Une commande **désignée par son identifiant**, relations comprises.
   *
   * ── Ce que le source garantit (lu, pas supposé) ───────────────────────────
   *
   * `fleetbaseRoutes('orders')` expose `GET {id}` → `findRecord()`, qui appelle
   * `$this->model->getById($id, …, $request)`. Trois faits en découlent, tous
   * vérifiés dans `core-api` :
   *
   * - **uuid OU public_id** : `getById` fait `where(key, $id)->orWhere(publicId,
   *   $id)`. C'est l'une des rares routes qui accepte les deux, là où la
   *   résolution d'identifiant est ailleurs tout sauf uniforme (journal §6.7).
   * - **`with[]` est honoré** : `withRelationships()` lit `with` ou `expand`, et
   *   ne charge une relation que si `method_exists($model, $nom)` — un nom
   *   inconnu est **ignoré en silence**, jamais une erreur. Donc rien à casser
   *   si une relation disparaît en amont, mais rien non plus qui le signale :
   *   les noms ci-dessous sont ceux de la console.
   * - **réponse clé au singulier** : `findRecord` renvoie `['order' => …]`.
   *   L'appelant déballe `response.order ?? response`.
   *
   * `getById` filtre aussi sur `company_uuid` depuis la session — le cloisonnement
   * par organisation tient donc sans qu'on l'ajoute.
   *
   * ⚠️ **Cette lecture ne « corrige » pas la fiche de détail incomplète du
   * 30/07/2026.** L'hypothèse était que la liste appauvrissait la réponse ; le
   * source la contredit — `OrderResource::toArray()` sert `meta`, et `payload`
   * y compris `pickup`/`dropoff`/`entities`, **sans condition**, et la même
   * classe sert la liste et l'unitaire. On garde la lecture unitaire parce
   * qu'elle est juste (un appel au lieu d'un parcours de pages qui peut manquer
   * sa cible), pas parce qu'elle résout ce défaut-là.
   *
   * Les relations demandées sont celles dont la projection commerçant a besoin
   * — ni plus (chaque `with[]` coûte une jointure), ni moins.
   */
  /**
   * La commande **déballée**, avec ses relations.
   *
   * ⚠️ La lecture unitaire est enveloppée dans `{order: {…}}` là où la liste
   * rend l'objet nu. Appeler `getOrderWithRelations` sans déballer rendait huit
   * lignes d'`uuid: null` par lot — la seule trace qu'il y ait eu.
   */
  async readOrderFull(orderUuid: string): Promise<any> {
    const response = await this.getOrderWithRelations(orderUuid);
    return response?.order ?? response;
  }

  /**
   * Recharge des commandes venues d'une LISTE, en lectures unitaires.
   *
   * ── Pourquoi c'est indispensable, et pas une optimisation ──────────────────
   *
   * ⚠️ **La liste ne porte AUCUN champ personnalisé.** `GET /orders` est servi
   * par la ressource d'index : `meta` y vaut `{_index_resource: true}` et
   * `custom_field_values` est **absent**, `with[]` ou pas — mesuré le
   * 01/08/2026, reconfirmé le 03/08. Prix, montant à encaisser, type de
   * véhicule, refus et échecs de livraison vivent tous là : une liste non
   * rechargée les affiche donc **tous vides**.
   *
   * ⚠️ **C'est la régression du 03/08/2026, et elle mérite d'être nommée.**
   * `Order.specMeta` — une copie locale — comblait ce trou pour les modules qui
   * lisent par la liste. Il a été retiré après avoir prouvé que les 535
   * commandes avaient bien leurs champs personnalisés… ce qui prouvait le
   * **stockage**, pas la **lecture**. Le transporteur s'est retrouvé sans prix
   * ni montant à encaisser. La preuve portait sur la mauvaise moitié du trajet.
   *
   * ── Ce que la fonction garantit, et ce qu'elle ne garantit pas ─────────────
   *
   * Par lots de huit, en parallèle : recharger cinquante commandes une par une
   * rendrait la liste inutilisable. ⚠️ Une commande qu'on ne sait pas recharger
   * est **rendue telle quelle**, avec un avertissement — pas retirée. Elle
   * s'affichera sans ses montants, ce qui se voit ; la faire disparaître serait
   * un manque que personne ne peut constater.
   */
  async hydrateOrders(orders: any[], batch = 8): Promise<any[]> {
    if (!orders.length) return orders;

    const out: any[] = [];
    for (let i = 0; i < orders.length; i += batch) {
      const loaded = await Promise.all(
        orders.slice(i, i + batch).map(async (o: any) => {
          if (!o?.uuid) return o;
          try {
            return (await this.readOrderFull(o.uuid)) ?? o;
          } catch (error: any) {
            this.logger.warn(
              `Commande ${o.uuid} non rechargée (${error?.message}) — elle s'affichera `
                + 'sans ses montants',
            );
            return o;
          }
        }),
      );
      out.push(...loaded);
    }

    return out;
  }

  async getOrderWithRelations(orderUuid: string) {
    const params = new URLSearchParams();
    for (const relation of [
      'payload',
      'driverAssigned',
      'trackingNumber',
      'orderConfig',
      // Le stockage durable des données métier. `withCustomFields()` le
      // chargerait de toute façon, mais l'exiger ici rend la dépendance
      // visible : un jour où quelqu'un se demandera d'où viennent le prix et
      // le montant à encaisser, la réponse est sur cette ligne.
      'customFieldValues.customField',
    ]) {
      params.append('with[]', relation);
    }

    const response = await this.callFleetOps(
      'GET',
      `/orders/${this.seg(orderUuid)}`,
      undefined,
      params,
    );
    return response.data;
  }

  /**
   * Cancel an order. Note: no {id} in the path - the order UUID goes in
   * the request body as 'order', per OrderController::cancel().
   */
  async cancelOrder(orderUuid: string) {
    const response = await this.callFleetOps('PATCH', '/orders/cancel', { order: orderUuid });
    return response.data;
  }

  /**
   * Assign an order to a driver. Confirmed shape by reading
   * DriverController::assignOrder() - route is `/drivers/{id}/assign-order`,
   * body key is `order` (not `order_id`/`orderId`).
   */
  async assignOrderToDriver(driverUuid: string, orderUuid: string) {
    // `seg()` comme partout ailleurs : l'uuid vient ici de notre propre base
    // (favori enregistré, conducteur d'une flotte vérifiée), mais la
    // discipline vaut mieux uniforme que jugée site par site — c'est
    // exactement ce que la revue P0 avait relevé sur les autres chemins.
    const response = await this.callFleetOps('POST', `/drivers/${this.seg(driverUuid)}/assign-order`, {
      order: orderUuid,
    });
    return response.data;
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
        // ⚠️ **`facilitator_uuid` est effacé aussi**, et son oubli rendait la
        // course invisible pour tout le monde.
        //
        // `isClaimable` (flotte) et `isClaimableAdhoc` (transporteur) exigent
        // TOUS DEUX que les deux colonnes soient vides. Une course affectée par
        // une entreprise puis refusée par le conducteur ressortait donc
        // `adhoc: true` mais toujours rattachée : ni les indépendants ni les
        // entreprises ne la voyaient, et le commerçant la croyait diffusée.
        //
        // Le chemin était rare avant ce chantier ; l'affectation par une
        // entreprise en fait une opération de routine.
        facilitator_uuid: null,
        facilitator_type: null,
        adhoc: true,
        adhoc_distance: adhocDistance,
      },
    });
    return response.data;
  }

  /**
   * Dispatche une commande — la diffuse aux transporteurs ET fait avancer son
   * statut.
   *
   * ── Il existe DEUX endpoints de dispatch, et un seul fait le travail ──────
   *
   * C'est ce qui a coûté quatre tentatives. Lus dans le source `fleetops` :
   *
   * `v1` — `dispatchOrder(string $id)`, identifiant dans le chemin :
   *
   *   if ($order->dispatched) { return apiError('Order has already been dispatched!'); }
   *   $order->dispatch();              // drapeau `dispatched` + `dispatched_at`
   *   $order->insertDispatchActivity(); // l'activité, qui écrit `status`
   *
   * Deux opérations séparées, précédées d'une garde sur le drapeau. Si quoi que
   * ce soit a déjà posé `dispatched` — et poser `adhoc: true` par un `PUT` le
   * fait —, cette route **refuse et n'écrit jamais l'activité** : la commande
   * reste `status = created` définitivement. Symptôme observé en réel : une
   * commande portant à la fois « Created » et « Dispatched at 13:25 », avec
   * pour seule activité « Order Created ».
   *
   * `int/v1` — `dispatchOrder(Request $request)`, identifiant dans le CORPS :
   *
   *   $order = Order::findById($request->input('order'), [...]);
   *   $order->dispatchWithActivity();
   *
   * Une seule méthode, `dispatchWithActivity()`, qui fait les deux d'un bloc.
   * **C'est la route de la console** (`PATCH /int/v1/orders/dispatch`), donc
   * celle dont le comportement est éprouvé au quotidien par l'éditeur.
   *
   * D'où ce choix. `PATCH` et non `POST` : le verbe est imposé par
   * `$router->patch('dispatch', $controller('dispatchOrder'))`.
   *
   * ⚠️ **L'ordre des appels reste non négociable** : le dispatch exige un
   * transporteur assigné OU `adhoc` déjà posé. Assigner (ou diffuser) d'abord,
   * dispatcher ensuite.
   */
  async dispatchOrder(orderUuid: string) {
    const response = await this.callFleetOps('PATCH', '/orders/dispatch', {
      order: orderUuid,
    });
    return response.data;
  }

  /**
   * Retire une commande de la diffusion : ni transporteur assigné, ni adhoc.
   *
   * ── Pourquoi cette opération existe ───────────────────────────────────────
   *
   * C'est la **compensation** de l'étape 1 de la publication. Il n'y a pas de
   * transaction possible entre notre Postgres et le MySQL de Fleetbase, joint
   * en HTTP : publier se fait en deux écritures amont (rendre éligible, puis
   * dispatcher) et rien ne les rend atomiques.
   *
   * Or la première a un effet immédiatement visible : `adhoc: true` suffit à
   * faire apparaître la course dans la liste des opportunités d'un
   * transporteur — `transporteur.service.ts` filtre sur `adhoc === true` sans
   * exiger `dispatched`, et accepte de la faire prendre en statut `created`.
   * Si la seconde écriture échoue, la course est donc **réclamable alors que
   * le commerçant la croit encore en brouillon**.
   *
   * Ramener `adhoc` à `false` et détacher le transporteur restaure un vrai
   * brouillon. Best-effort par nature : si la compensation échoue à son tour,
   * il ne reste qu'à le journaliser fort — mais l'inverse, ne rien tenter,
   * laisse une course en circulation que personne n'a publiée.
   */
  /**
   * Rattache une course à un facilitateur, et la retire de la diffusion.
   *
   * ── Les deux écritures sont indissociables ──────────────────────────────
   *
   * Poser `facilitator_uuid` ne touche ni `adhoc` ni `driver_assigned_uuid` :
   * le dispatch adhoc de Fleetbase **continue de notifier les indépendants
   * toutes les ~4 minutes** tant que personne n'a accepté (validé par test réel
   * le 26/07, `specs_echango_delivery.md` §3.2). Une course réclamée par une
   * entreprise resterait donc proposée à tout le réseau, et notre filtre de
   * liste n'y peut rien — les pings partent de Fleetbase.
   *
   * `adhoc: false` est donc écrit **dans le même geste**, et non dans un second
   * appel : deux appels laisseraient une fenêtre pendant laquelle la course est
   * à la fois attribuée et diffusée.
   *
   * ⚠️ **Aucune clé `meta` dans ce payload.** Le `$record->update($input)` de
   * Fleetbase remplace `meta` **en entier** dès qu'elle est mentionnée — c'est
   * le bug qui efface prix et montant à encaisser quand la console affecte un
   * conducteur. On n'envoie que les colonnes voulues, jamais une commande
   * re-sérialisée.
   *
   * ── `fleet-ops:vendor`, et non `vendor` — mesuré, pas déduit ─────────────
   *
   * Contrôle C1 joué en réel le 31/07/2026 (`scripts/verify-facilitator.sh`) :
   * Fleetbase **stocke `fleet-ops:vendor`**, son alias de morphologie
   * polymorphe. Envoyer `vendor` fonctionne — la valeur est normalisée, la
   * relation `with[]=facilitator` résout le bon Vendor, et le filtre
   * `?facilitator=` rend la commande avec un témoin à 0 — mais on envoie
   * désormais la forme canonique.
   *
   * Le motif n'est pas cosmétique : dépendre d'une normalisation observée **une
   * seule fois** est plus faible que d'écrire la valeur que le serveur stocke
   * de toute façon. Si cette normalisation disparaissait, `vendor` deviendrait
   * un type inconnu, la relation cesserait de résoudre, et rien ne le
   * signalerait — le rattachement continuerait de renvoyer 2xx.
   *
   * ⚠️ Asymétrie à connaître : nous envoyons `customer_type: 'vendor'` à la
   * création, et le journal §2.10 l'a relu tel quel. Les deux colonnes ne sont
   * donc peut-être pas traitées à l'identique en amont — raison de plus pour
   * ne pas raisonner de l'une vers l'autre, ce que la première version de
   * `docs/specs_facilitateur.md` faisait et que sa revue a démenti.
   */
  async attachFacilitator(orderUuid: string, vendorUuid: string) {
    const response = await this.callFleetOps('PUT', `/orders/${this.seg(orderUuid)}`, {
      order: {
        facilitator_uuid: vendorUuid,
        facilitator_type: FACILITATOR_TYPE_VENDOR,
        adhoc: false,
      },
    });
    return response.data;
  }

  /**
   * Met à jour des champs NATIFS de la commande (PUT `/orders`, enveloppe
   * `{order}`). Sert aux transitions de dispatch qui n'ont pas de route dédiée —
   * notamment poser `adhoc: false` après une assignation, `assignOrderToDriver`
   * ne touchant que `driver_assigned_uuid`.
   */
  async setOrderFields(orderUuid: string, fields: Record<string, any>) {
    const response = await this.callFleetOps('PUT', `/orders/${this.seg(orderUuid)}`, {
      order: fields,
    });
    return response.data;
  }

  async withdrawFromDispatch(orderUuid: string) {
    const response = await this.callFleetOps('PUT', `/orders/${this.seg(orderUuid)}`, {
      order: {
        driver_assigned_uuid: null,
        adhoc: false,
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
      throw error;
    }

    // Les trois enveloppes que Fleetbase emploie selon l'endpoint (§2.4).
    const candidate =
      data?.driver ?? (data?.uuid ? data : this.extractCollection(data, 'drivers')[0]);

    return candidate?.uuid === driverUuid ? candidate : null;
  }

  /**
   * **Tous** les conducteurs correspondant à un filtre, pages comprises.
   *
   * ── Le plafond silencieux que ceci ferme ─────────────────────────────────
   *
   * `getAllDrivers()` rend **une** page. Trois appels s'en servaient comme
   * d'une liste exhaustive avec `limit: 100`, et deux autres sans limite du
   * tout — c'est-à-dire avec la page par défaut de Fleetbase :
   *
   *  * le **repli par les chiffres** des trois recherches de conducteur, qui
   *    balaie le réseau entier pour retrouver un numéro écrit dans un autre
   *    format. Au-delà du plafond, la **garde anti-doublon cesse d'opérer** —
   *    et une même personne se retrouve avec deux `Driver` Fleetbase, position
   *    et historique désynchronisés, ce que tout ce mécanisme existe pour
   *    empêcher ;
   *  * `fetchOwnedDrivers()`, la liste que l'entreprise voit de ses PROPRES
   *    conducteurs ;
   *  * le repli d'invitation d'`auth.service`, qui **refuse une invitation
   *    légitime** quand le conducteur est au-delà de la première page.
   *
   * Dans les trois cas, une liste tronquée n'est pas une liste partielle :
   * c'est une **réponse fausse**, puisque l'appelant y cherche l'absence de
   * quelqu'un. Même famille que le plafond de 100 sur les commandes (28/07) et
   * même remède — d'où la symétrie volontaire avec `fetchEveryOrder`.
   *
   * Le garde-fou de pages n'est pas une limite que quelqu'un doit atteindre ;
   * le franchir est journalisé, parce qu'au-delà les résultats redeviennent
   * faux.
   */
  async fetchEveryDriverMatching(
    filters: DriverFilters = {},
    pageSize = 100,
    maxPages = 20,
  ): Promise<any[]> {
    const all: any[] = [];

    for (let page = 1; page <= maxPages; page++) {
      const drivers = this.extractCollection(
        await this.getAllDrivers({ ...filters, page, limit: pageSize }),
        'drivers',
      );

      if (drivers.length === 0) break;
      all.push(...drivers);
      if (drivers.length < pageSize) break;

      if (page === maxPages) {
        this.logger.warn(
          `fetchEveryDriverMatching a atteint le garde-fou de ${maxPages} pages — ` +
            'la liste est tronquée, et un conducteur existant peut être déclaré absent',
        );
      }
    }

    return all;
  }

  async getAllDrivers(filters: DriverFilters = {}) {
    const response = await this.callFleetOps('GET', '/drivers', undefined, filters);
    return response.data;
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
    const response = await this.callFleetOps('POST', '/drivers', { driver: data });
    return response.data;
  }

  /**
   * Attach a Driver to a Vendor's fleet. Confirmed shape by reading
   * VendorController::assignDriver() - route is `/vendors/{id}/assign-driver`,
   * body key is `driver`; this sets the Driver's `vendor_uuid`.
   */
  async assignDriverToVendor(vendorUuid: string, driverUuid: string) {
    const response = await this.callFleetOps('POST', `/vendors/${vendorUuid}/assign-driver`, {
      driver: driverUuid,
    });
    return response.data;
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
    const response = await this.callFleetOps('POST', '/user-devices', {
      user_uuid: userUuid,
      token,
      platform,
      status: 'active',
    });
    return response.data;
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
  /**
   * ⚠️ Paginé — sans quoi la purge des jetons morts cesse en silence.
   *
   * Cette lecture est le repli appelé quand la suppression par identifiant
   * stocké a échoué, lors d'une rotation de jeton Firebase. Elle ne demandait
   * ni `page` ni `limit`, et Fleetbase sert **30 lignes** par défaut (mesuré) :
   * au-delà de 30 `UserDevice` dans l'organisation — un par téléphone, plus les
   * rotations —, le jeton cherché est hors page 1, la fonction rend `null`, et
   * il ne reste qu'un `warn`.
   *
   * Le `UserDevice` périmé survit alors, et comme `routeNotificationForFcm()`
   * renvoie **tous** les devices du `user_uuid`, les `OrderPing` partent
   * indéfiniment vers un jeton mort. Panne strictement silencieuse : des
   * notifications qui n'arrivent pas, et rien dans les journaux (revue F2).
   */
  async findUserDeviceByToken(token: string) {
    const pageSize = 100;
    const maxPages = 20;

    try {
      for (let page = 1; page <= maxPages; page++) {
        const response = await this.callFleetOps('GET', '/user-devices', undefined, {
          page,
          limit: pageSize,
        });
        const devices = this.extractCollection(response.data, 'user_devices');
        const hit = devices.find((d: any) => d?.token === token);
        if (hit) return hit;
        if (devices.length < pageSize) return null;
      }

      // Distinct de « pas trouvé » : ici on n'a pas fini de chercher, et taire
      // la différence ferait conclure à l'absence d'un jeton qu'on n'a pas
      // regardé (règle 10).
      this.logger.warn(
        `findUserDeviceByToken a atteint le garde-fou de ${maxPages} pages — ` +
          'le jeton peut exister au-delà et ne sera pas purgé',
      );
      return null;
    } catch (error) {
      this.logger.warn(`UserDevice lookup by token failed: ${error.message}`);
      return null;
    }
  }

  // ── Champs personnalisés d'un conducteur ──────────────────────────────────

  /**
   * Le conducteur, **avec ses valeurs de champs personnalisés**.
   *
   * `with[]=customFieldValues.customField` est indispensable : sans lui la
   * réponse porte les valeurs sans leur définition, donc sans le `name` qui
   * permet de savoir laquelle est laquelle. On lirait alors des uuid.
   */
  async getDriverWithCustomFields(driverId: string) {
    const response = await this.callFleetOps('GET', `/drivers/${driverId}`, undefined, {
      'with[]': 'customFieldValues.customField',
    });
    return response.data?.driver ?? response.data;
  }

  /**
   * Écrit des valeurs de champs personnalisés sur un conducteur.
   *
   * ⚠️ **Le corps DOIT être enveloppé sous `driver`.** Envoyé à plat, Laravel
   * rend un **500** : `Validation\Factory::make(): Argument #1 ($data) must be
   * of type array, null given`. Le message nomme un fichier du framework et ne
   * dit rien du contrat — mesuré le 02/08/2026, sur les deux formes
   * d'identifiant et avec ou sans champs personnalisés, avant de comprendre que
   * l'enveloppe était en cause. C'est la même convention que la lecture
   * unitaire d'une commande, servie sous `{order: {…}}`.
   */
  async setDriverCustomFieldValues(
    driverId: string,
    values: { custom_field_uuid: string; value: any; value_type: string }[],
  ) {
    const response = await this.callFleetOps('PUT', `/drivers/${driverId}`, {
      driver: { custom_field_values: values },
    });
    return response.data;
  }

  /**
   * Écrit des valeurs de champs personnalisés sur une **commande existante**.
   *
   * Sert à consigner ce qui s'est passé à la porte — montant perçu, écart,
   * horodatage — au moment de la clôture. La création, elle, les passe dans le
   * corps de `createOrder`.
   *
   * ⚠️ **Le corps ne porte QUE `custom_field_values`, et c'est essentiel.** Le
   * chemin de mise à jour de Fleetbase est un `$record->update($input)`
   * générique : toute clé présente est écrite telle quelle, et `meta` — qui est
   * dans le `$fillable` et n'a aucun mutateur — serait **remplacé en entier**.
   * C'est exactement ce que fait la console en affectant un transporteur, et ce
   * qui a détruit prix et montants sur une commande réelle le 30/07/2026. En
   * n'envoyant pas la clé, on ne peut pas commettre la même faute.
   *
   * ⚠️ **Enveloppe sous `order`**, comme `setDriverCustomFieldValues` sous
   * `driver` : envoyé à plat, Laravel rend un 500 dont le message nomme un
   * fichier du framework et ne dit rien du contrat.
   *
   * ── Mesuré en réel le 03/08/2026, contre le Fleetbase de développement ─────
   *
   * Trois choses, chacune avec son témoin, parce qu'aucune ne se déduit de la
   * lecture du source :
   *
   *  1. **L'appel passe** — `PUT` sur le `public_id`, HTTP 200, et la valeur
   *     est **relue**. Le code HTTP seul ne prouve rien : Fleetbase abandonne
   *     un champ inconnu sans rien dire.
   *  2. **`meta` est intact** après l'écriture, à l'octet près.
   *  3. ⚠️ **Le `PUT` FUSIONNE, il ne remplace pas** — et c'était la question
   *     qui décidait de tout. Trois champs posés (`price`, `cod_amount`,
   *     `collected_amount`), puis un `PUT` n'en portant **qu'un seul** : les
   *     trois sont toujours là, seul celui envoyé a changé.
   *
   * Sans ce troisième témoin, cette méthode aurait effacé prix et montant à
   * encaisser **au moment précis de la clôture** — le défaut `meta` du
   * 30/07/2026, reproduit sur le mécanisme censé le corriger. Et il fallait
   * **poser** le témoin : lire une commande qui ne porte qu'un champ ne
   * distingue pas « les autres ont été détruits » de « elle n'en avait pas ».
   */
  // ── Champs personnalisés d'un commerçant (Vendor) ─────────────────────────
  //
  // ⚠️ **La définition est portée par le VENDOR lui-même**, pas par une
  // configuration partagée : `subject_uuid` vaut l'uuid du vendor. Chaque
  // commerçant a donc sa propre définition `favourites`. C'est la mécanique de
  // Fleetbase pour les sujets qui ne sont pas des `OrderConfig`, et ça décide
  // de la forme du service qui s'en sert — un cache par vendor, pas un global.
  //
  // ⚠️ **Mesuré le 03/08/2026, pas déduit.** Le trait `HasCustomFields` sur
  // `Vendor.php` dit que le modèle les accepte ; il ne dit rien de la route.
  // Constaté en réel : `PUT /int/v1/vendors/{public_id}` avec le corps
  // enveloppé sous `vendor` rend 200, et la valeur se relit — **déjà
  // désérialisée en liste**, pas en chaîne JSON.

  /**
   * L'identité d'une entreprise — **la seule source**.
   *
   * ⚠️ `MerchantAccount.businessName` et `FleetAccount.businessName` en
   * gardaient une copie, figée à l'inscription, jusqu'au 03/08/2026. Mesurées
   * ce jour-là : 303 identiques sur 304 côté commerçant — bénin, mais c'est le
   * même mécanisme qui avait fait diverger **trois conducteurs sur trois**. Une
   * copie que personne ne compare finit par mentir ; la question n'est que
   * quand.
   *
   * ⚠️ Rend `null` plutôt qu'un nom vide si la lecture échoue : l'appelant
   * décide quoi afficher, et « je n'ai pas pu savoir » ne doit pas se déguiser
   * en « cette entreprise n'a pas de nom » (règle 10).
   */
  /**
   * Les entreprises dont le nom contient [query].
   *
   * ⚠️ **`query` est le bon paramètre, et c'est mesuré** (03/08/2026) :
   * sur 456 vendors, `query=vende` en rend **1**, un témoin inventé en rend
   * **0**, et `name=vende` en rend **0** — c'est une égalité, pas un
   * « contient ». Sans témoin, un filtre abandonné en silence par Fleetbase
   * aurait rendu les 456 comme si c'était le résultat.
   *
   * ⚠️ **Rend TOUS les vendors, commerçants compris.** Chez Fleetbase, un
   * commerçant et une entreprise de transport sont le même objet. L'appelant
   * doit intersecter avec ce que le BFF sait — c'est lui qui distingue les
   * deux populations.
   */
  async searchVendors(query: string, maxPages = 6, pageSize = 100): Promise<any[]> {
    const all: any[] = [];

    try {
      for (let page = 1; page <= maxPages; page++) {
        const response = await this.callFleetOps('GET', '/vendors', undefined, {
          query,
          page,
          limit: pageSize,
        });
        // ⚠️ **`response.data`, jamais `response`.** `callFleetOps` rend la
        // réponse axios ; `extractCollection` attend le CORPS. Lui passer la
        // réponse ne lève pas — elle rend simplement une liste **vide**, et la
        // recherche affichait « aucune entreprise » sur un vendor qui existait,
        // que Fleetbase trouvait, et dont l'uuid correspondait bien à un compte
        // (mesuré le 03/08/2026). Un déballage raté ne fait pas de bruit : il
        // fait disparaître des résultats.
        const rows = this.extractCollection(response.data, 'vendors');
        all.push(...rows);

        if (rows.length < pageSize) return all;

        if (page === maxPages) {
          // ⚠️ **Jamais de troncature muette.** L'appelant intersecte ensuite
          // avec ce que le BFF connaît : une page manquante ne rend pas « moins
          // de résultats », elle rend **aucun** quand l'entreprise cherchée
          // était au-delà. C'est le défaut mesuré le 03/08/2026 — un vendor
          // existant, une recherche qui le trouve, et une liste vide à l'écran
          // parce que le plafond était à 30.
          this.logger.warn(
            `Recherche d'entreprises « ${query} » tronquée à ${maxPages * pageSize} — `
              + 'une entreprise existante peut manquer à la liste',
          );
        }
      }
      return all;
    } catch (error: any) {
      this.logger.warn(`Recherche d'entreprises impossible (${query}) : ${error.message}`);
      return all;
    }
  }

  async getVendorIdentity(
    vendorId: string,
  ): Promise<{ name: string | null; phone: string | null } | null> {
    try {
      const response = await this.callFleetOps('GET', `/vendors/${this.seg(vendorId)}`);
      const vendor = response.data?.vendor ?? response.data;
      if (!vendor) return null;
      return {
        name: typeof vendor.name === 'string' && vendor.name.trim() ? vendor.name : null,
        phone: typeof vendor.phone === 'string' && vendor.phone.trim() ? vendor.phone : null,
      };
    } catch (error: any) {
      this.logger.warn(`Identité du vendor ${vendorId} illisible : ${error.message}`);
      return null;
    }
  }

  async getVendorWithCustomFields(vendorId: string) {
    const response = await this.callFleetOps('GET', `/vendors/${this.seg(vendorId)}`, undefined, {
      'with[]': 'customFieldValues.customField',
    });
    return response.data?.vendor ?? response.data;
  }

  async setVendorCustomFieldValues(
    vendorId: string,
    values: { custom_field_uuid: string; value: any; value_type: string }[],
  ) {
    const response = await this.callFleetOps('PUT', `/vendors/${this.seg(vendorId)}`, {
      vendor: { custom_field_values: values },
    });
    return response.data;
  }

  async setOrderCustomFieldValues(
    orderId: string,
    values: { custom_field_uuid: string; value: any; value_type: string }[],
  ) {
    const response = await this.callFleetOps('PUT', `/orders/${this.seg(orderId)}`, {
      order: { custom_field_values: values },
    });
    return response.data;
  }
}
