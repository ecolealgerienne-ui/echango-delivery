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
    return { status: 'ok', timestamp: new Date().toISOString() };
  }
}
