import { Module } from '@nestjs/common';
import { CommerçantController } from './commercant.controller';
import { CommerçantService } from './commercant.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { GeocodingService } from '../common/geocoding/geocoding.service';
import { PricingService } from '../common/pricing/pricing.service';

@Module({
  imports: [FleetbaseModule],
  controllers: [CommerçantController],
  providers: [CommerçantService, GeocodingService, PricingService],
})
export class CommerçantModule {}
