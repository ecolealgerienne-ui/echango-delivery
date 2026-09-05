import axios from 'axios';

export interface Reachability {
  reachable: boolean;
  /** Aller-retour en ms si l'amont a répondu, `null` sinon. */
  latencyMs: number | null;
}

/**
 * « Cet amont HTTP répond-il ? » — la sonde partagée par toutes les
 * dépendances rapportées dans `/health` (Fleetbase, echango-geo, et les
 * suivantes).
 *
 * Extraite le 05/09/2026 : `FleetbaseApiClient.ping()` et
 * `GeocodingService.ping()` en tenaient deux copies identiques. Une seule
 * définition, pour que la règle « `/health` ne peut pas échouer » ne dépende
 * pas d'un copier-coller tenu à jour des deux côtés.
 *
 * ── Ce qu'elle garantit ──────────────────────────────────────────────────
 *
 * - **Ne lève jamais.** Une dépendance à terre est un `reachable: false`, pas
 *   une exception qui ferait tomber la sonde (`docs/status_v1.md`).
 * - **N'importe quel statut vaut « joignable ».** `validateStatus` laisse
 *   passer 401 / 404 / 500 : ils prouvent que l'amont *répond*, ce qui est
 *   toute la question. Seuls un timeout ou un refus de connexion donnent
 *   `false`.
 * - **Axios nu.** Hors de tout client applicatif : pas l'intercepteur qui
 *   journalise chaque erreur en `error` (inutile de crier à chaque
 *   `/health`), pas le timeout long du vrai client — 2,5 s par défaut.
 */
export async function probeReachable(
  url: string,
  timeoutMs = 2500,
): Promise<Reachability> {
  const start = Date.now();
  try {
    await axios.get(url, { timeout: timeoutMs, validateStatus: () => true });
    return { reachable: true, latencyMs: Date.now() - start };
  } catch {
    return { reachable: false, latencyMs: null };
  }
}
