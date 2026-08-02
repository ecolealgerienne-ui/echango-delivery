import { Injectable, Logger } from '@nestjs/common';
import { notFound } from '../common/errors/http-errors';
import { PrismaService } from '../database/prisma.service';

/**
 * Évènements notifiés au commerçant.
 *
 * Liste fermée et volontairement courte : une notification qui n'appelle
 * aucune décision est du bruit, et le bruit fait désactiver les notifications
 * — après quoi les trois qui comptaient ne passent plus non plus.
 *
 * Ce qui justifie une entrée ici : le commerçant a quelque chose à faire, ou à
 * dire à son propre client. « Un transporteur arrive » se répercute au client
 * qui attend ; « la livraison a échoué » demande de rappeler ; « le
 * transporteur s'est désisté » explique une attente qui, sans ça, ressemble à
 * une panne.
 *
 * Ce qui n'y figure pas, délibérément : les états intermédiaires du dispatch
 * (`dispatched`, `enroute`). Ils changent souvent, n'appellent aucune action,
 * et le suivi de la commande les montre déjà à qui les cherche.
 */
export const NOTIFICATION_TYPES = [
  /** Un transporteur a pris la course. */
  'order.assigned',
  /** Le transporteur assigné s'est désisté : la course repart au réseau. */
  'order.released',
  /** Livraison effectuée. */
  'order.completed',
  /** Commande annulée (par le commerçant, ou côté opérateur). */
  'order.canceled',
  /** Le transporteur a signalé un échec de livraison. */
  'order.failed',
  /** Le transporteur a encaissé le montant dû à la livraison. */
  'cash.collected',
  /** Le montant perçu diffère de celui annoncé — le commerçant doit le savoir
   *  tout de suite, pas au moment de la remise, quand la discussion sera plus
   *  difficile. */
  'cash.discrepancy',
  /** Un transporteur déclare avoir remis des espèces : sans cette notification,
   *  la remise attendrait une confirmation que personne ne sait devoir donner. */
  'cash.remittance_declared',
] as const;

export type NotificationType = (typeof NOTIFICATION_TYPES)[number];

export interface NotifyInput {
  merchantId: string;
  type: NotificationType;
  title: string;
  body: string;
  fleetbaseOrderUuid?: string | null;
  orderId?: string | null;
  /**
   * Les variables du message, servies **à part** du message.
   *
   * L'application traduit depuis `type` (règle 4) ; les cuire dans `body`
   * rendait la phrase intraduisible sans la redécouper.
   */
  data?: Record<string, string | null> | null;
}

/**
 * Journal de notifications du commerçant.
 *
 * ── Pourquoi un journal en base plutôt qu'un envoi direct ───────────────────
 *
 * Un push est un message sans accusé de réception utile : téléphone éteint,
 * jeton périmé après réinstallation, notification balayée sans être lue. Si
 * l'envoi était le seul support, l'information disparaîtrait avec lui — et
 * c'est exactement l'information qu'un commerçant vient chercher quand il
 * rouvre l'application (« est-ce que quelqu'un a pris ma course ? »).
 *
 * Le journal est donc la source de vérité, et le push — quand il existera — un
 * simple accélérateur.
 *
 * ⚠️ **L'envoi push n'est pas branché** (29/07/2026). Joindre un commerçant
 * demande un credential serveur Firebase absent de ce déploiement, et le push
 * natif de Fleetbase ne peut pas servir : il route par `UserDevice`, donc par
 * un `User` Fleetbase, que le commerçant n'a délibérément pas
 * (docs/specs_bff.md). Les jetons d'appareil sont bien collectés — il ne
 * manque que l'expéditeur. L'application relève le journal en interrogeant le
 * serveur.
 */
@Injectable()
export class NotificationsService {
  private readonly logger = new Logger(NotificationsService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Enregistre une notification.
   *
   * Ne lève jamais : tous les appelants sont dans le chemin d'une opération qui
   * a déjà réussi — un échec de livraison signalé, une course refusée. Faire
   * échouer l'opération parce que sa notification n'a pas pu s'écrire
   * inverserait la hiérarchie des importances. L'échec est journalisé en
   * `error`, seul cas où une trace manquante doit se voir.
   */
  async notify(input: NotifyInput): Promise<void> {
    try {
      await this.prisma.merchantNotification.create({
        data: {
          merchantId: input.merchantId,
          type: input.type,
          title: input.title,
          body: input.body,
          fleetbaseOrderUuid: input.fleetbaseOrderUuid ?? null,
          orderId: input.orderId ?? null,
          data: input.data ?? undefined,
        },
      });
    } catch (error: any) {
      this.logger.error(
        `Notification non écrite (${input.type}) : ${error.message}. ` +
          'Si le message mentionne MerchantNotification, lancer npm run prisma:migrate.',
      );
    }
  }

  /**
   * Notifie le commerçant propriétaire d'une commande Fleetbase.
   *
   * Le rattachement passe par le cache local. La référence à §2.8 (« les
   * filtres de requête sont ignorés en silence ») est corrigée depuis le
   * 29/07/2026 — c'était une erreur de nom de paramètre. Une commande inconnue du
   * cache n'appartient à aucun commerçant Echango : rien à notifier, et rien
   * d'anormal — l'opérateur peut créer des commandes depuis la console.
   */
  async notifyOrderOwner(
    fleetbaseOrderUuid: string,
    notification: Omit<NotifyInput, 'merchantId' | 'fleetbaseOrderUuid' | 'orderId'>,
  ): Promise<void> {
    const order = await this.prisma.order.findFirst({
      where: { fleetbaseOrderId: fleetbaseOrderUuid },
      select: { id: true, merchantId: true },
    });

    if (!order) return;

    await this.notify({
      ...notification,
      merchantId: order.merchantId,
      orderId: order.id,
      fleetbaseOrderUuid,
    });
  }

  async list(merchantId: string, unreadOnly = false, limit = 50) {
    const notifications = await this.prisma.merchantNotification.findMany({
      where: { merchantId, ...(unreadOnly ? { readAt: null } : {}) },
      orderBy: { createdAt: 'desc' },
      take: Math.min(Math.max(limit, 1), 100),
    });

    const unread = await this.prisma.merchantNotification.count({
      where: { merchantId, readAt: null },
    });

    return {
      data: notifications.map((n: any) => ({
        id: n.id,
        type: n.type,
        // Servis en repli d'un `type` inconnu du client — jamais comme le
        // texte à afficher : ils sont en français dans le code serveur.
        title: n.title,
        body: n.body,
        data: n.data ?? null,
        // L'identifiant local, pas l'uuid Fleetbase : c'est celui que le
        // module commerçant sait résoudre, et il évite d'exposer l'amont.
        order_id: n.orderId,
        read: n.readAt !== null,
        created_at: n.createdAt.toISOString(),
      })),
      unread,
    };
  }

  /**
   * Marque une notification comme lue.
   *
   * `updateMany` avec le merchantId dans le filtre, et non `update` par id : un
   * `update` par identifiant seul permettrait de marquer lues les notifications
   * d'un autre commerçant. Anodin en apparence — mais c'est aussi un moyen de
   * confirmer l'existence d'un identifiant, et la discipline vaut mieux
   * uniforme que jugée cas par cas.
   */
  async markRead(merchantId: string, notificationId: string) {
    const { count } = await this.prisma.merchantNotification.updateMany({
      where: { id: notificationId, merchantId, readAt: null },
      data: { readAt: new Date() },
    });

    if (count === 0) {
      // Déjà lue ou inexistante : on ne distingue pas les deux, mais il faut
      // encore savoir si la notification appartient bien à ce commerçant.
      const exists = await this.prisma.merchantNotification.count({
        where: { id: notificationId, merchantId },
      });
      if (exists === 0) notFound('notification.not_found', 'Notification introuvable');
    }

    return { read: true };
  }

  async markAllRead(merchantId: string) {
    const { count } = await this.prisma.merchantNotification.updateMany({
      where: { merchantId, readAt: null },
      data: { readAt: new Date() },
    });
    return { read: count };
  }
}
