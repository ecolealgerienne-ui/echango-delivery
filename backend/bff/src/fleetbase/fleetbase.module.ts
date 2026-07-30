import { Module } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';
import { OrderCustomFieldsService } from './order-custom-fields.service';

@Module({
  providers: [FleetbaseApiClient, OrderCustomFieldsService],
  exports: [FleetbaseApiClient, OrderCustomFieldsService],
})
export class FleetbaseModule {}
