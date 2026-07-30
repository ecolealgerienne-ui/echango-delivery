import { Module } from '@nestjs/common';
import { TransporteurController } from './transporteur.controller';
import { TransporteurService } from './transporteur.service';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

@Module({
  imports: [FleetbaseModule],
  controllers: [TransporteurController],
  providers: [TransporteurService],
})
export class TransporteurModule {}
