import { Injectable, Logger } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import {
  ORDER_CUSTOM_FIELDS,
  customFieldName,
  encodeCustomFieldValue,
} from './order-custom-fields';

/**
 * Déclare les champs personnalisés d'Echango sur l'`OrderConfig`, et traduit
 * entre notre vocabulaire (`meta`) et le leur (`custom_field_values`).
 *
 * ── Pourquoi un provisionnement au lieu d'une configuration manuelle ────────
 *
 * Écrire une valeur exige l'`uuid` d'une **définition** de champ. Demander à
 * un admin de créer treize champs à la main dans la console avant la première
 * commande, c'est garantir qu'un jour l'un d'eux manquera — et un champ
 * manquant ne lève pas d'erreur, il fait silencieusement disparaître un
 * montant. Le BFF les déclare donc lui-même, à la première commande, et
 * n'ajoute que ce qui manque.
 *
 * ── Ce que ce service ne fait PAS ───────────────────────────────────────────
 *
 * Il ne supprime rien et ne renomme rien. Un admin qui ajoute ses propres
 * champs sur la même configuration les garde ; ceux du catalogue ne sont
 * jamais recréés s'ils existent déjà, sous quelque libellé qu'un admin leur ait
 * donné entre-temps — le rattachement se fait par `name`, que le formulaire de
 * la console n'expose pas, et non par le libellé, qu'il expose.
 */
@Injectable()
export class OrderCustomFieldsService {
  private readonly logger = new Logger(OrderCustomFieldsService.name);

  /**
   * `orderConfigUuid` → (`name` du champ → `uuid` de la définition).
   *
   * En mémoire, volontairement : c'est un cache jetable au sens de la règle 1
   * du projet — le perdre coûte une relecture, jamais une donnée. Il évite
   * surtout de relire le catalogue à chaque création de commande.
   */
  private readonly cache = new Map<string, Map<string, string>>();

  /** Provisionnements en cours, pour que deux commandes simultanées n'en lancent pas deux. */
  private readonly inFlight = new Map<string, Promise<Map<string, string>>>();

  constructor(private readonly fleetbaseClient: FleetbaseApiClient) {}

  /**
   * Les définitions du catalogue, créées si besoin.
   *
   * Renvoie une carte vide en cas d'échec plutôt que de lever : une commande
   * doit pouvoir se créer même si le provisionnement échoue. Elle retombera
   * alors sur `meta` et `specMeta`, c'est-à-dire sur le comportement d'avant
   * cette migration — dégradé, pas cassé.
   */
  async definitionsFor(orderConfigUuid: string): Promise<Map<string, string>> {
    const cached = this.cache.get(orderConfigUuid);
    if (cached) return cached;

    const pending = this.inFlight.get(orderConfigUuid);
    if (pending) return pending;

    const task = this.provision(orderConfigUuid)
      .then((map) => {
        // Mis en cache seulement si complet : un provisionnement partiel doit
        // être retenté au prochain appel, sinon un champ manquant le resterait
        // pour toute la durée de vie du processus.
        if (map.size === ORDER_CUSTOM_FIELDS.length) this.cache.set(orderConfigUuid, map);
        return map;
      })
      .catch((error: any) => {
        this.logger.error(
          `Champs personnalisés indisponibles pour ${orderConfigUuid} : ${error.message} — `
            + 'la commande sera créée sans eux (repli sur meta)',
        );
        return new Map<string, string>();
      })
      .finally(() => this.inFlight.delete(orderConfigUuid));

    this.inFlight.set(orderConfigUuid, task);
    return task;
  }

  private async provision(orderConfigUuid: string): Promise<Map<string, string>> {
    const response = await this.fleetbaseClient.listCustomFields(orderConfigUuid);
    const existing = this.fleetbaseClient.extractCollection(response, 'custom_fields');

    const byName = new Map<string, string>();
    for (const field of existing) {
      if (field?.name && field?.uuid) byName.set(field.name, field.uuid);
    }

    const missing = ORDER_CUSTOM_FIELDS.filter((f) => !byName.has(customFieldName(f.key)));
    if (!missing.length) return byName;

    const categoryUuid = await this.groupFor(orderConfigUuid);

    this.logger.log(
      `Déclaration de ${missing.length} champ(s) personnalisé(s) sur la configuration `
        + `${orderConfigUuid} : ${missing.map((f) => f.key).join(', ')}`,
    );

    for (const [index, field] of missing.entries()) {
      try {
        const created = await this.fleetbaseClient.createCustomField({
          // Le libellé EST la clé de lecture côté Fleetbase
          // (`Str::snake(Str::lower($label))`), donc il reproduit nos clés
          // actuelles à l'identique : le contrat servi aux applications ne
          // bouge pas. L'explication en français va dans `description`.
          label: field.key,
          name: customFieldName(field.key),
          type: 'text',
          subject_uuid: orderConfigUuid,
          subject_type: 'order-config',
          ...(categoryUuid ? { category_uuid: categoryUuid } : {}),
          description: field.description,
          required: false,
          editable: true,
          order: index,
        });

        const uuid = created?.custom_field?.uuid ?? created?.uuid;
        if (uuid) byName.set(customFieldName(field.key), uuid);
      } catch (error: any) {
        // Un champ manquant n'empêche pas les autres : mieux vaut douze
        // valeurs protégées et une qui retombe sur `meta` que rien du tout.
        const detail =
          error.response?.data?.errors?.[0]
          || error.response?.data?.error
          || error.message;
        this.logger.error(`Champ personnalisé « ${field.key} » non déclaré : ${detail}`);
      }
    }

    return byName;
  }

  /** Le groupe « Echango » de la configuration, créé au besoin. */
  private async groupFor(orderConfigUuid: string): Promise<string | undefined> {
    try {
      const response = await this.fleetbaseClient.listCustomFieldGroups(orderConfigUuid);
      const groups = this.fleetbaseClient.extractCollection(response, 'categories');

      const existing = groups.find((g: any) => g?.name === 'Echango');
      if (existing?.uuid) return existing.uuid;

      const created = await this.fleetbaseClient.createCustomFieldGroup(orderConfigUuid, 'Echango');
      return created?.category?.uuid ?? created?.uuid;
    } catch (error: any) {
      // Sans groupe, les champs existent quand même et restent lisibles par
      // l'API ; seul leur affichage dans la console est incertain. Ça ne
      // justifie pas de refuser une livraison.
      this.logger.warn(`Groupe de champs personnalisés non créé : ${error.message}`);
      return undefined;
    }
  }

  /**
   * Traduit notre `meta` en valeurs de champs personnalisés.
   *
   * Les clés absentes du catalogue — `pricing_inputs` — restent dans `meta` :
   * ce sont des données de calibration, pas d'exploitation.
   */
  async valuesFor(
    orderConfigUuid: string,
    meta: Record<string, any> | undefined,
  ): Promise<{ custom_field_uuid: string; value: any; value_type: string }[]> {
    if (!meta) return [];

    const definitions = await this.definitionsFor(orderConfigUuid);
    if (!definitions.size) return [];

    const values: { custom_field_uuid: string; value: any; value_type: string }[] = [];

    for (const field of ORDER_CUSTOM_FIELDS) {
      const raw = meta[field.key];
      if (raw === undefined || raw === null) continue;

      const uuid = definitions.get(customFieldName(field.key));
      if (!uuid) continue;

      const { value, value_type } = encodeCustomFieldValue(field, raw);
      values.push({ custom_field_uuid: uuid, value, value_type });
    }

    return values;
  }

}
