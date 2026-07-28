import { Module } from '@nestjs/common';
import { CommerçantController } from './commercant.controller';
import { CommerçantService } from './commercant.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

@Module({
  imports: [FleetbaseModule],
  controllers: [CommerçantController],
  providers: [CommerçantService],
})
export class CommerçantModule {}
