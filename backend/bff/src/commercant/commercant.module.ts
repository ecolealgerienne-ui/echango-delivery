import { Module } from '@nestjs/common';
import { CommerçantController } from './commercant.controller';
import { CommerçantService } from './commercant.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { GeocodingModule } from '../common/geocoding/geocoding.module';
import { PricingService } from '../common/pricing/pricing.service';

@Module({
  imports: [FleetbaseModule, GeocodingModule],
  controllers: [CommerçantController],
  providers: [CommerçantService, PricingService],
})
export class CommerçantModule {}
