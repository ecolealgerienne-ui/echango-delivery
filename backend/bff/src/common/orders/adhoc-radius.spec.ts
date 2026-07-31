import { adhocRadiusMetres, DEFAULT_ADHOC_RADIUS_METRES } from './adhoc-radius';

/**
 * Le rayon de diffusion, éprouvé sur ce qu'une variable d'environnement peut
 * réellement contenir.
 *
 * ── Pourquoi un test sur trois lignes de code ─────────────────────────────
 *
 * Parce que ce que ces trois lignes décident, c'est **qui voit une course**.
 * Un repli qui ne se déclenche pas envoie `NaN` à Fleetbase ; un repli qui se
 * déclenche trop envoie 15 km là où l'exploitation en voulait cinquante. Ni
 * l'un ni l'autre ne produit d'erreur visible : la course part, et personne
 * n'est pingué comme prévu.
 *
 * Et surtout : la valeur arrive **en chaîne**. `process.env` ne rend jamais de
 * nombre, et c'est le cas que la relecture oublie.
 */
describe('adhocRadiusMetres', () => {
  it('accepte un nombre configuré', () => {
    expect(adhocRadiusMetres(30000)).toBe(30000);
  });

  it('accepte une CHAÎNE, qui est ce que rend `process.env`', () => {
    // Le cas réel : `.env` porte `ADHOC_RADIUS_METRES=30000`, et
    // `configService.get()` rend `'30000'`. Un contrôle qui n'exercerait que
    // le nombre passerait au vert sur un code cassé en production.
    expect(adhocRadiusMetres('30000')).toBe(30000);
  });

  it('accepte une valeur décimale', () => {
    expect(adhocRadiusMetres('7500.5')).toBe(7500.5);
  });

  describe('retombe sur le repli', () => {
    it('quand rien n’est configuré', () => {
      expect(adhocRadiusMetres(undefined)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres(null)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
    });

    it('sur une chaîne vide — le piège de la variable déclarée sans valeur', () => {
      // ⚠️ `Number('')` vaut **0**, pas `NaN`. Un contrôle écrit sur
      // `Number.isNaN` seul aurait donc laissé passer un rayon de zéro, qui ne
      // diffuse à personne — et rien à l'écran n'aurait dit pourquoi.
      expect(adhocRadiusMetres('')).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres('   ')).toBe(DEFAULT_ADHOC_RADIUS_METRES);
    });

    it('sur zéro et sur un négatif', () => {
      expect(adhocRadiusMetres(0)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres(-5000)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres('-1')).toBe(DEFAULT_ADHOC_RADIUS_METRES);
    });

    it('sur ce qui n’est pas un nombre', () => {
      expect(adhocRadiusMetres('quinze km')).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres({})).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres(NaN)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
      expect(adhocRadiusMetres(Infinity)).toBe(DEFAULT_ADHOC_RADIUS_METRES);
    });
  });

  it('rend la MÊME valeur aux deux appelants — c’est tout l’objet du module', () => {
    // `CommerçantService` diffuse à la création, `TransporteurService`
    // rediffuse une course rendue. Une divergence entre les deux ferait qu'un
    // refus rétrécit ou élargit la portée d'une course, en silence.
    const configured = '22000';
    expect(adhocRadiusMetres(configured)).toBe(adhocRadiusMetres(configured));
    expect(adhocRadiusMetres(undefined)).toBe(adhocRadiusMetres(''));
  });
});
