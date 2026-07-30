import { SetMetadata } from '@nestjs/common';

export const PERSONA_KEY = 'persona';

/**
 * Type de compte exigé sur une route.
 *
 * Les trois personas partagent le même émetteur JWT : un jeton commerçant est
 * donc **cryptographiquement valide** sur les routes transporteur, et
 * réciproquement. Seul un contrôle explicite du champ `type` les sépare.
 *
 * Ce contrôle existait en dur dans `TransporteurController` et
 * `FlotteController`, mais **manquait dans `CommerçantController`** (revue E4).
 * Il n'était rattrapé que par une propriété non voulue du schéma — les `cuid`
 * de tables différentes ne se rencontrent pas, donc la recherche échouait en
 * 404. Une garantie probabiliste, qui tombait au premier compte multi-profils
 * ou au premier import d'identifiants.
 *
 * Le décorateur remplace les trois helpers dupliqués : l'oubli sur une route
 * future n'est plus possible sans que ça se voie.
 */
export const Persona = (...types: string[]) => SetMetadata(PERSONA_KEY, types);
