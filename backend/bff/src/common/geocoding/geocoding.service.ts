import { Injectable, Logger } from '@nestjs/common';
import { badRequest } from '../errors/http-errors';
import axios, { AxiosInstance } from 'axios';

export interface GeocodedPlace {
  label: string;
  latitude: number;
  longitude: number;
  city?: string;
  postalCode?: string;
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
      return { label: '', latitude, longitude };
    }
  }

  private toPlace(raw: any): GeocodedPlace {
    const address = raw?.address ?? {};
    return {
      label: raw?.display_name ?? '',
      latitude: Number(raw?.lat) || 0,
      longitude: Number(raw?.lon) || 0,
      city: address.city ?? address.town ?? address.village ?? address.municipality,
      postalCode: address.postcode,
      country: address.country,
    };
  }
}
