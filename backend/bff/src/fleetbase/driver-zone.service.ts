import { Injectable, Logger } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import { DriverPoint, DriverZone } from '../common/orders/driver-zone';
import { readDriverPosition } from '../common/geo/driver-position';
import {
  DRIVER_ZONE_FIELDS,
  readOptionalText,
  DriverZoneFieldName,
  readRadiusKm,
  readWilaya,
  ZONE_UNSET,
} from './driver-zone-fields';

/**
 * Ce qu'une lecture rend : la préférence **et** la position, tirées du même
 * appel — le filtre a besoin des deux, et les séparer doublerait le coût.
 */
export interface DriverZoneReading {
  zone: DriverZone | null;
  point: DriverPoint | null;
  /**
   * Catégorie de véhicule déclarée — `null` si rien n'est réglé, ou si la
   * lecture a échoué.
   *
   * ⚠️ **Sort de la MÊME réponse que la zone et la position**, et c'est tout
   * l'intérêt : le filtre des opportunités a besoin des trois, et les séparer
   * coûterait trois appels Fleetbase par affichage de liste.
   *
   * ⚠️ Vivait dans `DriverAccount.vehicleType` jusqu'au 03/08/2026 — une
   * colonne du BFF, donc invisible d'un opérateur en console, qui ne pouvait
   * pas corriger la catégorie d'un transporteur venu s'en plaindre.
   */
  vehicleType: string | null;
  /** Nom et téléphone tels que Fleetbase les porte — la seule source. */
  name: string | null;
  phone: string | null;
}

/**
 * Lit et écrit la zone de travail d'un conducteur, dans les champs
 * personnalisés Fleetbase.
 *
 * ── Pourquoi les définitions se provisionnent toutes seules ─────────────────
 *
 * Écrire une valeur exige l'`uuid` d'une **définition**. Demander à un opérateur
 * de créer deux champs à la main pour chaque conducteur, c'est garantir qu'un
 * jour l'un manquera — et un champ manquant ne lève rien : il fait disparaître
 * la préférence, donc le filtre, donc le transporteur revoit toute l'Algérie
 * sans comprendre pourquoi. Même parti pris que le catalogue des commandes.
 *
 * ── Ce que ce service ne fait pas ───────────────────────────────────────────
 *
 * Il ne supprime ni ne renomme. Le rattachement se fait par `name`, que la
 * console n'expose pas ; un opérateur qui renomme le libellé garde son champ.
 */
@Injectable()
export class DriverZoneService {
  private readonly logger = new Logger(DriverZoneService.name);

  /**
   * `driverId` → (`name` du champ → `uuid` de la définition).
   *
   * Cache jetable au sens de la règle 1 : le perdre coûte une relecture, jamais
   * une donnée.
   */
  private readonly cache = new Map<string, Map<string, string>>();

  constructor(private readonly fleetbase: FleetbaseApiClient) {}

  /**
   * La zone déclarée par ce conducteur.
   *
   * ⚠️ Rend `null` — « aucune préférence » — dès que quelque chose empêche de
   * lire, y compris une panne Fleetbase. **C'est délibéré** : un défaut de
   * lecture ne doit pas se traduire par une liste vide. Mieux vaut montrer trop
   * de courses parce qu'on n'a pas su lire la préférence, que d'en cacher parce
   * qu'on a supposé une zone qu'on ignore.
   */
  async read(driverUuid: string): Promise<DriverZoneReading> {
    try {
      const driver = await this.fleetbase.getDriverWithCustomFields(driverUuid);

      // ⚠️ **La position sort de la MÊME réponse**, et c'est le seul intérêt de
      // les lire ensemble : le filtre a besoin des deux, et les séparer aurait
      // coûté deux appels Fleetbase — à 3 secondes pièce sur cet
      // environnement — à chaque affichage de la liste.
      //
      // `readDriverPosition` refuse déjà `[0, 0]` et une position absente : on
      // hérite de cette prudence au lieu de la réécrire.
      const position = readDriverPosition(driver);
      const point = position
        ? { latitude: position.latitude, longitude: position.longitude }
        : null;

      // L'identité vient de Fleetbase et de nulle part ailleurs. Le BFF en
      // gardait une copie figée à l'inscription ; mesurées le 03/08/2026, les
      // deux divergeaient sur **trois conducteurs sur trois** — « Test
      // Transporteur » côté BFF contre « Amar BENGHARBI » en amont.
      const identity = {
        name: typeof driver?.name === 'string' ? driver.name : null,
        phone: typeof driver?.phone === 'string' ? driver.phone : null,
      };

      const values = driver?.custom_field_values;
      if (!Array.isArray(values) || !values.length) {
        return { zone: null, point, vehicleType: null, ...identity };
      }

      const byName = new Map<string, any>();
      for (const entry of values) {
        const name = entry?.custom_field?.name;
        if (typeof name === 'string') byName.set(name, entry?.value);
      }

      const vehicleType = readOptionalText(byName.get('vehicle_type'));
      const wilaya = readWilaya(byName.get('zone_wilaya'));
      const radiusKm = readRadiusKm(byName.get('zone_radius_km'));
      if (!wilaya && radiusKm == null) {
        return { zone: null, point, vehicleType, ...identity };
      }
      return { zone: { wilaya, radiusKm }, point, vehicleType, ...identity };
    } catch (error) {
      this.logger.warn(
        `Zone du conducteur ${driverUuid} illisible (${error?.message}) — `
          + 'aucun filtrage appliqué, plutôt qu’une liste vide',
      );
      // ⚠️ Tout à `null` — « je n'ai pas pu savoir », pas « rien de déclaré ».
      // L'appelant du filtre traite l'absence comme « aucun filtrage », ce qui
      // montre trop de courses plutôt que d'en cacher (règle 10).
      return { zone: null, point: null, vehicleType: null, name: null, phone: null };
    }
  }

  /**
   * Enregistre la catégorie de véhicule. Une valeur vide efface la préférence.
   *
   * Même mécanique que la zone, et même piège : la mise à jour n'accepte que le
   * `public_id`, les définitions se cherchent par uuid.
   */
  async writeVehicleType(
    driverUuid: string,
    driverPublicId: string,
    vehicleType: string | null,
  ): Promise<void> {
    const definitions = await this.definitionsFor(driverUuid);
    const uuid = definitions.get('vehicle_type');
    if (!uuid) {
      this.logger.warn(
        `Définition « vehicle_type » absente pour ${driverUuid} — valeur non écrite`,
      );
      return;
    }

    await this.fleetbase.setDriverCustomFieldValues(driverPublicId, [
      // ⚠️ Jamais de chaîne vide : Fleetbase la refuse sur tout champ
      // personnalisé. `ZONE_UNSET` porte l'absence.
      { custom_field_uuid: uuid, value: vehicleType || ZONE_UNSET, value_type: 'text' },
    ]);
  }

  /**
   * Enregistre la zone. Une valeur vide efface la préférence correspondante.
   *
   * ⚠️ **Deux identifiants, et ils ne sont pas interchangeables.** La lecture
   * (`GET /drivers/:id`) accepte l'uuid ; la **mise à jour** ne l'accepte pas —
   * elle rend `400 « Error occurred while trying to update a driver »`, un
   * message qui ne nomme pas la cause. Seul le `public_id` (`driver_…`) passe.
   * Mesuré le 02/08/2026, après avoir cru l'écriture cassée alors qu'elle
   * fonctionnait sous l'autre identifiant. Même piège que la suppression d'une
   * adresse, qui refuse l'`id` numérique et n'accepte que `place_…`.
   *
   * Les définitions, elles, se cherchent par **uuid** : c'est lui qui sert de
   * `subject_uuid`. D'où les deux paramètres, plutôt qu'un seul dont on
   * espérerait qu'il passe partout.
   */
  async write(driverUuid: string, driverPublicId: string, zone: DriverZone): Promise<void> {
    const definitions = await this.definitionsFor(driverUuid);

    const payload: { custom_field_uuid: string; value: any; value_type: string }[] = [];
    const push = (name: DriverZoneFieldName, value: string) => {
      const uuid = definitions.get(name);
      if (!uuid) {
        this.logger.warn(`Définition « ${name} » absente pour ${driverUuid} — valeur non écrite`);
        return;
      }
      payload.push({ custom_field_uuid: uuid, value, value_type: 'text' });
    };

    // ⚠️ Jamais de chaîne vide : Fleetbase la refuse sur tout champ
    // personnalisé (400). `ZONE_UNSET` porte l'absence — motif complet dans
    // `driver-zone-fields.ts`.
    push('zone_wilaya', zone.wilaya ?? ZONE_UNSET);
    push('zone_radius_km', zone.radiusKm == null ? ZONE_UNSET : String(zone.radiusKm));

    if (!payload.length) return;

    try {
      await this.fleetbase.setDriverCustomFieldValues(driverPublicId, payload);
    } catch (error) {
      // ⚠️ **Une définition supprimée en amont laisse un uuid mort dans le
      // cache, et l'écriture échoue alors définitivement** — jusqu'au prochain
      // redémarrage. Constaté le 02/08/2026 : une définition retirée pendant
      // une mise au point a fait échouer chaque enregistrement suivant, avec un
      // `400 « Error occurred while trying to update a driver »` qui n'aide en
      // rien à le comprendre.
      //
      // Le cas n'est pas de laboratoire : un opérateur peut supprimer un champ
      // depuis la console. On oublie donc ce qu'on croyait savoir et on
      // réessaie **une** fois — au-delà, l'échec est réel et doit remonter.
      this.logger.warn(
        `Écriture de la zone refusée pour ${driverPublicId} (${error?.message}) — `
          + 'cache des définitions vidé, seconde tentative',
      );
      this.cache.delete(driverUuid);
      const fresh = await this.definitionsFor(driverUuid);
      const retry = payload
        .map((entry) => {
          const name = [...definitions.entries()].find(([, uuid]) => uuid === entry.custom_field_uuid)?.[0];
          const uuid = name ? fresh.get(name) : undefined;
          return uuid ? { ...entry, custom_field_uuid: uuid } : null;
        })
        .filter((e): e is NonNullable<typeof e> => e != null);
      if (!retry.length) throw error;
      await this.fleetbase.setDriverCustomFieldValues(driverPublicId, retry);
    }
  }

  /**
   * Les définitions attachées à ce conducteur, créées si elles manquent.
   *
   * ⚠️ Attachées **au conducteur**, pas à une configuration partagée : la
   * relation `customFields()` du modèle filtre sur `subject_uuid`. Il y a donc
   * deux définitions par conducteur — coût connu et assumé, c'est ce que le
   * modèle impose.
   */
  private async definitionsFor(driverUuid: string): Promise<Map<string, string>> {
    const cached = this.cache.get(driverUuid);
    if (cached) return cached;

    const known = new Map<string, string>();
    try {
      const existing = await this.fleetbase.listCustomFields(driverUuid);
      const list = existing?.custom_fields ?? existing?.data ?? existing ?? [];
      if (Array.isArray(list)) {
        for (const field of list) {
          if (typeof field?.name === 'string' && field?.uuid) known.set(field.name, field.uuid);
        }
      }

      for (const definition of DRIVER_ZONE_FIELDS) {
        if (known.has(definition.name)) continue;
        // ⚠️ La réponse porte la définition sous `custom_field`, PAS sous
        // `data` : lire la mauvaise clé faisait conclure à un échec sur une
        // création parfaitement réussie (mesuré le 02/08/2026).
        const created = await this.fleetbase.createCustomField({
          label: definition.label,
          name: definition.name,
          type: definition.type,
          subject_uuid: driverUuid,
          subject_type: 'driver',
          help_text: definition.helpText,
          editable: true,
          required: false,
        });
        const uuid = created?.custom_field?.uuid ?? created?.data?.uuid ?? created?.uuid;
        if (uuid) known.set(definition.name, uuid);
      }
    } catch (error) {
      this.logger.warn(
        `Provisionnement des champs de zone impossible pour ${driverUuid} : ${error?.message}`,
      );
    }

    if (known.size) this.cache.set(driverUuid, known);
    return known;
  }
}
