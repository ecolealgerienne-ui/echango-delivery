import { Module } from '@nestjs/common';
import { FlotteController } from './flotte.controller';
import { FlotteService } from './flotte.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { PricingService } from '../common/pricing/pricing.service';
import { OrderCreationHelpers } from '../common/orders/order-creation.helpers';

@Module({
  imports: [FleetbaseModule],
  controllers: [FlotteController],
  providers: [FlotteService, PricingService, OrderCreationHelpers],
})
export class FlotteModule {}
