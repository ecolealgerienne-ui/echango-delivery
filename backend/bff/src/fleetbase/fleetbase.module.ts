import { Module } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import { OrderCustomFieldsService } from './order-custom-fields.service';
import { DriverZoneService } from './driver-zone.service';
import { MerchantFavouritesService } from './merchant-favourites.service';
import { ResourceLockService } from '../common/concurrency/resource-lock.service';

@Module({
  providers: [
    FleetbaseApiClient,
    OrderCustomFieldsService,
    DriverZoneService,
    MerchantFavouritesService,
    ResourceLockService,
  ],
  exports: [
    FleetbaseApiClient,
    OrderCustomFieldsService,
    DriverZoneService,
    MerchantFavouritesService,
    // Exporté : `TransporteurService` (dans un module qui importe celui-ci) en a
    // besoin pour sérialiser l'affectation d'une course (`acceptOrder`).
    ResourceLockService,
  ],
})
export class FleetbaseModule {}
