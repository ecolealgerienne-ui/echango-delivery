import { Module } from '@nestjs/common';
import { GeocodingService } from './geocoding.service';

/**
 * `GeocodingService` était fourni en dur dans `CommerçantModule`. Il est
 * désormais partagé : `HealthModule` en a besoin pour la sonde de
 * joignabilité d'`echango-geo`. Un module qui l'exporte évite de le déclarer
 * deux fois (deux instances, deux clients axios).
 */
@Module({
  providers: [GeocodingService],
  exports: [GeocodingService],
})
export class GeocodingModule {}
