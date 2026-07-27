import { Module } from '@nestjs/common';
import { FleetbaseApiClient } from './fleetbase-api.client';

@Module({
  providers: [FleetbaseApiClient],
  exports: [FleetbaseApiClient],
})
export class FleetbaseModule {}
