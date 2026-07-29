import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * Origine d'un montant. **Enregistrée avec le prix**, jamais déduite.
 *
 * Sans elle, l'historique du pilote mélangerait les prix proposés par les
 * commerçants et ceux calculés par la plateforme — et la calibration de la
 * future formule serait faite sur ses propres résultats, ce qui la validerait
 * quoi qu'elle vaille.
 */
export type PriceSource =
  /** Montant saisi par le commerçant. Le modèle actuel. */
  | 'merchant'
  /** Montant calculé par la plateforme. Pas encore implémenté. */
  | 'computed';

/** Ce dont une formule de calcul aura besoin, figé à la création. */
export interface PricingInputs {
  pickupLatitude: number;
  pickupLongitude: number;
  dropoffLatitude: number;
  dropoffLongitude: number;
  /** Enlèvement programmé (ISO 8601), ou absent pour « dès que possible ». */
  scheduledAt?: string;
  /** Catégorie minimale exigée. */
  vehicleType?: string;
}

export interface Quote {
  amount: number | null;
  currency: string;
  source: PriceSource;
  /**
   * Les entrées retenues, conservées avec le montant.
   *
   * Les figer plutôt que de les recalculer plus tard : la distance dépend du
   * géocodage et du réseau routier au moment de la course, et une commande
   * rejouée six mois après ne donnerait pas le même chiffre. Un prix qu'on ne
   * peut pas réexpliquer est un prix qu'on ne peut pas contester.
   */
  inputs: Record<string, any>;
}

/**
 * Tarification.
 *
 * ── État : un seul mode, mais la couture est posée ───────────────────────────
 *
 * Aujourd'hui le commerçant **propose** un montant et la plateforme le relaie.
 * Une méthode de calcul viendra — au kilomètre, à la durée, avec majoration
 * selon l'horaire — mais son barème n'est pas tranché (Priorité 3 du plan
 * d'action), et l'inventer ici serait prendre la décision par défaut.
 *
 * Ce que ce service fait dès maintenant, et qui ne peut PAS être rattrapé plus
 * tard : **capturer les entrées de la future formule sur chaque commande**.
 * Distance, horaire, catégorie de véhicule. Sans elles, les commandes du pilote
 * ne serviront pas à calibrer le barème — on ne pourra pas répondre à « qu'est-
 * ce que ce trajet aurait coûté au tarif X ? » sur des courses réelles.
 *
 * ── Quand la formule arrivera ────────────────────────────────────────────────
 *
 * Implémenter `computeQuote()` et basculer `PRICING_MODE=computed`. Les
 * appelants ne changent pas : ils demandent un devis, ils reçoivent un montant
 * et sa provenance.
 */
@Injectable()
export class PricingService {
  private readonly logger = new Logger(PricingService.name);

  constructor(private readonly configService: ConfigService) {}

  get currency(): string {
    return this.configService.get('CURRENCY') || 'DZD';
  }

  /**
   * Distance à vol d'oiseau entre deux points, en mètres.
   *
   * ⚠️ **Sous-estime systématiquement la distance routière**, de 20 à 40 % en
   * milieu urbain. Ce n'est donc pas un substitut à un calcul d'itinéraire :
   * c'est une entrée de calibration, enregistrée telle quelle et étiquetée
   * comme telle (`distance_method: 'haversine'`).
   *
   * Le vrai calcul demande un moteur de routage — OSRM, non auto-hébergé à ce
   * stade malgré le narratif du projet (specs_echango_delivery.md §3). Quand il
   * le sera, la distance routière viendra le compléter, et l'étiquette
   * permettra de distinguer les deux dans l'historique.
   */
  static haversineMetres(
    lat1: number,
    lon1: number,
    lat2: number,
    lon2: number,
  ): number {
    const R = 6371000;
    const toRad = (deg: number) => (deg * Math.PI) / 180;

    const dLat = toRad(lat2 - lat1);
    const dLon = toRad(lon2 - lon1);
    const a =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;

    return Math.round(R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a)));
  }

  /**
   * Entrées de tarification d'une commande, à figer dans ses métadonnées.
   *
   * Appelé même quand le prix est saisi par le commerçant : c'est justement
   * l'appariement « ce qu'il a proposé » / « ce que le trajet valait » qui
   * permettra de construire le barème.
   */
  buildInputs(inputs: PricingInputs): Record<string, any> {
    const distance = PricingService.haversineMetres(
      inputs.pickupLatitude,
      inputs.pickupLongitude,
      inputs.dropoffLatitude,
      inputs.dropoffLongitude,
    );

    const scheduled = inputs.scheduledAt ? new Date(inputs.scheduledAt) : new Date();

    return {
      distance_metres: distance,
      distance_method: 'haversine',
      vehicle_type: inputs.vehicleType ?? null,
      // L'heure et le jour sont conservés séparément de l'horodatage : ce sont
      // eux qui porteront les majorations (nuit, week-end), et les extraire au
      // moment du calcul supposerait de connaître le fuseau d'alors.
      scheduled_at: scheduled.toISOString(),
      scheduled_hour: scheduled.getHours(),
      scheduled_weekday: scheduled.getDay(),
    };
  }

  /**
   * Devis d'une course.
   *
   * @param proposed montant saisi par le commerçant, s'il y en a un.
   */
  quote(inputs: PricingInputs, proposed?: number): Quote {
    const captured = this.buildInputs(inputs);
    const mode = this.configService.get('PRICING_MODE') || 'merchant';

    if (mode === 'computed') {
      const computed = this.computeQuote(captured);
      if (computed !== null) {
        return { amount: computed, currency: this.currency, source: 'computed', inputs: captured };
      }
      // Le mode calculé est demandé mais aucune formule n'existe : on retombe
      // sur la proposition du commerçant plutôt que de renvoyer un prix nul,
      // et on le dit bruyamment — une configuration qui ne fait pas ce qu'elle
      // annonce doit se voir.
      this.logger.warn(
        'PRICING_MODE=computed mais aucune formule implémentée — repli sur le montant proposé par le commerçant',
      );
    }

    return {
      amount: proposed ?? null,
      currency: this.currency,
      source: 'merchant',
      inputs: captured,
    };
  }

  /**
   * Barème de la plateforme. **Non implémenté** — décision produit ouverte.
   *
   * Ce qu'il faudra trancher avant de l'écrire : prix de base, tarif au
   * kilomètre, éventuel tarif à la durée, majorations d'horaire (nuit,
   * week-end), différenciation par catégorie de véhicule, et commission
   * Echango. Toutes ces entrées sont déjà capturées sur chaque commande depuis
   * `buildInputs()` — le barème pourra donc être testé rétroactivement sur
   * l'historique réel du pilote avant d'être activé.
   *
   * Renvoyer `null` et non zéro : l'absence de barème n'est pas un prix nul.
   */
  private computeQuote(_inputs: Record<string, any>): number | null {
    return null;
  }
}
