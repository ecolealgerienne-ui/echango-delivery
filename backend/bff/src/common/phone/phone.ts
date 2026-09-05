/**
 * Normalisation d'un numéro de téléphone algérien vers `+213XXXXXXXXX`.
 *
 * ── Pourquoi une seule fonction ──────────────────────────────────────────
 *
 * La fiche client (`docs/specs_localisation_client_et_optimisation_parcours.md`
 * §1.3) est indexée par téléphone, portée plateforme — un même client doit
 * être reconnu qu'un commerçant tape `0555123456` ou `+213555123456`. Sans
 * normalisation à un seul endroit, deux commerçants créeraient deux fiches
 * pour la même personne selon la façon dont chacun a saisi le numéro (règle 5
 * de CLAUDE.md : une divergence ici n'est pas une variante, c'est un défaut).
 *
 * Accepte les mobiles algériens (05/06/07) en forme locale (`0XXXXXXXXX`,
 * dix chiffres) ou internationale (`+213XXXXXXXXX`/`00213XXXXXXXXX`, neuf
 * chiffres après l'indicatif). Rend `null` sur tout le reste plutôt que de
 * deviner — un numéro mal formé doit être refusé, pas normalisé au hasard.
 */
const LOCAL_MOBILE = /^0(5|6|7)\d{8}$/;
const INTERNATIONAL_MOBILE = /^(?:\+213|00213)(5|6|7)\d{8}$/;

export function normalizePhone(raw: string): string | null {
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim().replace(/[\s.-]/g, '');

  if (LOCAL_MOBILE.test(trimmed)) {
    return `+213${trimmed.slice(1)}`;
  }

  if (INTERNATIONAL_MOBILE.test(trimmed)) {
    const digits = trimmed.startsWith('+213') ? trimmed.slice(4) : trimmed.slice(5);
    return `+213${digits}`;
  }

  return null;
}
