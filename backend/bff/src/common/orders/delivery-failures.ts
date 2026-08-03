/**
 * Les échecs de livraison, **portés par la commande**.
 *
 * ── Pourquoi ce n'est plus une table du BFF (03/08/2026) ────────────────────
 *
 * `DeliveryFailure` vivait côté BFF, donc **invisible depuis la console** — et
 * la console est utilisée en exploitation. C'est pourtant la donnée qui
 * explique le mieux pourquoi une livraison n'aboutit pas : « destinataire
 * absent », avec la photo. Un opérateur devait nous appeler pour l'obtenir.
 *
 * ── Un seul lecteur pour les trois personas ─────────────────────────────────
 *
 * Commerçant, transporteur et entreprise lisent la même liste, avec le même
 * ordre et le même chemin de photo — seul le préfixe de route change. Trois
 * copies auraient divergé sur l'ordre ou sur le format de date, et personne ne
 * les aurait comparées (règle 5).
 */

/** Un échec, tel qu'il est stocké sur la commande. */
export interface StoredDeliveryFailure {
  /** Identifiant stable, généré à l'écriture. Sert de clé à la route de preuve. */
  id: string;
  driver_uuid?: string | null;
  waypoint_uuid?: string | null;
  reason: string;
  notes?: string | null;
  /** URL Fleetbase du fichier. **Jamais servie à l'application** — voir plus bas. */
  proof_url?: string | null;
  proof_ref?: string | null;
  reported_at: string;
}

/**
 * Les échecs d'une commande, **du plus récent au plus ancien**.
 *
 * ⚠️ L'ordre compte et il est ici, pas chez l'appelant. Une version précédente
 * ne gardait que le dernier, au motif que « seul le dernier décrit l'état
 * courant ». C'est vrai d'un badge de statut, faux d'un signalement : une
 * livraison qui a échoué trois fois n'est pas celle qui a échoué une fois, et
 * chaque rapport porte sa propre photo — n'en exposer qu'une revenait à effacer
 * les preuves précédentes.
 */
export function orderFailures(order: any): StoredDeliveryFailure[] {
  const brut = order?.meta?.delivery_failures;
  if (!Array.isArray(brut)) return [];

  return brut
    .filter((f: any) => f && typeof f.reason === 'string')
    .slice()
    .sort((a: any, b: any) => String(b.reported_at ?? '').localeCompare(String(a.reported_at ?? '')));
}

/**
 * Ce que l'application reçoit — la liste complète et le plus récent à part.
 *
 * ⚠️ **`proof_url` de Fleetbase ne sort JAMAIS.** Elle pointe sur l'hôte tel
 * que Fleetbase se connaît — injoignable depuis un téléphone — et surtout elle
 * n'est protégée par rien : la donner à l'app reviendrait à publier les preuves
 * de livraison à qui devinerait l'adresse. On sert un chemin du BFF, où le
 * jeton fait foi.
 *
 * ⚠️ **Et la route porte l'uuid de la COMMANDE**, plus un identifiant global.
 * C'est ce qui rend l'appartenance **structurelle** : servir la preuve exige de
 * résoudre la commande, donc de traverser le contrôle qui existe déjà. La
 * version précédente cherchait un signalement par son identifiant seul et
 * devait re-vérifier le propriétaire à la main — la discipline anti-IDOR
 * reposait sur le fait que son auteur y avait pensé.
 */
export function projectFailures(
  order: any,
  /** `commercant` ou `transporteur` — le préfixe de la route de preuve. */
  persona: string,
): Record<string, any> {
  const failures = orderFailures(order);
  if (!failures.length) return {};

  const uuid = order?.uuid;
  const project = (f: StoredDeliveryFailure) => ({
    id: f.id,
    reason: f.reason,
    notes: f.notes ?? null,
    photo_url: f.proof_url && uuid ? `/${persona}/commandes/${uuid}/preuves/${f.id}` : null,
    created_at: f.reported_at,
  });

  return {
    delivery_failure: project(failures[0]),
    delivery_failures: failures.map(project),
  };
}

/** L'échec désigné par [id] sur cette commande, ou `undefined`. */
export function findFailure(order: any, id: string): StoredDeliveryFailure | undefined {
  return orderFailures(order).find((f) => f.id === id);
}

/** Cette commande porte-t-elle au moins un échec signalé ? */
export function hasFailure(order: any): boolean {
  return orderFailures(order).length > 0;
}
