import { Controller, Get } from '@nestjs/common';
import { PrismaService } from '../database/prisma.service';
import { Public } from '../common/decorators/public.decorator';

/**
 * Sonde de disponibilité.
 *
 * Le `HEALTHCHECK` du Dockerfile interrogeait déjà `/health`, route qui
 * n'existait pas : le conteneur de production aurait été marqué `unhealthy` en
 * permanence, et redémarré en boucle selon l'orchestrateur (revue archi #13).
 *
 * La sonde vérifie la base — une dépendance sans laquelle le service ne peut
 * rien faire. Fleetbase n'est délibérément PAS vérifié : son indisponibilité
 * dégrade le service sans le rendre inutile (les commandes en cache restent
 * lisibles), et faire redémarrer le BFF parce qu'un tiers est tombé ne
 * réparerait rien.
 */
@Controller('health')
export class HealthController {
  constructor(private readonly prisma: PrismaService) {}

  @Public()
  @Get()
  async check() {
    await this.prisma.$queryRaw`SELECT 1`;

    // ── La fraîcheur du réconciliateur, enfin LUE ────────────────────────────
    //
    // `Order.lastSyncedAt` était écrite deux fois par tour et **lue nulle part**
    // (revue du 01/08/2026, A7), sous un commentaire promettant de « distinguer
    // *rien n'a bougé* de *personne ne regarde* ». Personne ne posait la
    // question, donc un réconciliateur arrêté restait indiscernable d'une
    // commande stable — et c'est lui qui porte toute la chaîne de notification
    // du commerçant, Fleetbase n'appelant jamais le BFF.
    //
    // Deux issues possibles pour un champ sans lecteur : le supprimer, ou lui
    // donner le lecteur qu'il annonce (règle 9). Ici le second, parce que le
    // besoin est réel et qu'il tient en une requête.
    const latest = await this.prisma.order.findFirst({
      where: { lastSyncedAt: { not: null } },
      orderBy: { lastSyncedAt: 'desc' },
      select: { lastSyncedAt: true },
    });

    return {
      status: 'ok',
      timestamp: new Date().toISOString(),
      // `null` et non « jamais » : sur une installation neuve, aucune commande
      // n'a encore été réconciliée, et ce n'est pas une panne. Le distinguer
      // d'un âge nul est tout l'intérêt (règle 10).
      reconciler_last_run: latest?.lastSyncedAt?.toISOString() ?? null,
      reconciler_age_seconds: latest?.lastSyncedAt
        ? Math.round((Date.now() - latest.lastSyncedAt.getTime()) / 1000)
        : null,
    };
  }
}
