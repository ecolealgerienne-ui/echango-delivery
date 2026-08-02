import {
  DriverZone,
  OrderPickup,
  orderPickup,
  zoneAllows,
  zoneAllowsPickup,
} from './driver-zone';

/**
 * La zone décide aussi de **qui est sollicité**, pas seulement de ce qui
 * s'affiche.
 *
 * ── Pourquoi ce fichier existe à côté de `driver-zone.spec.ts` ──────────────
 *
 * Deux chemins appliquent la même règle et n'ont pas la même chose en main :
 * la liste des opportunités tient une commande Fleetbase complète, la
 * sollicitation d'un favori se décide **avant que la commande existe**. Ces cas
 * vérifient qu'ils ne peuvent pas diverger — c'est-à-dire que la règle est
 * appliquée à un seul endroit et non recopiée (règle 5).
 *
 * ⚠️ **L'enjeu n'est pas symétrique.** Écarter à tort d'une liste coûte une
 * course qu'on ne voit pas ; assigner à tort **sort la course du pool** et la
 * laisse chez quelqu'un qui ne la regardera pas — rien ne la reprend. C'est
 * pourquoi le biais « ce qu'on ignore laisse passer » est vérifié cas par cas
 * ici aussi : un favori ne doit jamais être écarté par une préférence qu'on n'a
 * pas su lire.
 */
describe('la zone appliquée à une sollicitation', () => {
  const alger: DriverZone = { wilaya: 'Alger', radiusKm: null };
  const centre = { latitude: 36.7538, longitude: 3.0588 };

  describe('les deux chemins donnent la même réponse', () => {
    // Le cas fondateur : une divergence ici écarterait un transporteur d'une
    // liste tout en lui assignant d'office la même course.
    const cases: Array<{ nom: string; order: any }> = [
      {
        nom: 'course dans la wilaya',
        order: { meta: { pickup_province: 'ALGER' } },
      },
      {
        nom: 'course hors wilaya',
        order: { meta: { pickup_province: 'Tamanrasset' } },
      },
      { nom: 'course sans wilaya', order: { meta: {} } },
    ];

    for (const { nom, order } of cases) {
      it(nom, () => {
        expect(zoneAllowsPickup(orderPickup(order), alger, centre)).toBe(
          zoneAllows(order, alger, centre),
        );
      });
    }
  });

  describe('ce qui écarte réellement', () => {
    it('écarte un favori dont la wilaya ne correspond pas', () => {
      const pickup: OrderPickup = { wilaya: 'Tamanrasset', point: null };
      expect(zoneAllowsPickup(pickup, alger, centre)).toBe(false);
    });

    it('garde le favori quand la wilaya correspond, casse comprise', () => {
      // Témoin du cas précédent : sans lui, « écarte toujours » passerait.
      expect(zoneAllowsPickup({ wilaya: 'ALGER', point: null } as OrderPickup, alger, centre)).toBe(true);
      expect(zoneAllowsPickup({ wilaya: ' alger ', point: null } as OrderPickup, alger, centre)).toBe(true);
    });

    it('écarte au-delà du rayon déclaré', () => {
      const zone: DriverZone = { wilaya: null, radiusKm: 15 };
      // Blida, ~45 km d'Alger.
      const loin: OrderPickup = { wilaya: null, point: { latitude: 36.4703, longitude: 2.8277 } };
      const pres: OrderPickup = { wilaya: null, point: { latitude: 36.7600, longitude: 3.0600 } };
      expect(zoneAllowsPickup(loin, zone, centre)).toBe(false);
      expect(zoneAllowsPickup(pres, zone, centre)).toBe(true);
    });
  });

  describe('⚠️ ce qu’on ignore ne retire JAMAIS un favori', () => {
    it('aucune préférence déclarée ⇒ il reste sollicitable', () => {
      expect(zoneAllowsPickup({ wilaya: 'Tamanrasset', point: null } as OrderPickup, null, centre)).toBe(true);
      expect(zoneAllowsPickup({ wilaya: 'Tamanrasset', point: null } as OrderPickup, undefined, centre)).toBe(
        true,
      );
    });

    it('départ de wilaya inconnue ⇒ il reste sollicitable', () => {
      // Le formulaire peut ne pas porter la wilaya (adresse saisie à la main).
      expect(zoneAllowsPickup({ wilaya: null, point: null } as OrderPickup, alger, centre)).toBe(true);
    });

    it('conducteur sans position ⇒ seul le rayon tombe, pas la wilaya', () => {
      const zone: DriverZone = { wilaya: 'Alger', radiusKm: 1 };
      const loin: OrderPickup = { wilaya: 'Alger', point: { latitude: 36.4703, longitude: 2.8277 } };
      // Le rayon ne peut pas s'appliquer : la wilaya décide seule, et elle passe.
      expect(zoneAllowsPickup(loin, zone, null)).toBe(true);
      // Témoin : avec la position, le rayon écarte bel et bien.
      expect(zoneAllowsPickup(loin, zone, centre)).toBe(false);
    });

    it('départ sans point ⇒ le rayon ne peut pas écarter', () => {
      const zone: DriverZone = { wilaya: null, radiusKm: 1 };
      expect(zoneAllowsPickup({ wilaya: null, point: null } as OrderPickup, zone, centre)).toBe(true);
    });
  });

  describe('orderPickup', () => {
    it('lit le départ d’une commande, meta d’abord', () => {
      // ⚠️ La liste ne sert PAS `province` sur le point d'enlèvement : la copie
      // posée dans `meta` à la création est la seule lisible là.
      expect(
        orderPickup({
          meta: { pickup_province: 'Alger' },
          payload: { pickup: { province: 'Oran', location: { coordinates: [3.05, 36.75] } } },
        }),
      ).toEqual({ wilaya: 'Alger', point: { latitude: 36.75, longitude: 3.05 } });
    });

    it('ne fabrique rien quand la commande ne porte rien', () => {
      expect(orderPickup({})).toEqual({ wilaya: null, point: null });
      expect(orderPickup(null)).toEqual({ wilaya: null, point: null });
    });
  });
});
