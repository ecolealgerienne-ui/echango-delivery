import { Injectable, Logger } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';
import axios, { AxiosInstance } from 'axios';

/**
 * Une adresse décomposée, telle que Nominatim la rend.
 *
 * ── Pourquoi décomposer plutôt que garder une chaîne ────────────────────────
 *
 * Le `display_name` de Nominatim est une phrase :
 * « Chemin Haddad Ali, Belcourt, Sidi M'Hamed, Alger, Daïra Sidi M'Hamed,
 * Alger, 16000, Algérie ». Rangée entière dans `street1`, elle donnait une
 * adresse où la wilaya apparaissait deux fois — l'accesseur `address` de
 * Fleetbase y rajoutant le nom du lieu et la commune —, et surtout aucun champ
 * exploitable : ni tri par commune, ni recherche par code postal, et
 * `coarseLocality()` réduit à découper une chaîne pour retrouver ce que le
 * géocodeur avait déjà séparé.
 *
 * Le modèle `Place` a exactement les colonnes qu'il faut. La correspondance
 * est donc directe, et c'est la forme fidèle : chaque composante à sa place.
 *
 * ⚠️ **Les noms de champs de Nominatim varient selon le pays**, et sa
 * documentation ne les énumère pas exhaustivement. Les chaînes de repli
 * ci-dessous sont ordonnées du plus précis au plus large ; en Algérie, la
 * commune (`Sidi M\'Hamed`) et l\'agglomération (`Alger`) ne sont pas au même
 * niveau administratif, et laquelle porte quelle clé reste **à confirmer sur
 * un appel réel** — `scripts/check-geocoding.sh`.
 */
export interface GeocodedPlace {
  /** `display_name` entier, tel quel. */
  label: string;
  /**
   * Ce qui désigne la porte : numéro, rue, quartier.
   *
   * C'est ce qu'on propose au commerçant dans le champ « Adresse », puisque
   * commune, wilaya, code postal et pays ont désormais leur propre colonne.
   */
  shortLabel: string;
  latitude: number;
  longitude: number;
  /** Numéro et rue. */
  street?: string;
  /** Quartier. */
  neighborhood?: string;
  /** Daïra. */
  district?: string;
  /** Commune. */
  city?: string;
  /** Wilaya. */
  province?: string;
  postalCode?: string;
  /**
   * Code ISO-2 en majuscules, **et pas le nom du pays**.
   *
   * La colonne `country` de `Place` stocke un code : `country_name` est un
   * accesseur qui le résout (`data_get($this, 'country_data.name.common')`).
   * Y écrire « Algérie » laisserait donc `country_name` vide.
   */
  country?: string;
}

/**
 * Géocodage par Nominatim (OpenStreetMap).
 *
 * ── Pourquoi côté serveur et non dans l'app ─────────────────────────────────
 *
 * 1. **La politique d'usage de Nominatim l'exige.** Elle impose un `User-Agent`
 *    identifiant l'application et plafonne à une requête par seconde. Depuis
 *    des milliers de téléphones, ni l'un ni l'autre n'est tenable : chaque
 *    appareil s'annoncerait comme Dart, et le débit cumulé ferait bloquer notre
 *    plage d'adresses. Ici, un seul appelant, identifié, dont on maîtrise le
 *    rythme.
 * 2. **Même discipline que pour Fleetbase** : l'app ne parle qu'au BFF. Le jour
 *    où l'on passera à une instance Nominatim auto-hébergée — cohérent avec le
 *    choix d'auto-héberger Fleetbase — seule cette classe changera.
 *
 * ⚠️ **Avant un usage réel** : l'instance publique de Nominatim est prévue pour
 * un trafic modeste et interdit explicitement les usages intensifs. Elle
 * convient au pilote ; au-delà, héberger la nôtre ou passer à un service
 * dédié. Voir https://operations.osmfoundation.org/policies/nominatim/
 */
@Injectable()
export class GeocodingService {
  private readonly logger = new Logger(GeocodingService.name);
  private readonly client: AxiosInstance;

  /**
   * Nominatim demande un intervalle d'au moins une seconde entre deux
   * requêtes. On sérialise plutôt que de compter sur la modération naturelle
   * du trafic : une saisie au clavier en produit une par frappe.
   */
  private lastCallAt = 0;
  private static readonly MIN_INTERVAL_MS = 1100;

  constructor() {
    this.client = axios.create({
      baseURL: process.env.NOMINATIM_URL || 'https://nominatim.openstreetmap.org',
      timeout: 10000,
      headers: {
        // Exigé par la politique d'usage. Une adresse de contact réelle est
        // ce qui permet à l'OSMF de nous prévenir plutôt que de nous bloquer.
        'User-Agent': process.env.NOMINATIM_USER_AGENT || 'EchangoDelivery/0.1 (contact@echango.local)',
        'Accept-Language': 'fr',
      },
    });
  }

  private async throttle(): Promise<void> {
    const wait = GeocodingService.MIN_INTERVAL_MS - (Date.now() - this.lastCallAt);
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    this.lastCallAt = Date.now();
  }

  /** Recherche d'adresse à partir d'un texte libre. */
  async search(query: string, limit = 5): Promise<GeocodedPlace[]> {
    if (query.trim().length < 3) return [];

    await this.throttle();

    try {
      const { data } = await this.client.get('/search', {
        params: {
          q: query,
          format: 'jsonv2',
          addressdetails: 1,
          limit,
          // Restreint à l'Algérie : sans ça, « rue de la Liberté » remonte
          // d'abord des résultats européens, et le commerçant choisit sans
          // s'en apercevoir une adresse à 2 000 km.
          countrycodes: process.env.GEOCODING_COUNTRY || 'dz',
        },
      });

      return (Array.isArray(data) ? data : []).map((r: any) => this.toPlace(r));
    } catch (error) {
      this.logger.warn(`Recherche d'adresse échouée (${query}) : ${error.message}`);
      badRequest('geocoding.unavailable', 'Recherche d\'adresse indisponible');
    }
  }

  /** Adresse correspondant à un point choisi sur la carte. */
  async reverse(latitude: number, longitude: number): Promise<GeocodedPlace> {
    await this.throttle();

    try {
      const { data } = await this.client.get('/reverse', {
        params: { lat: latitude, lon: longitude, format: 'jsonv2', addressdetails: 1 },
      });

      // Nominatim ne connaît pas tous les points — mer, désert, zone non
      // cartographiée. Le point reste valide et utilisable par le dispatch :
      // c'est le libellé qui manque, pas la position. On renvoie donc les
      // coordonnées avec un libellé vide plutôt qu'une erreur.
      return {
        ...this.toPlace(data ?? {}),
        latitude,
        longitude,
      };
    } catch (error) {
      this.logger.warn(`Géocodage inverse échoué (${latitude},${longitude}) : ${error.message}`);
      return { label: '', shortLabel: '', latitude, longitude };
    }
  }

  private toPlace(raw: any): GeocodedPlace {
    const a = raw?.address ?? {};

    const first = (...values: any[]): string | undefined =>
      values.find((v) => typeof v === 'string' && v.trim().length > 0);

    // « 12 Rue X » : le numéro précède la voie en français, l'inverse de
    // l'usage anglo-saxon. Nominatim les rend séparés, à nous de les joindre
    // dans le bon ordre.
    const street =
      [a.house_number, first(a.road, a.pedestrian, a.footway, a.path)]
        .filter((v) => typeof v === 'string' && v.length > 0)
        .join(' ') || undefined;

    // ── Correspondance établie sur un appel réel (Alger, 30/07/2026) ────────
    //
    //   road         : Rue Larbi Tebessi     neighbourhood : Ali Mellah
    //   suburb       : Belcourt              city          : Alger
    //   county       : Daïra Sidi M'Hamed    state         : Alger
    //   postcode     : 16000                 country_code  : dz
    //
    // Deux enseignements, tous deux contraires à ce que j'avais supposé.
    //
    // **Nominatim ne rend pas la commune.** « Sidi M'Hamed » n'apparaît que
    // dans le nom de la daïra ; `city` porte l'agglomération et `state` la
    // wilaya, qui s'appellent toutes deux « Alger ». Il n'y a donc pas de clé
    // à choisir pour la commune : elle n'est pas dans la réponse. `city` reste
    // le plus proche, et sur une commune hors agglomération il la renvoie
    // directement — d'où la chaîne, qui couvre les deux cas.
    //
    // **`neighbourhood` et `suburb` coexistent et diffèrent.** N'en garder
    // qu'un perdrait « Belcourt », qui est le nom par lequel un transporteur
    // situe l'adresse — bien plus que « Daïra Sidi M'Hamed ». D'où `suburb`
    // dans `district` de préférence à la daïra, qui n'aide personne à
    // trouver une porte.
    const neighborhood = first(a.neighbourhood, a.quarter, a.suburb, a.city_district);
    const suburb = first(a.suburb, a.city_district);
    const district =
      suburb && suburb !== neighborhood ? suburb : first(a.county, a.state_district);

    const city = first(a.municipality, a.city, a.town, a.village, a.city_district);
    const province = first(a.state, a.region);

    return {
      label: raw?.display_name ?? '',
      // « Rue Larbi Tebessi, Ali Mellah, Belcourt » : la voie et les deux noms
      // de secteur les plus fins. C'est ce qui permet de trouver la porte ;
      // commune, wilaya, code postal et pays ont leur colonne et n'ont rien à
      // faire dans une ligne d'adresse.
      //
      // Dédoublonné : sur un point sans voie nommée, Nominatim renvoie parfois
      // le même mot sous deux clés, et « Belcourt, Belcourt » se lit comme un
      // défaut d'affichage.
      shortLabel: [street, neighborhood, suburb]
        .filter((v, i, all): v is string => Boolean(v) && all.indexOf(v) === i)
        .join(', '),
      latitude: Number(raw?.lat) || 0,
      longitude: Number(raw?.lon) || 0,
      street,
      neighborhood,
      district,
      city,
      province,
      postalCode: first(a.postcode),
      country:
        typeof a.country_code === 'string' ? a.country_code.toUpperCase() : undefined,
    };
  }
}
