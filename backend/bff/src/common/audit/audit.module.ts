import { Global, Module } from '@nestjs/common';
import { AuditService } from './audit.service';

/**
 * Global, comme PrismaModule : la piste d'audit doit être atteignable depuis
 * n'importe quel module sans qu'on ait à penser à l'importer. Un contrôle de
 * sécurité qu'il faut câbler module par module finit par manquer là où il
 * compte.
 */
@Global()
@Module({
  providers: [AuditService],
  exports: [AuditService],
})
export class AuditModule {}
