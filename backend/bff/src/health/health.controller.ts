import { Controller, Get } from '@nestjs/common';
import { PrismaService } from '../database/prisma.service';
import { FleetbaseApiClient } from '../fleetbase/fleetbase-api.client';
import { GeocodingService } from '../common/geocoding/geocoding.service';
import { Public } from '../common/decorators/public.decorator';

/**
 * Sonde de disponibilité.
 *
 * Le `HEALTHCHECK` du Dockerfile interrogeait déjà `/health`, route qui
 * n'existait pas : le conteneur de production aurait été marqué `unhealthy` en
 * permanence, et redémarré en boucle selon l'orchestrateur (revue archi #13).
 *
 * La sonde vérifie la base — une dépendance sans laquelle le service ne peut
 * rien faire : si `SELECT 1` échoue, la route échoue, et l'orchestrateur a
 * raison de redémarrer.
 *
 * ── Fleetbase est RAPPORTÉ, jamais une cause d'échec (corrigé le 04/08/2026) ──
 *
 * Son indisponibilité dégrade le service sans le rendre inutile (le cache reste
 * lisible), et redémarrer le BFF parce qu'un tiers est tombé ne réparerait rien
 * — donc la sonde ne DOIT PAS échouer sur Fleetbase. Mais l'ignorer entièrement
 * était l'excès inverse : derrière un répartiteur de charge, `/health` à 200 en
 * dépit d'un amont à terre continue d'envoyer du trafic sur un BFF qui ne peut
 * pas servir. La bonne forme, retenue ici, est de **rapporter l'état de la
 * dépendance sans échouer** (`docs/status_v1.md`, « /health ne peut pas
 * échouer ») : `status: ok` tant que la base répond, et un bloc `dependencies`
 * que le déploiement lit pour décider — retirer l'instance du pool, alerter —
 * sans provoquer de boucle de redémarrage.
 */
@Controller('health')
export class HealthController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly fleetbase: FleetbaseApiClient,
    private readonly geocoding: GeocodingService,
  ) {}

  @Public()
  @Get()
  async check() {
    await this.prisma.$queryRaw`SELECT 1`;

    // Sondes courtes, qui ne lèvent jamais : un amont à terre ⇒
    // `reachable: false`, pas un `/health` en échec.
    const [fleetbase, geo] = await Promise.all([
      this.fleetbase.ping(),
      // echango-geo : indispensable aux routes /commercant/geocodage*, mais sa
      // panne ne rend pas le BFF inutile (commandes, dispatch, carnet
      // d'adresses continuent). Rapportée, comme Fleetbase.
      this.geocoding.ping(),
    ]);

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
      // Les dépendances amont, rapportées sans jamais faire échouer la sonde.
      // Le déploiement lit `reachable` pour décider ; `status` reste `ok`.
      dependencies: { fleetbase, geo },
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
