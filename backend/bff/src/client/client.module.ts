import { Module } from '@nestjs/common';
import { ClientController } from './client.controller';
import { ClientPublicController } from './client-public.controller';
import { ClientService } from './client.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

/**
 * Fiche client géolocalisée — `docs/specs_localisation_client_et_optimisation_parcours.md` §1.
 *
 * `FleetbaseModule` est importé pour `ResourceLockService` (verrou de fiche),
 * pas pour parler à Fleetbase : cette fonctionnalité ne touche que Postgres.
 * `PrismaService` n'a pas besoin d'être importé : `PrismaModule` est
 * `@Global()`.
 */
@Module({
  imports: [FleetbaseModule],
  controllers: [ClientController, ClientPublicController],
  providers: [ClientService],
})
export class ClientModule {}
