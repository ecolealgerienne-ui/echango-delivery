import { Injectable, Logger } from '@nestjs/common';

import { FleetbaseApiClient } from './fleetbase-api.client';

/**
 * Les favoris d'un commerçant, **portés par son `Vendor` Fleetbase**.
 *
 * ── Pourquoi ce n'est plus une table du BFF (03/08/2026) ────────────────────
 *
 * `DriverFavourite` vivait côté BFF, donc **invisible depuis la console** — et
 * la console est utilisée en exploitation. Un opérateur qui se demande pourquoi
 * une course part toujours au même transporteur n'avait aucun moyen de voir que
 * le commerçant l'avait mis en favori.
 *
 * ── Ce que la table garantissait, et comment on le tient maintenant ─────────
 *
 * Un `@@unique([merchantId, partyType, fleetbasePartyUuid])`. Ici c'est le
 * dédoublonnage de [add] qui le tient : ajouter deux fois le même transporteur
 * remplace l'entrée au lieu d'en créer une seconde.
 *
 * ⚠️ **Lire-modifier-écrire, donc non atomique.** Deux ajouts simultanés par le
 * *même* commerçant peuvent en perdre un. C'est un cas de figure qui suppose
 * deux appareils du même compte appuyant dans la même seconde ; la perte est un
 * favori à rajouter, jamais une donnée métier. Nommé plutôt que tu (règle 2).
 *
 * ── Un détail de Fleetbase qui décide de la forme de ce service ─────────────
 *
 * ⚠️ La définition du champ est portée par **le vendor lui-même**
 * (`subject_uuid` = uuid du vendor), pas par une configuration partagée. Chaque
 * commerçant a donc sa propre définition, et le cache est **par vendor** — un
 * cache global rendrait l'uuid de définition d'un commerçant à un autre, et on
 * écrirait les favoris de l'un sur la fiche de l'autre.
 */

/** Un favori, tel qu'il est stocké et servi. */
export interface MerchantFavourite {
  /** `driver` ou `fleet`. */
  party_type: string;
  /** uuid Fleetbase du conducteur ou du vendor de l'entreprise. */
  party_uuid: string;
  party_name?: string | null;
  added_at?: string | null;
}

const CHAMP = 'favourites';

@Injectable()
export class MerchantFavouritesService {
  private readonly logger = new Logger(MerchantFavouritesService.name);

  /** uuid du vendor → uuid de sa définition `favourites`. */
  private readonly definitions = new Map<string, string>();

  constructor(private readonly fleetbase: FleetbaseApiClient) {}

  /**
   * Les favoris de ce commerçant, du plus récent au plus ancien.
   *
   * ⚠️ **Lève plutôt que de rendre une liste vide** si la lecture échoue. Une
   * liste vide se lit « ce commerçant n'a aucun favori » — et l'appelant en
   * tire des conséquences : la sollicitation d'un favori part au pool, l'écran
   * affiche « aucun transporteur favori ». Un défaut de lecture doit se dire
   * (règle 10), pas se déguiser en absence.
   */
  async read(vendorUuid: string): Promise<MerchantFavourite[]> {
    const vendor = await this.fleetbase.getVendorWithCustomFields(vendorUuid);
    return this.extract(vendor);
  }

  /**
   * Variante tolérante, pour les chemins où l'absence de favori n'est **pas**
   * une information : la sollicitation à la création.
   *
   * ⚠️ Le repli est sûr **dans ce sens précis** — ne pas trouver de favori
   * envoie la course au pool, ce que le commerçant a de toute façon accepté en
   * cochant l'option. L'inverse (assigner à un favori qu'on croit lire) ne
   * serait pas rattrapable.
   */
  async readOrNone(vendorUuid: string): Promise<MerchantFavourite[]> {
    try {
      return await this.read(vendorUuid);
    } catch (error: any) {
      this.logger.warn(
        `Favoris illisibles pour ${vendorUuid} (${error.message}) — la course part au pool`,
      );
      return [];
    }
  }

  /** Ajoute ou remplace un favori. Rend la liste complète après écriture. */
  async add(
    vendorUuid: string,
    favourite: MerchantFavourite,
  ): Promise<MerchantFavourite[]> {
    const vendor = await this.fleetbase.getVendorWithCustomFields(vendorUuid);
    const actuels = this.extract(vendor);

    const suivants = [
      { ...favourite, added_at: new Date().toISOString() },
      ...actuels.filter(
        (f) =>
          !(f.party_uuid === favourite.party_uuid && f.party_type === favourite.party_type),
      ),
    ];

    await this.write(vendorUuid, vendor, suivants);
    return suivants;
  }

  /**
   * Retire un favori. Rend `false` s'il n'y était pas.
   *
   * L'appelant en fait un `notFound` : retirer un favori inexistant doit se
   * dire, sinon un identifiant erroné passe pour un succès et l'écran affiche
   * une suppression qui n'a pas eu lieu.
   */
  async remove(vendorUuid: string, partyUuid: string): Promise<boolean> {
    const vendor = await this.fleetbase.getVendorWithCustomFields(vendorUuid);
    const actuels = this.extract(vendor);
    const suivants = actuels.filter((f) => f.party_uuid !== partyUuid);

    if (suivants.length === actuels.length) return false;

    await this.write(vendorUuid, vendor, suivants);
    return true;
  }

  /**
   * Les favoris portés par une réponse vendor déjà en main.
   *
   * ⚠️ **La valeur peut arriver DÉJÀ désérialisée**, et c'est mesuré : sur ce
   * Fleetbase, `custom_field_values[].value` d'un champ `array` revient en
   * liste JavaScript, pas en chaîne. Un `JSON.parse` inconditionnel lèverait et
   * ferait passer une liste pleine pour une liste vide — le défaut exact commis
   * dans le script de reprise, qui réécrivait onze refus à chaque passage.
   */
  private extract(vendor: any): MerchantFavourite[] {
    const rows = vendor?.custom_field_values;
    if (!Array.isArray(rows)) return [];

    const row = rows.find((v: any) => v?.custom_field?.name === CHAMP);
    if (!row) return [];

    let brut = row.value;
    if (typeof brut === 'string') {
      if (!brut.trim()) return [];
      try {
        brut = JSON.parse(brut);
      } catch {
        this.logger.warn(`Favoris illisibles sur ${vendor?.uuid} : valeur non JSON`);
        return [];
      }
    }

    if (!Array.isArray(brut)) return [];
    return brut.filter(
      (f: any) => f && typeof f.party_uuid === 'string' && f.party_uuid.length > 0,
    );
  }

  private async write(
    vendorUuid: string,
    vendor: any,
    favourites: MerchantFavourite[],
  ): Promise<void> {
    const definitionUuid = await this.definitionFor(vendorUuid);

    await this.fleetbase.setVendorCustomFieldValues(vendor?.public_id ?? vendorUuid, [
      {
        custom_field_uuid: definitionUuid,
        // Encodé à la main : le cast de Fleetbase remplit `value` avant
        // `value_type` et ne sérialise donc pas lui-même (même contournement
        // que pour les commandes).
        value: JSON.stringify(favourites),
        value_type: 'array',
      },
    ]);
  }

  /** L'uuid de la définition `favourites` de ce vendor, créée au besoin. */
  private async definitionFor(vendorUuid: string): Promise<string> {
    const connu = this.definitions.get(vendorUuid);
    if (connu) return connu;

    const response = await this.fleetbase.listCustomFields(vendorUuid);
    const existants = this.fleetbase.extractCollection(response, 'custom_fields');
    const trouve = existants.find(
      (f: any) => f?.name === CHAMP && (!f?.subject_uuid || f.subject_uuid === vendorUuid),
    );

    if (trouve?.uuid) {
      this.definitions.set(vendorUuid, trouve.uuid);
      return trouve.uuid;
    }

    const cree = await this.fleetbase.createCustomField({
      subject_uuid: vendorUuid,
      subject_type: 'vendor',
      name: CHAMP,
      label: CHAMP,
      type: 'text',
      description:
        'Transporteurs et entreprises que ce commerçant a mis en favori. '
        + 'Sollicités en priorité quand il coche l\'option à la création.',
      required: false,
      editable: true,
      order: 0,
    });

    const uuid = cree?.custom_field?.uuid ?? cree?.uuid;
    if (!uuid) {
      throw new Error(`Définition « ${CHAMP} » non créée pour le vendor ${vendorUuid}`);
    }

    this.definitions.set(vendorUuid, uuid);
    return uuid;
  }
}
