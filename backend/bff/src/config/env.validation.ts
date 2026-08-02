/**
 * Validation de l'environnement au démarrage.
 *
 * Motivation (revue du 28/07/2026, constat critique C1) : `JWT_SECRET` avait
 * trois valeurs de repli différentes selon le fichier, dont une versionnée
 * dans `docker-compose.yml`. Un déploiement sans la variable démarrait donc
 * **normalement**, avec un secret public — n'importe qui pouvait forger un
 * jeton et contourner l'intégralité du cloisonnement entre comptes.
 *
 * Le principe retenu : une variable manquante ou trop faible doit empêcher le
 * démarrage, pas dégrader silencieusement la sécurité. Un service qui refuse
 * de démarrer se remarque ; un service qui tourne avec un secret public, non.
 */

/** Longueur minimale du secret de signature, en caractères. */
const JWT_SECRET_MIN_LENGTH = 32;

/**
 * Secrets connus pour avoir été utilisés comme valeurs de repli dans ce dépôt.
 * Ils sont dans l'historique Git, donc publics : les refuser explicitement
 * évite qu'un copier-coller de `.env.example` ne les réintroduise.
 */
const FORBIDDEN_SECRETS = [
  'dev-secret',
  'dev-secret-key',
  'dev-secret-key-change-in-prod',
  'your_super_secret_jwt_key_change_in_production',
  'changeme',
  'secret',
];

export function validateEnv(config: Record<string, unknown>) {
  const errors: string[] = [];

  const required = ['DATABASE_URL', 'JWT_SECRET', 'FLEETBASE_API_URL', 'FLEETBASE_API_KEY'];
  for (const key of required) {
    if (!config[key] || String(config[key]).trim() === '') {
      errors.push(`${key} est absent ou vide`);
    }
  }

  const secret = String(config.JWT_SECRET ?? '');
  if (secret) {
    if (secret.length < JWT_SECRET_MIN_LENGTH) {
      errors.push(
        `JWT_SECRET fait ${secret.length} caractères, minimum ${JWT_SECRET_MIN_LENGTH}. ` +
          `En générer un : openssl rand -base64 48`,
      );
    }
    if (FORBIDDEN_SECRETS.includes(secret.toLowerCase())) {
      errors.push(
        'JWT_SECRET utilise une valeur présente dans le dépôt Git, donc publique. ' +
          'En générer un : openssl rand -base64 48',
      );
    }
  }

  // ── La vanne des détails d'erreur, gardée sur la BONNE variable ───────────
  //
  // ⚠️ Ce test portait sur `ALLOW_DEV_ERRORS`, qui n'est lue **nulle part** dans
  // le dépôt (revue du 01/08/2026, A4). La condition qui ouvre réellement le
  // renvoi au client des détails Fleetbase — identifiants internes, structure de
  // l'organisation — est `NODE_ENV === 'development'`, recopiée six fois dans
  // les services.
  //
  // Le garde était donc inerte dans les deux sens : il ne se déclenchait que
  // sous `NODE_ENV === 'production'`, c'est-à-dire précisément quand la fuite
  // est déjà impossible ; et poser `ALLOW_DEV_ERRORS=false` ne fermait rien tout
  // en donnant l'impression du contraire. Une garde qui protège une variable
  // morte est pire qu'une garde absente : l'absence fait vérifier.
  //
  // Ce qui est refusé maintenant, c'est **le cas réel** : un déploiement
  // exposé qui démarre en `development`. Le compose du dépôt pose cette valeur
  // en dur, donc le cas n'est pas théorique.
  const exposedPort = config.PORT && config.PORT !== '3000' && config.PORT !== '3001';
  if (config.NODE_ENV === 'development' && (config.PUBLIC_URL || exposedPort)) {
    errors.push(
      "NODE_ENV=development sur un déploiement exposé : les détails d'erreur " +
        'Fleetbase (identifiants internes, structure de l\'organisation) seraient ' +
        'renvoyés aux clients. Poser NODE_ENV=production.',
    );
  }

  if (errors.length) {
    throw new Error(
      `Configuration invalide, démarrage refusé :\n` +
        errors.map((e) => `  - ${e}`).join('\n') +
        `\n\nVoir backend/bff/.env.example.`,
    );
  }

  return config;
}
