import { Module } from '@nestjs/common';
import { CommerçantController } from './commercant.controller';
import { CommerçantService } from './commercant.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { GeocodingService } from '../common/geocoding/geocoding.service';
import { PricingService } from '../common/pricing/pricing.service';
import { OrderCreationHelpers } from '../common/orders/order-creation.helpers';

@Module({
  imports: [FleetbaseModule],
  controllers: [CommerçantController],
  providers: [
    CommerçantService,
    GeocodingService,
    PricingService,
    OrderCreationHelpers,
  ],
})
export class CommerçantModule {}
