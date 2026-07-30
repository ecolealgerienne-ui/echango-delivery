import { Module } from '@nestjs/common';
import { AuthService } from './auth.service';
import { AuthController } from './auth.controller';
import { FleetbaseModule } from '../fleetbase/fleetbase.module';

// Pas de JwtModule local ici : le JwtModule d'AppModule est déclaré `global`.
// En enregistrer un second créait un JwtService distinct, avec son propre
// repli de secret — c'est ce qui faisait diverger signature et vérification
// (revue C1).
@Module({
  imports: [FleetbaseModule],
  providers: [AuthService],
  controllers: [AuthController],
  exports: [AuthService],
})
export class AuthModule {}
