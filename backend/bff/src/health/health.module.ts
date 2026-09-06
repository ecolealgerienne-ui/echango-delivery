import { Module } from '@nestjs/common';
import { HealthController } from './health.controller';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';
import { GeocodingModule } from '../common/geocoding/geocoding.module';

@Module({
  // Pour les sondes de joignabilité servies par /health : Fleetbase et
  // echango-geo (le service de géocodage transverse).
  imports: [FleetbaseModule, GeocodingModule],
  controllers: [HealthController],
})
export class HealthModule {}
