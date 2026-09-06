import axios from 'axios';
import { probeReachable } from './reachability';

jest.mock('axios');
const mockedAxios = axios as jest.Mocked<typeof axios>;

/**
 * La sonde partagée des dépendances de `/health`. Ce que ces cas verrouillent
 * — et qui n'était couvert nulle part quand la logique vivait en deux copies
 * dans `FleetbaseApiClient` et `GeocodingService` :
 *
 *  - n'importe quel statut HTTP compte comme joignable (401/500 inclus) ;
 *  - un timeout / refus de connexion → `reachable: false`, **sans lever** ;
 *  - la latence n'est mesurée que sur une réponse.
 */
describe('probeReachable', () => {
  beforeEach(() => {
    (mockedAxios.get as jest.Mock) = jest.fn();
  });

  it('réponse 200 → reachable, latence mesurée', async () => {
    (mockedAxios.get as jest.Mock).mockResolvedValue({ status: 200 });
    const r = await probeReachable('http://x/health');
    expect(r.reachable).toBe(true);
    expect(typeof r.latencyMs).toBe('number');
  });

  it('un 500 (ou 401, 404) prouve que l’amont répond', async () => {
    (mockedAxios.get as jest.Mock).mockResolvedValue({ status: 500 });
    await expect(probeReachable('http://x')).resolves.toMatchObject({ reachable: true });
  });

  it('timeout / connexion refusée → reachable:false, latencyMs null, ne lève pas', async () => {
    (mockedAxios.get as jest.Mock).mockRejectedValue(
      Object.assign(new Error('timeout of 2500ms exceeded'), { code: 'ECONNABORTED' }),
    );
    await expect(probeReachable('http://x')).resolves.toEqual({
      reachable: false,
      latencyMs: null,
    });
  });

  it('transmet le timeout et neutralise validateStatus', async () => {
    (mockedAxios.get as jest.Mock).mockResolvedValue({ status: 204 });
    await probeReachable('http://x', 1234);
    const [, opts] = (mockedAxios.get as jest.Mock).mock.calls[0];
    expect(opts.timeout).toBe(1234);
    expect(opts.validateStatus()).toBe(true);
  });
});
