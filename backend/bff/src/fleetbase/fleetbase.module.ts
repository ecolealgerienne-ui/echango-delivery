import { Module } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import { OrderCustomFieldsService } from './order-custom-fields.service';
import { DriverZoneService } from './driver-zone.service';
import { MerchantFavouritesService } from './merchant-favourites.service';

@Module({
  providers: [
    FleetbaseApiClient,
    OrderCustomFieldsService,
    DriverZoneService,
    MerchantFavouritesService,
  ],
  exports: [
    FleetbaseApiClient,
    OrderCustomFieldsService,
    DriverZoneService,
    MerchantFavouritesService,
  ],
})
export class FleetbaseModule {}
