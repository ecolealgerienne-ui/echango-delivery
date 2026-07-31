import { CashService, driverParty, fleetParty, merchantParty } from './cash.service';

/**
 * Les trois couples du registre, et surtout ce qui les sépare.
 *
 * ── Ce que ce test protège ──────────────────────────────────────────────────
 *
 * Une course encaissée porte **deux** obligations quand elle a un facilitateur :
 * le conducteur doit à son facilitateur, le facilitateur doit au commerçant. Les
 * deux se lisent sur la MÊME ligne d'encaissement, avec deux filtres différents.
 *
 * Le risque n'est donc pas qu'un filtre soit vide, c'est qu'il soit **trop
 * large** : si le couple « conducteur → commerçant » oubliait
 * `facilitatorId: null`, une course confiée à une entreprise serait comptée
 * deux fois — une fois chez l'entreprise, une fois chez le conducteur — et le
 * commerçant verrait le double de ce qu'on lui doit. C'est le seul défaut de
 * cette famille qui produirait un nombre plausible.
 *
 * On inspecte donc les clauses `where` réellement construites, plutôt que des
 * montants : un montant juste peut sortir d'un filtre faux dès que le jeu de
 * données est petit, et c'est exactement ce qu'un test unitaire ne doit pas
 * laisser passer.
 */
describe('debtBetween — les trois couples de parties', () => {
  let collectionWhere: any;
  let earningWhere: any;
  let remittanceWheres: any[];

  const service = () => {
    collectionWhere = undefined;
    earningWhere = undefined;
    remittanceWheres = [];

    const prisma: any = {
      cashCollection: {
        aggregate: (args: any) => {
          collectionWhere = args.where;
          return Promise.resolve({ _sum: { collectedAmount: 0 } });
        },
      },
      driverEarning: {
        aggregate: (args: any) => {
          earningWhere = args.where;
          return Promise.resolve({ _sum: { grossAmount: 0 } });
        },
      },
      cashRemittance: {
        aggregate: (args: any) => {
          remittanceWheres.push(args.where);
          return Promise.resolve({ _sum: { amount: 0 } });
        },
      },
    };

    return new CashService(
      prisma,
      { get: (): undefined => undefined } as any,
      {} as any,
      {} as any,
    );
  };

  it('conducteur → commerçant exige facilitatorId nul (sinon double comptage)', async () => {
    await service().debtBetween(driverParty('drv-1'), merchantParty('mer-1'));

    expect(collectionWhere).toMatchObject({
      driverId: 'drv-1',
      merchantId: 'mer-1',
      facilitatorId: null,
    });
    expect(earningWhere).toMatchObject({
      driverId: 'drv-1',
      merchantId: 'mer-1',
      facilitatorId: null,
    });
  });

  it('conducteur → facilitateur déduit ce que LE CONDUCTEUR a gagné, pas la course', async () => {
    await service().debtBetween(driverParty('drv-1'), fleetParty('flt-1'));

    expect(collectionWhere).toMatchObject({ driverId: 'drv-1', facilitatorId: 'flt-1' });

    // La distinction qui empêche un salarié d'empocher le chiffre d'affaires de
    // son employeur : sur ce maillon, seules les rémunérations dont le
    // BÉNÉFICIAIRE est le conducteur se déduisent.
    expect(earningWhere).toMatchObject({
      earnerType: 'driver',
      earnerId: 'drv-1',
      facilitatorId: 'flt-1',
    });
    expect(earningWhere.driverId).toBeUndefined();
  });

  it('facilitateur → commerçant déduit la rémunération de la course', async () => {
    await service().debtBetween(fleetParty('flt-1'), merchantParty('mer-1'));

    expect(collectionWhere).toMatchObject({ facilitatorId: 'flt-1', merchantId: 'mer-1' });
    expect(earningWhere).toMatchObject({ facilitatorId: 'flt-1', merchantId: 'mer-1' });
    expect(earningWhere.earnerType).toBeUndefined();
  });

  it('un couple donné à l’envers est ORIENTÉ, pas ignoré', async () => {
    // ⚠️ Ce test vérifiait l'inverse, et il célébrait un défaut bloquant.
    //
    // La chaîne va toujours dans le même sens — `driver → fleet → merchant` —
    // donc `legScope()` ne connaît que ces trois couples. Sans orientation,
    // `balancesFor()` interrogeait `(merchant, driver)` pour TOUT écran
    // commerçant : filtre vide, dette lue à 0 au lieu de 1300, puis +1300
    // fantôme une fois la remise confirmée, parce qu'il ne restait dans le
    // calcul que les remises avec le signe inversé.
    //
    // Le couple est donc réordonné avant tout calcul, et c'est le SIGNE qui
    // porte le sens demandé.
    await service().debtBetween(merchantParty('mer-1'), driverParty('drv-1'));

    expect(collectionWhere).toMatchObject({
      driverId: 'drv-1',
      merchantId: 'mer-1',
      facilitatorId: null,
    });
  });

  it('les deux vues d’une même dette sont opposées, jamais divergentes', async () => {
    // L'invariant qu'aucun test ne couvrait : le conducteur et le commerçant
    // doivent lire le MÊME nombre, au signe près. C'est ce qui manquait pour
    // attraper le défaut ci-dessus, tous les tests n'inspectant qu'un bout.
    const svc = service();
    const forward = await svc.debtBetween(driverParty('drv-1'), merchantParty('mer-1'));
    const backward = await svc.debtBetween(merchantParty('mer-1'), driverParty('drv-1'));

    expect(backward).toBe(-forward);
  });

  it('une partie face à elle-même vaut zéro sans interroger la base', async () => {
    const debt = await service().debtBetween(fleetParty('flt-1'), fleetParty('flt-1'));

    expect(debt).toBe(0);
    expect(collectionWhere).toBeUndefined();
  });

  it('les remises héritées sont comptées, sinon la migration ressuscite des dettes soldées', async () => {
    await service().debtBetween(driverParty('drv-1'), merchantParty('mer-1'));

    // Deux sens interrogés : ce qui va de A vers B, et ce qui revient.
    expect(remittanceWheres).toHaveLength(2);

    // Le sens conducteur → commerçant doit accepter les DEUX formes : le couple
    // typé, et les lignes d'avant ce chantier qui n'ont que `direction`.
    const outgoing = remittanceWheres[0];
    expect(outgoing.OR).toBeDefined();
    expect(outgoing.OR).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ fromType: 'driver', fromId: 'drv-1', toType: 'merchant', toId: 'mer-1' }),
        expect.objectContaining({ fromType: null, direction: 'driver_to_merchant' }),
      ]),
    );
  });

  it('un couple que le vocabulaire hérité ne sait pas nommer n’invente pas de repli', async () => {
    await service().debtBetween(driverParty('drv-1'), fleetParty('flt-1'));

    // Aucune ligne d'avant ce chantier ne décrit une remise conducteur →
    // entreprise : lui chercher un équivalent hérité reviendrait à compter des
    // remises faites à quelqu'un d'autre.
    const outgoing = remittanceWheres[0];
    expect(outgoing.OR).toBeUndefined();
    expect(outgoing).toMatchObject({
      fromType: 'driver',
      fromId: 'drv-1',
      toType: 'fleet',
      toId: 'flt-1',
    });
  });
});
