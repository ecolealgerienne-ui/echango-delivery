import { Global, Module } from '@nestjs/common';
import { CashService } from './cash.service';

/**
 * Global : les trois côtés du registre vivent dans des modules différents — le
 * commerçant fixe le montant à encaisser et confirme les remises, le
 * transporteur encaisse et déclare, et la création de commande contrôle le
 * plafond. Un service qu'il faut penser à importer module par module finit par
 * manquer là où il compte, et ici « là où il compte » porte sur de l'argent.
 */
@Global()
@Module({
  providers: [CashService],
  exports: [CashService],
})
export class CashModule {}
