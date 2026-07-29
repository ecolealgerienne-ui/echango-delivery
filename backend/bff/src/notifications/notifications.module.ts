import { Global, Module } from '@nestjs/common';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { NotificationsService } from './notifications.service';
import { OrderReconcilerService } from './order-reconciler.service';

/**
 * Global, comme la piste d'audit : trois modules notifient (le transporteur
 * quand il signale un échec ou refuse une course, le commerçant à l'annulation,
 * le réconciliateur en continu), et un service qu'il faut penser à importer
 * module par module finit par manquer là où il compte.
 */
@Global()
@Module({
  imports: [FleetbaseModule],
  providers: [NotificationsService, OrderReconcilerService],
  exports: [NotificationsService, OrderReconcilerService],
})
export class NotificationsModule {}
