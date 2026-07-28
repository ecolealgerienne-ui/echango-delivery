import { Injectable, Logger } from '@nestjs/common';
import { PrismaService } from '../../database/prisma.service';

export interface AuditEntry {
  actorType?: string | null;
  actorId?: string | null;
  /** Verbe métier, en notation pointée : `order.access`, `proof.access`. */
  action: string;
  resourceType: string;
  resourceId?: string | null;
  /** Ce qui a motivé le refus, en clair. Jamais de donnée personnelle. */
  reason?: string;
  details?: Record<string, unknown>;
}

/**
 * Écriture de la piste d'audit.
 *
 * Ce qui est journalisé, et pourquoi ce périmètre : les **refus** d'accès. Sur
 * un système dont tout le cloisonnement est applicatif — Fleetbase ignore
 * silencieusement les filtres de requête, donc rien ne protège en dehors du
 * code du BFF — une tentative d'accès à la ressource d'autrui est le signal
 * qui compte. Un `logger.warn` ne suffisait pas : non structuré, non
 * requêtable, perdu à la rotation (revue F14).
 *
 * Les succès ordinaires ne sont pas journalisés ici : ils sont déjà dans les
 * journaux d'accès HTTP, et les écrire doublerait le volume sans rien ajouter.
 */
@Injectable()
export class AuditService {
  private readonly logger = new Logger(AuditService.name);

  constructor(private readonly prisma: PrismaService) {}

  /** Refus d'accès : la tentative a été bloquée. */
  denied(entry: AuditEntry): void {
    this.write({ ...entry, status: 'failure' });
  }

  /** Action sensible ayant abouti — révocation, émission d'invitation. */
  succeeded(entry: AuditEntry): void {
    this.write({ ...entry, status: 'success' });
  }

  /**
   * Écriture au fil de l'eau, sans attendre.
   *
   * L'appelant est dans le chemin d'une requête qu'il s'apprête à refuser :
   * le faire attendre une écriture en base retarderait la réponse sans rien
   * apporter, et une base d'audit indisponible ne doit pas transformer un 403
   * propre en 500.
   *
   * En contrepartie, un échec d'écriture est journalisé en `error` — c'est le
   * seul cas où la disparition d'une trace doit se voir. Sans ce garde-fou, une
   * table absente ferait taire l'audit sans que personne ne le remarque.
   */
  private write(entry: AuditEntry & { status: string }): void {
    const { actorType, actorId, action, resourceType, resourceId, reason, details, status } = entry;

    void this.prisma.auditLog
      .create({
        data: {
          actorType: actorType ?? null,
          actorId: actorId ?? null,
          action,
          resourceType,
          resourceId: resourceId ?? null,
          status,
          errorMessage: reason ?? null,
          details: details ? JSON.stringify(details) : null,
        },
      })
      .catch((error: any) => {
        this.logger.error(
          `Audit non écrit (${action} / ${status}) : ${error.message}. ` +
            'Si le message mentionne AuditLog, lancer npm run prisma:migrate.',
        );
      });
  }
}
