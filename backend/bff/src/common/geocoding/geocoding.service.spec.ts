import { HttpStatus } from '@nestjs/common';
import axios from 'axios';
import { ErrorCode } from '../errors/error-codes';
import { GeocodingService } from './geocoding.service';

jest.mock('axios');
const mockedAxios = axios as jest.Mocked<typeof axios>;

/**
 * Bascule du géocodage vers `echango-geo` (05/09/2026).
 *
 * ── Ce que ces cas verrouillent ────────────────────────────────────────────
 *
 * 1. Le contrat `GeocodedPlace` traverse sans retouche : `echango-geo` produit
 *    déjà cette forme (le mapping `toPlace()` a quitté ce dépôt), donc `search`
 *    rend `data.results` tel quel et `reverse` rend `data` tel quel.
 * 2. **Une panne d'`echango-geo` sort en `503`, jamais en `200`.** Avant la
 *    bascule, `reverse` avalait toute erreur et rendait un `Place` à libellé
 *    vide — indiscernable d'un point en mer. C'est précisément l'ambiguïté que
 *    le service transverse existe pour lever ; la ré-introduire ici la
 *    viderait de son sens.
 * 3. Un point que Nominatim ne connaît pas (mer) N'est PAS une panne :
 *    `echango-geo` répond `200` + champs vides, et on le relaie.
 */
describe('GeocodingService — client d’echango-geo', () => {
  let get: jest.Mock;
  let service: GeocodingService;

  beforeEach(() => {
    get = jest.fn();
    mockedAxios.create.mockReturnValue({ get } as never);
    mockedAxios.get = jest.fn();
    mockedAxios.isAxiosError.mockImplementation((e: unknown) =>
      Boolean((e as { isAxiosError?: boolean })?.isAxiosError),
    );
    process.env.GEO_SERVICE_URL = 'http://geo-api:3000';
    process.env.GEO_INTERNAL_TOKEN = 'jeton-test';
    service = new GeocodingService();
  });

  describe('search', () => {
    it('court-circuite sous 3 caractères, sans appel réseau', async () => {
      await expect(service.search('ab')).resolves.toEqual([]);
      expect(get).not.toHaveBeenCalled();
    });

    it('transmet q / limit / country et rend data.results tel quel', async () => {
      const place = {
        label: 'Rue Larbi Tebessi, Belcourt, Alger',
        shortLabel: 'Rue Larbi Tebessi',
        latitude: 36.75,
        longitude: 3.05,
        city: 'Alger',
        province: 'Alger',
        country: 'DZ',
      };
      get.mockResolvedValue({ status: 200, data: { results: [place] } });

      const out = await service.search('Larbi Tebessi', 3);

      expect(get).toHaveBeenCalledWith('/v1/geocode/search', {
        params: { q: 'Larbi Tebessi', limit: 3, country: 'dz' },
      });
      expect(out).toEqual([place]);
    });

    it('rend [] quand echango-geo ne trouve rien (jamais une erreur)', async () => {
      get.mockResolvedValue({ status: 200, data: { results: [] } });
      await expect(service.search('zzzzzz')).resolves.toEqual([]);
    });

    it('echango-geo en 503 → 503 geocoding.unavailable', async () => {
      get.mockRejectedValue({
        isAxiosError: true,
        response: { status: 503, data: { code: 'geo.upstream_unavailable' } },
      });
      await expect(service.search('alger centre')).rejects.toMatchObject({
        status: HttpStatus.SERVICE_UNAVAILABLE,
        response: { code: ErrorCode.GEOCODING_UNAVAILABLE },
      });
    });

    it('echango-geo injoignable → 503 geocoding.unavailable', async () => {
      get.mockRejectedValue({ isAxiosError: true, code: 'ECONNREFUSED' });
      await expect(service.search('alger centre')).rejects.toMatchObject({
        status: HttpStatus.SERVICE_UNAVAILABLE,
        response: { code: ErrorCode.GEOCODING_UNAVAILABLE },
      });
    });
  });

  describe('reverse', () => {
    it('relaie le Place tel quel', async () => {
      const place = {
        label: 'Rue Didouche Mourad, Alger',
        shortLabel: 'Rue Didouche Mourad',
        latitude: 36.77,
        longitude: 3.05,
        province: 'Alger',
        country: 'DZ',
      };
      get.mockResolvedValue({ status: 200, data: place });
      await expect(service.reverse(36.77, 3.05)).resolves.toEqual(place);
    });

    it('point en mer : relaie les coordonnées + champs vides, pas d’erreur', async () => {
      const vide = { label: '', shortLabel: '', latitude: 30, longitude: -40 };
      get.mockResolvedValue({ status: 200, data: vide });
      await expect(service.reverse(30, -40)).resolves.toEqual(vide);
    });

    it('echango-geo injoignable → 503, JAMAIS un 200 à libellé vide', async () => {
      get.mockRejectedValue({ isAxiosError: true, code: 'ETIMEDOUT' });
      await expect(service.reverse(36.77, 3.05)).rejects.toMatchObject({
        status: HttpStatus.SERVICE_UNAVAILABLE,
        response: { code: ErrorCode.GEOCODING_UNAVAILABLE },
      });
    });
  });

  describe('ping', () => {
    it('rend reachable:true quand /health répond (quel que soit le statut)', async () => {
      (mockedAxios.get as jest.Mock).mockResolvedValue({ status: 200 });
      await expect(service.ping()).resolves.toEqual({ reachable: true });
    });

    it('rend reachable:false sans jamais lever', async () => {
      (mockedAxios.get as jest.Mock).mockRejectedValue(new Error('down'));
      await expect(service.ping()).resolves.toEqual({ reachable: false });
    });
  });
});
