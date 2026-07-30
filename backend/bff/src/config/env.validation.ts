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

  // `development` ouvre le renvoi des détails d'erreur Fleetbase au client
  // (identifiants internes, structure de l'organisation). Le compose du dépôt
  // posait cette valeur en dur — la refuser sur un port non local.
  if (config.NODE_ENV === 'production' && config.ALLOW_DEV_ERRORS === 'true') {
    errors.push('ALLOW_DEV_ERRORS ne peut pas être activé en production');
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
