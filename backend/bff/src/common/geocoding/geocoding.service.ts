import { Injectable, Logger } from '@nestjs/common';
import axios, { AxiosInstance } from 'axios';
import { serviceUnavailable } from '../errors/http-errors';
import { ErrorCode } from '../errors/error-codes';

/**
 * Une adresse décomposée.
 *
 * ⚠️ **Contrat figé, partagé avec l'app** (`echango_delivery/lib/…/geocoded_
 * place.dart`) et avec le service transverse `echango-geo`, qui produit
 * exactement cette forme. Ni ce fichier ni aucun écran n'a bougé lors de la
 * bascule du géocodage vers `echango-geo` (05/09/2026) — seule la source a
 * changé, de Nominatim-en-direct à un appel HTTP interne.
 *
 * Chaque composante a sa colonne dans le modèle `Place` : c'est ce qui permet
 * le tri par commune et la recherche par code postal, qu'un `display_name`
 * rangé en une chaîne interdisait.
 */
export interface GeocodedPlace {
  /** `display_name` entier, tel quel. */
  label: string;
  /**
   * Ce qui désigne la porte : numéro, rue, quartier. Alimente le champ
   * « Adresse » du formulaire commerçant (`street1`).
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
  /** Code ISO-2 en majuscules, **et pas le nom du pays**. */
  country?: string;
}

/**
 * Géocodage — client HTTP du service transverse `echango-geo`.
 *
 * ── Pourquoi un service dédié plutôt qu'un appel Nominatim ici ──────────────
 *
 * Deux implémentations Nominatim indépendantes coexistaient dans l'écosystème
 * (ce BFF et le CRM), chacune ayant repayé le prix du throttle, de la gestion
 * du 429 et du risque de bannissement d'IP. Le référentiel géographique
 * public n'appartient à aucun produit : il vit dans `echango-geo`, derrière
 * un Nominatim auto-hébergé. Voir `echango-geo/docs/specs_echango_geo_v1.md`.
 *
 * Ce qui a disparu d'ici avec la bascule : le mapping `toPlace()` (~80 lignes,
 * désormais dans `echango-geo`, appelé une fois pour tout l'écosystème), le
 * throttle de 1 100 ms (contrainte de l'instance **publique** d'OSM, sans
 * objet une fois self-hosté), l'en-tête `User-Agent` de politique d'usage.
 *
 * ── Frontière d'accès ─────────────────────────────────────────────────────
 *
 * `echango-geo` n'est pas exposé publiquement : il n'est joignable que sur le
 * réseau Docker interne, et exige en plus un jeton partagé dans
 * `X-Internal-Token`. L'app ne l'appelle jamais — seul ce BFF le fait.
 */
@Injectable()
export class GeocodingService {
  private readonly logger = new Logger(GeocodingService.name);
  private readonly client: AxiosInstance;
  private readonly baseURL: string;

  constructor() {
    this.baseURL = process.env.GEO_SERVICE_URL || 'http://geo-api:3000';
    this.client = axios.create({
      baseURL: this.baseURL,
      timeout: Number(process.env.GEO_SERVICE_TIMEOUT_MS) || 12000,
      headers: {
        'X-Internal-Token': process.env.GEO_INTERNAL_TOKEN ?? '',
      },
    });
  }

  /** Recherche d'adresse à partir d'un texte libre. */
  async search(query: string, limit = 5): Promise<GeocodedPlace[]> {
    if (query.trim().length < 3) return [];

    try {
      const { data } = await this.client.get<{ results: GeocodedPlace[] }>(
        '/v1/geocode/search',
        {
          params: {
            q: query,
            limit,
            // `echango-geo` restreint aussi côté serveur, mais on transmet le
            // pays attendu : sans lui « rue de la Liberté » remonte d'abord
            // des résultats européens.
            country: process.env.GEOCODING_COUNTRY || 'dz',
          },
        },
      );
      // `echango-geo` rend déjà la forme `GeocodedPlace` (mapping fait chez
      // lui) — rien à retransformer ici.
      return data.results ?? [];
    } catch (error) {
      throw this.unavailable('search', query, error);
    }
  }

  /**
   * Adresse correspondant à un point.
   *
   * ⚠️ **Un point que Nominatim ne connaît pas (mer, zone non cartographiée)
   * n'est pas une erreur** : `echango-geo` répond alors `200` avec les
   * coordonnées et des champs texte vides, et on le relaie tel quel — le point
   * reste valide, c'est le libellé qui manque.
   *
   * En revanche, si `echango-geo` est injoignable, on lève `503` et **pas** un
   * `200` à libellé vide : sans ça, une panne du service serait indiscernable
   * d'un point en mer, exactement l'ambiguïté que ce service a été construit
   * pour lever.
   */
  async reverse(latitude: number, longitude: number): Promise<GeocodedPlace> {
    try {
      const { data } = await this.client.get<GeocodedPlace>('/v1/geocode/reverse', {
        params: { lat: latitude, lon: longitude },
      });
      return data;
    } catch (error) {
      throw this.unavailable('reverse', `${latitude},${longitude}`, error);
    }
  }

  /**
   * `echango-geo` répond-il ? Sonde pour `/health`, qui la RAPPORTE sans
   * échouer — même forme que `FleetbaseApiClient.ping()`.
   *
   * Axios nu, hors du client : `validateStatus` laisse passer n'importe quel
   * statut (un `200` de `/health` suffit à prouver qu'il répond), et un amont
   * à terre est un état qu'on mesure, pas un incident à journaliser à chaque
   * `/health`. Timeout court : la sonde ne doit pas hériter des 12 s du client.
   */
  async ping(timeoutMs = 2500): Promise<{ reachable: boolean }> {
    try {
      await axios.get(`${this.baseURL}/health`, {
        timeout: timeoutMs,
        validateStatus: () => true,
      });
      return { reachable: true };
    } catch {
      return { reachable: false };
    }
  }

  private unavailable(op: string, subject: string, error: unknown): never {
    const status =
      axios.isAxiosError(error) && error.response ? error.response.status : undefined;
    const upstreamCode =
      axios.isAxiosError(error) && error.response
        ? (error.response.data as { code?: string })?.code
        : undefined;
    this.logger.warn(
      `geo/${op} a échoué (${subject}) : ${
        status ? `HTTP ${status}${upstreamCode ? ` ${upstreamCode}` : ''}` : (error as Error).message
      }`,
    );
    serviceUnavailable(
      ErrorCode.GEOCODING_UNAVAILABLE,
      op === 'reverse' ? 'Géocodage inverse indisponible' : "Recherche d'adresse indisponible",
    );
  }
}
