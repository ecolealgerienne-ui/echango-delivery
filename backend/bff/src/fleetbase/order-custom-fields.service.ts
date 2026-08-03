import { Injectable, Logger } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import {
  ORDER_CUSTOM_FIELDS,
  customFieldName,
  encodeCustomFieldValue,
  readOrderCustomFields,
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
   * Renvoie une carte **vide** en cas d'échec plutôt que de lever, et ce n'est
   * pas une tolérance : c'est l'appelant qui décide. `assertCustomFieldsComplete()`
   * refusera la création, parce qu'une livraison dont les montants ne sont pas
   * stockés durablement paraît normale et ne se révèle qu'à la porte du
   * destinataire (décision produit, 30/07/2026).
   *
   * Lever ici mélangerait « Fleetbase est injoignable » et « le catalogue est
   * incomplet » dans une seule exception, alors que le refus doit nommer la
   * seconde.
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
            + 'les créations de commande seront refusées tant que ce point n\'est pas rétabli',
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
      // ⚠️ Le sujet est revérifié en mémoire, alors que `?subject_uuid=` est un
      // filtre réel (`subject_uuid` est dans le `$fillable` de `CustomField`,
      // et `applyOptimizedFilters()` applique tout filtre fillable).
      //
      // La garde reste, parce que le mode d'échec sans elle est le pire
      // possible : un filtre qui cesserait d'être honoré — renommage amont,
      // régression — renverrait les champs de **toutes** les configurations, et
      // un champ nommé `price` sur une autre configuration serait pris pour le
      // nôtre. On écrirait alors des montants sur les définitions de quelqu'un
      // d'autre, sans la moindre erreur. Avec la garde, le pire cas est une
      // carte vide, donc un repli sur `meta`.
      if (field?.subject_uuid && field.subject_uuid !== orderConfigUuid) continue;
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
        // On continue la boucle malgré l'échec : le log doit nommer TOUS les
        // champs fautifs, pas seulement le premier. Sans ça, un catalogue
        // cassé se corrige à l'aveugle, un champ par redémarrage.
        //
        // La commande sera refusée de toute façon — `assertCustomFieldsComplete()`
        // compare ce qui devait être écrit à ce qui a une définition.
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

      const existing = groups.find(
        (g: any) =>
          g?.name === 'Echango' && (!g?.owner_uuid || g.owner_uuid === orderConfigUuid),
      );
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

  /**
   * Écrit des valeurs sur une commande **déjà créée**.
   *
   * Sert à consigner ce qui s'est passé à la porte au moment de la clôture.
   * Rend le nombre de valeurs écrites, pour que l'appelant puisse refuser
   * plutôt que de clôturer une livraison dont l'encaissement n'est nulle part.
   *
   * ⚠️ **Ne rend jamais un succès muet sur zéro valeur.** Si le catalogue est
   * incomplet — définition absente, Fleetbase injoignable au provisionnement —
   * `valuesFor` rend une liste vide, et écrire une liste vide serait un appel
   * réussi qui n'enregistre rien. C'est précisément la forme de panne que la
   * règle 10 interdit : un défaut sans valeur par défaut. L'appelant reçoit 0
   * et doit en faire quelque chose.
   */
  /**
   * Ajoute un élément à une liste portée par une commande.
   *
   * Sert aux refus et aux échecs de livraison, qui s'accumulent : ce ne sont
   * pas des valeurs qu'on remplace mais des faits qu'on empile.
   *
   * ⚠️ **Lire-modifier-écrire, donc NON atomique — et la fenêtre se nomme
   * (règle 2).** Deux transporteurs qui refusent la *même* course diffusée dans
   * le même souffle peuvent voir un refus écrasé par l'autre. Ce n'est pas
   * théorique sur une course en diffusion large.
   *
   * **Ce que ça coûte quand ça arrive** : la course réapparaît une fois dans la
   * liste de celui dont le refus s'est perdu. Il la refuse à nouveau. C'est un
   * désagrément, pas une perte — aucune décision, aucun argent, aucune
   * livraison n'en dépend.
   *
   * **Pourquoi on l'accepte plutôt que de garder une table** : la table
   * garantissait l'unicité mais rendait le refus **invisible depuis la
   * console**, donc invisible à l'opérateur qui cherche pourquoi une course ne
   * part pas. Une garantie parfaite sur une donnée que personne ne peut lire
   * vaut moins qu'une garantie imparfaite sur une donnée qui explique un
   * blocage.
   *
   * ⚠️ **`dedupe` est obligatoire, et ce n'est pas une commodité** : sans lui,
   * un transporteur qui refuse deux fois — reprise après échec réseau —
   * empilerait deux entrées, et le compte des refus mentirait à l'opérateur.
   * La table portait un `@@unique` ; ici c'est cette fonction qui le tient.
   */
  async appendToOrderList(
    orderId: string,
    order: any,
    key: string,
    element: Record<string, any>,
    dedupe: (existing: Record<string, any>) => boolean,
  ): Promise<number> {
    const current = readOrderCustomFields(order)[key];
    const liste: Record<string, any>[] = Array.isArray(current) ? current : [];

    const suivante = [...liste.filter((e) => !dedupe(e)), element];
    return this.writeToOrder(orderId, { [key]: suivante });
  }

  async writeToOrder(
    orderId: string,
    patch: Record<string, any>,
  ): Promise<number> {
    const orderConfigUuid = await this.fleetbaseClient.getDefaultOrderConfigUuid();
    const values = await this.valuesFor(orderConfigUuid, patch);
    if (!values.length) return 0;

    await this.fleetbaseClient.setOrderCustomFieldValues(orderId, values);
    return values.length;
  }
}
