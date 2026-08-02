import { Module } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import { OrderCustomFieldsService } from './order-custom-fields.service';
import { DriverZoneService } from './driver-zone.service';

@Module({
  providers: [FleetbaseApiClient, OrderCustomFieldsService, DriverZoneService],
  exports: [FleetbaseApiClient, OrderCustomFieldsService, DriverZoneService],
})
export class FleetbaseModule {}
