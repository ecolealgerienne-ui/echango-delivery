import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

@Module({
  // Pour la sonde de joignabilité de Fleetbase servie par /health.
  imports: [FleetbaseModule],
  controllers: [HealthController],
})
export class HealthModule {}
