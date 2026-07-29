import { Controller, Post, Body, Headers, HttpCode, Logger } from '@nestjs/common';
import { Public } from '../common/decorators/public.decorator';

/**
 * Réception des évènements Fleetbase — **étage d'observation, pas encore de
 * production** (contrôle V8 de `docs/plan_migration_fleetbase.md`).
 *
 * ── Ce que fait cet endpoint, et ce qu'il ne fait pas ────────────────────────
 *
 * Il journalise intégralement ce que Fleetbase envoie : en-têtes et corps. Rien
 * d'autre. Aucune action métier n'en découle, et **aucune signature n'est
 * vérifiée**.
 *
 * C'est délibéré et temporaire. Le Lot 5 doit construire la vraie réception —
 * vérification de signature comprise — et il ne peut pas le faire sur des
 * suppositions : nous ne connaissons ni le nom de l'en-tête de signature, ni
 * l'algorithme, ni la forme exacte du corps, ni le vocabulaire réel des
 * évènements. Les inventer serait répéter l'erreur de `facilitator_uuid`, où un
 * nom supposé a tenu lieu de fait pendant plusieurs jours
 * (`docs/architecture_bff_fleetbase.md` §4.3).
 *
 * On observe donc d'abord, on implémente ensuite.
 *
 * ⚠️ **À ne jamais déployer en l'état.** Sans vérification de signature, cette
 * route accepte n'importe quel appelant. Elle est inoffensive tant qu'elle ne
 * fait qu'écrire dans le journal, et elle cesse de l'être à la seconde où le
 * Lot 5 lui fera modifier un état. L'ordre à respecter est donc : vérifier la
 * signature **avant** de brancher le moindre effet.
 *
 * ⚠️ Le corps est journalisé en entier, y compris les données personnelles des
 * destinataires. Acceptable sur une instance de développement, à retirer avant
 * toute installation servant de vraies livraisons.
 */
@Controller('webhooks')
export class WebhooksController {
  private readonly logger = new Logger('FleetbaseWebhook');

  @Public()
  @Post('fleetbase')
  // 200 explicite : la plupart des émetteurs de webhooks traitent tout code
  // hors 2xx comme un échec et réessaient. Un 201 par défaut passerait, mais
  // autant ne pas dépendre de leur tolérance.
  @HttpCode(200)
  receive(@Headers() headers: Record<string, string>, @Body() body: any) {
    // Les en-têtes d'abord : c'est là que se trouve la signature, et c'est la
    // seule information que le Lot 5 ne peut pas deviner.
    const interesting = Object.entries(headers).filter(([name]) =>
      /signature|fleetbase|webhook|event|hook|timestamp|x-/i.test(name),
    );

    this.logger.log(
      `── Évènement reçu ──\n` +
        `En-têtes retenus :\n${interesting.map(([k, v]) => `  ${k}: ${v}`).join('\n')}\n` +
        `Type annoncé : ${body?.event ?? body?.type ?? '(aucun champ event/type)'}\n` +
        `Clés de premier niveau : ${Object.keys(body ?? {}).join(', ') || '(corps vide)'}\n` +
        `Corps complet :\n${JSON.stringify(body, null, 2)}`,
    );

    // Toujours 200, même sur un corps inattendu : à ce stade on cherche à
    // apprendre ce que Fleetbase envoie, et un rejet le ferait réessayer en
    // boucle sans rien nous apprendre de plus.
    return { received: true };
  }
}
