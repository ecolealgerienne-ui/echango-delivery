import { Module } from '@nestjs/common';
import { FlotteController } from './flotte.controller';
import { FlotteService } from './flotte.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

@Module({
  imports: [FleetbaseModule],
  controllers: [FlotteController],
  providers: [FlotteService],
})
export class FlotteModule {}
