import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { NotificationsService } from './notifications.service';

/** Statuts Fleetbase après lesquels plus rien ne bouge. */
const TERMINAL = ['completed', 'canceled', 'cancelled'];

/**
 * Rapproche périodiquement le cache local de l'état réel des commandes chez
 * Fleetbase, et notifie le commerçant de ce qui a changé.
 *
 * ── Pourquoi un scrutateur, et non des webhooks ─────────────────────────────
 *
 * Fleetbase n'appelle pas le BFF : rien, dans le flux normal, ne nous prévient
 * qu'un transporteur a pris une course. Les deux évènements qui intéressent le
 * commerçant surviennent d'ailleurs **hors** de nos routes — un driver peut
 * accepter depuis l'application, mais un opérateur peut aussi assigner depuis
 * la console Fleetbase, et le second cas ne traverse aucun de nos endpoints.
 * Un scrutateur voit les deux ; un déclenchement posé dans nos services n'en
 * verrait qu'un, et l'autre disparaîtrait en silence — le pire mode de panne,
 * puisqu'il ressemble à « rien ne s'est passé ».
 *
 * Fleetbase possède bien des webhooks, et c'est la bonne cible à l'échelle.
 * Ils supposent une URL joignable depuis Fleetbase, une vérification de
 * signature et un déploiement configuré : des prérequis de mise en production,
 * pas de développement. Le scrutateur fonctionne aujourd'hui, sans rien à
 * configurer, et le journal de notifications qu'il alimente ne changera pas
 * quand la source deviendra un webhook.
 *
 * ── Ce qu'il corrige au passage ─────────────────────────────────────────────
 *
 * `Order.status` était figé à sa valeur de création et n'a jamais été
 * resynchronisé (défaut relevé de longue date). Le tenir à jour ici en fait la
 * mémoire qu'il prétendait être, et c'est justement de cette mémoire que
 * viennent les transitions : sans un « avant », il n'y a pas d'évènement, juste
 * un état.
 *
 * ── Limites assumées ────────────────────────────────────────────────────────
 *
 * Un passage télécharge toutes les commandes de l'organisation. Tenable au
 * pilote, pas à l'échelle. Le motif invoqué — « Fleetbase ignore les filtres de
 * requête » — est faux depuis le 29/07/2026 : c'était une erreur de nom de
 * paramètre (`docs/architecture_bff_fleetbase.md` §4.3). La latence est celle
 * de l'intervalle : une minute par défaut.
 *
 * Les deux disparaissent avec les **webhooks**, qui restent la bonne réponse
 * ici — un filtre serveur ne dirait toujours pas *qu'un changement a eu lieu*,
 * et ce service existe pour détecter une transition, pas pour lire une liste
 * (§8.3 du même document).
 */
@Injectable()
export class OrderReconcilerService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(OrderReconcilerService.name);
  private timer?: NodeJS.Timeout;
  /** Un passage lent ne doit pas en déclencher un second par-dessus. */
  private running = false;

  constructor(
    private readonly prisma: PrismaService,
    private readonly fleetbaseClient: FleetbaseApiClient,
    private readonly notifications: NotificationsService,
    private readonly configService: ConfigService,
  ) {}

  onModuleInit() {
    if (this.configService.get('RECONCILER_ENABLED') === 'false') {
      this.logger.warn(
        'Réconciliateur désactivé (RECONCILER_ENABLED=false) — les commerçants ne seront ' +
          'notifiés ni de la prise en charge ni de la livraison de leurs commandes',
      );
      return;
    }

    const interval = this.intervalMs();
    this.logger.log(`Réconciliateur actif, un passage toutes les ${interval / 1000} s`);

    // `unref()` : ce minuteur ne doit pas à lui seul maintenir le processus en
    // vie. Sans lui, un arrêt propre attend la fin de l'intervalle.
    this.timer = setInterval(() => void this.runOnce(), interval);
    this.timer.unref?.();
  }

  onModuleDestroy() {
    if (this.timer) clearInterval(this.timer);
  }

  private intervalMs(): number {
    const configured = Number(this.configService.get('RECONCILER_INTERVAL_MS'));
    // Plancher à 10 s : en dessous, on télécharge la totalité des commandes
    // plus vite qu'on ne les traite, et les passages se chevauchent.
    return Number.isFinite(configured) && configured >= 10_000 ? configured : 60_000;
  }

  /**
   * Un passage. Public pour qu'un test ou un script puisse le déclencher sans
   * attendre l'intervalle.
   */
  async runOnce(): Promise<{ examined: number; changed: number }> {
    if (this.running) {
      this.logger.warn('Passage précédent encore en cours — celui-ci est sauté');
      return { examined: 0, changed: 0 };
    }
    this.running = true;

    try {
      const cached = await this.prisma.order.findMany({
        where: { status: { notIn: TERMINAL } },
      });

      if (!cached.length) return { examined: 0, changed: 0 };

      const live = await this.fleetbaseClient.fetchEveryOrder();
      const byUuid = new Map(live.map((o: any) => [o?.uuid, o]));

      let changed = 0;
      for (const row of cached) {
        const order = byUuid.get(row.fleetbaseOrderId);
        // Commande absente de Fleetbase : supprimée, ou appartenant à une autre
        // organisation. Rien à notifier — et surtout, ne pas conclure d'une
        // absence qu'elle est terminée : un appel manqué la ferait disparaître
        // définitivement du suivi.
        if (!order) continue;

        if (await this.reconcile(row, order)) changed++;
      }

      return { examined: cached.length, changed };
    } catch (error: any) {
      // Un passage raté n'est pas grave — le suivant rattrapera, puisque la
      // comparaison porte sur l'état et non sur un flux d'évènements. C'est le
      // principal mérite du scrutateur face au webhook.
      this.logger.warn(`Passage de réconciliation échoué : ${error.message}`);
      return { examined: 0, changed: 0 };
    } finally {
      this.running = false;
    }
  }

  /**
   * Compare une ligne de cache à son état amont, notifie, puis mémorise.
   *
   * L'ordre importe : la mémorisation vient **après** les notifications. Si
   * l'écriture échoue, le passage suivant reverra la même transition et
   * renotifiera — un doublon visible, préférable à un évènement perdu, qui lui
   * ne se rattrape jamais.
   */
  private async reconcile(row: any, order: any): Promise<boolean> {
    const status: string = order?.status ?? row.status;
    const driverUuid: string | null =
      order?.driver_assigned_uuid ?? order?.driver_assigned?.uuid ?? null;
    const driverName: string | null = order?.driver_assigned?.name ?? null;

    const statusChanged = status !== row.status;
    const driverChanged = driverUuid !== row.driverAssignedUuid;

    if (!statusChanged && !driverChanged) {
      await this.touch(row.id);
      return false;
    }

    const notify = (type: any, title: string, body: string) =>
      this.notifications.notify({
        merchantId: row.merchantId,
        orderId: row.id,
        fleetbaseOrderUuid: row.fleetbaseOrderId,
        type,
        title,
        body,
      });

    if (driverChanged) {
      if (driverUuid) {
        await notify(
          'order.assigned',
          'Livraison prise en charge',
          driverName
            ? `${driverName} a pris votre livraison ${row.trackingNumber ?? ''}`.trim()
            : 'Un transporteur a pris votre livraison',
        );
      } else if (!TERMINAL.includes(status)) {
        // Désassignation hors annulation : le transporteur s'est désisté. Le
        // dire évite que l'attente qui suit ressemble à une panne.
        await notify(
          'order.released',
          'Transporteur désisté',
          'Votre livraison a été proposée à nouveau aux transporteurs du réseau.',
        );
      }
    }

    if (statusChanged) {
      if (status === 'completed') {
        await notify('order.completed', 'Livraison effectuée', 'Votre livraison est arrivée à destination.');
      } else if (status === 'canceled' || status === 'cancelled') {
        await notify('order.canceled', 'Livraison annulée', 'Votre demande de livraison a été annulée.');
      }
    }

    await this.prisma.order.update({
      where: { id: row.id },
      data: {
        status,
        driverAssignedUuid: driverUuid,
        driverName,
        lastSyncedAt: new Date(),
      },
    });

    return true;
  }

  /**
   * Horodate un passage sans changement.
   *
   * Distingue « rien n'a bougé » de « personne ne regarde » : sans cette
   * marque, un réconciliateur arrêté est indiscernable d'une commande stable,
   * et la panne la plus probable de ce composant — il ne tourne plus — est
   * précisément celle qui ne produit aucun signal.
   */
  private async touch(id: string) {
    try {
      await this.prisma.order.update({
        where: { id },
        data: { lastSyncedAt: new Date() },
      });
    } catch {
      // Marque d'horodatage : son absence n'empêche rien de fonctionner.
    }
  }
}
