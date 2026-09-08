import { Injectable, Logger } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import {
  parseServiceWilayas,
  serialiseServiceWilayas,
} from '../common/orders/fleet-zone';
import { FLEET_ZONE_FIELDS } from './fleet-zone-fields';

/**
 * Lit et écrit la **zone de service** d'une entreprise de transport — la liste
 * des wilayas où elle prend des courses libres — dans les champs personnalisés
 * de son `Vendor` Fleetbase.
 *
 * Pendant de `DriverZoneService`. Deux simplifications : une seule définition à
 * provisionner, et `PUT /int/v1/vendors/:id` accepte l'**uuid** (le PUT
 * conducteur, lui, exigeait le `public_id`).
 */
@Injectable()
export class FleetZoneService {
  private readonly logger = new Logger(FleetZoneService.name);

  /**
   * `vendorUuid` → (`name` du champ → `uuid` de la définition).
   * Cache jetable au sens de la règle 1 : le perdre coûte une relecture.
   */
  private readonly cache = new Map<string, Map<string, string>>();

  constructor(private readonly fleetbase: FleetbaseApiClient) {}

  /**
   * Les wilayas déclarées par cette entreprise.
   *
   * ⚠️ Rend `[]` — « aucune préférence » — dès que quelque chose empêche de
   * lire, panne Fleetbase comprise. **Délibéré** : un défaut de lecture ne doit
   * pas se traduire par une liste de courses vide. Mieux vaut en montrer trop
   * parce qu'on n'a pas su lire la préférence que d'en cacher sur une zone
   * qu'on ignore (règle 10, même choix que `DriverZoneService.read`).
   */
  async read(vendorUuid: string): Promise<{ wilayas: string[] }> {
    try {
      const vendor = await this.fleetbase.getVendorWithCustomFields(vendorUuid);
      const values = vendor?.custom_field_values;
      if (!Array.isArray(values) || !values.length) return { wilayas: [] };

      const byName = new Map<string, any>();
      for (const entry of values) {
        const name = entry?.custom_field?.name;
        if (typeof name === 'string') byName.set(name, entry?.value);
      }

      return { wilayas: parseServiceWilayas(byName.get('service_wilayas')) };
    } catch (error: any) {
      this.logger.warn(
        `Zone de service du vendor ${vendorUuid} illisible (${error?.message}) — `
          + 'aucun filtrage appliqué, plutôt qu’une liste vide',
      );
      return { wilayas: [] };
    }
  }

  /**
   * Enregistre la liste des wilayas. Une liste vide **efface** la préférence
   * (via la sentinelle — Fleetbase refuse `value: ""`, et omettre la clé
   * conserverait l'ancienne).
   */
  async write(vendorUuid: string, wilayas: string[]): Promise<void> {
    const definitions = await this.definitionsFor(vendorUuid);
    const uuid = definitions.get('service_wilayas');
    if (!uuid) {
      this.logger.warn(
        `Définition « service_wilayas » absente pour ${vendorUuid} — valeur non écrite`,
      );
      return;
    }

    const value = serialiseServiceWilayas(wilayas);
    try {
      await this.fleetbase.setVendorCustomFieldValues(vendorUuid, [
        { custom_field_uuid: uuid, value, value_type: 'text' },
      ]);
    } catch (error: any) {
      // Une définition supprimée en amont laisse un uuid mort dans le cache.
      // On oublie ce qu'on croyait savoir et on réessaie une fois — même parade
      // que `DriverZoneService.write`.
      this.logger.warn(
        `Écriture de la zone refusée pour ${vendorUuid} (${error?.message}) — `
          + 'cache des définitions vidé, seconde tentative',
      );
      this.cache.delete(vendorUuid);
      const fresh = await this.definitionsFor(vendorUuid);
      const retry = fresh.get('service_wilayas');
      if (!retry) throw error;
      await this.fleetbase.setVendorCustomFieldValues(vendorUuid, [
        { custom_field_uuid: retry, value, value_type: 'text' },
      ]);
    }
  }

  /**
   * La définition attachée à ce vendor, créée si elle manque.
   *
   * ⚠️ Attachée **au vendor** (`subject_uuid` = son uuid), pas à une
   * configuration partagée : la relation `customFields()` filtre sur
   * `subject_uuid`. Une définition par entreprise — coût connu, imposé par le
   * modèle, comme pour le conducteur.
   */
  private async definitionsFor(vendorUuid: string): Promise<Map<string, string>> {
    const cached = this.cache.get(vendorUuid);
    if (cached) return cached;

    const known = new Map<string, string>();
    try {
      const existing = await this.fleetbase.listCustomFields(vendorUuid);
      const list = existing?.custom_fields ?? existing?.data ?? existing ?? [];
      if (Array.isArray(list)) {
        for (const field of list) {
          if (typeof field?.name === 'string' && field?.uuid) {
            known.set(field.name, field.uuid);
          }
        }
      }

      for (const definition of FLEET_ZONE_FIELDS) {
        if (known.has(definition.name)) continue;
        // ⚠️ La réponse porte la définition sous `custom_field`, pas `data`.
        const created = await this.fleetbase.createCustomField({
          label: definition.label,
          name: definition.name,
          type: definition.type,
          subject_uuid: vendorUuid,
          subject_type: 'vendor',
          help_text: definition.helpText,
          editable: true,
          required: false,
        });
        const uuid =
          created?.custom_field?.uuid ?? created?.data?.uuid ?? created?.uuid;
        if (uuid) known.set(definition.name, uuid);
      }
    } catch (error: any) {
      this.logger.warn(
        `Provisionnement du champ de zone impossible pour ${vendorUuid} : ${error?.message}`,
      );
    }

    if (known.size) this.cache.set(vendorUuid, known);
    return known;
  }
}
