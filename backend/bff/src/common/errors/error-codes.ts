/**
 * Registre unique des codes d'erreur métier du BFF.
 *
 * ── Pourquoi un registre, et pas des chaînes inline ──────────────────────
 *
 * `http-errors.ts` fournit `badRequest(code, message)` etc., mais rien
 * n'empêchait un futur `badRequest('cash.amont_negative', …)` — une faute de
 * frappe — de compiler et de partir en production sous un code que ni le
 * client ni ce fichier ne connaissent. Une chaîne répétée à chaque site
 * d'appel n'est pas centralisée, elle est seulement cohérente par accident.
 *
 * Ce fichier est la seule source. `badRequest`/`unauthorized`/`forbidden`/
 * `notFound`/`conflict` exigent un `ErrorCode`, pas un `string` — un code
 * absent d'ici est donc une erreur de compilation, pas un bug découvert en
 * recette. C'est la même discipline que `OrderFilters`/`DriverFilters` dans
 * `fleetbase-api.client.ts` : le compilateur remplace le contrôle qu'aucune
 * requête de test n'aurait pensé à faire.
 *
 * ── Correspondance avec le client ─────────────────────────────────────────
 *
 * Mêmes noms, dans `echango_delivery/lib/errors/app_error.dart`. Aucun
 * partage de type entre les deux dépôts (langages différents) : la
 * correspondance se vérifie par lecture, comme le reste des contrats de ce
 * projet — et `lib/errors/error_translator.dart` échoue de façon visible
 * (fallback générique traduit, jamais un texte français brut) si un code
 * existe ici sans traduction là-bas.
 *
 * ── Une exception délibérée au nommage pointé ────────────────────────────
 *
 * `MERCHANT_PENDING = 'merchant_pending'` ne suit pas la convention
 * `domaine.motif` : ce code existait avant ce registre, et
 * `scripts/register-merchant.sh` le compare tel quel. Le renommer casserait
 * un script de test sans aucun bénéfice — le nom n'a pas besoin d'être joli,
 * il a besoin d'être stable.
 */
export const ErrorCode = {
  // ── Authentification ────────────────────────────────────────────────────
  AUTH_INVALID_CREDENTIALS: 'auth.invalid_credentials',
  AUTH_EMAIL_TAKEN: 'auth.email_taken',
  AUTH_MERCHANT_PENDING: 'merchant_pending',
  AUTH_MERCHANT_NOT_FOUND: 'auth.merchant_not_found',
  AUTH_MERCHANT_REGISTRATION_FAILED: 'auth.merchant_registration_failed',
  AUTH_FLEET_REGISTRATION_FAILED: 'auth.fleet_registration_failed',
  /**
   * Entreprise de transport inscrite, pas encore validée par un admin Echango.
   *
   * Le pendant exact de `merchant_pending`, et il suit la même exception de
   * nommage pour que les deux se lisent en parallèle — l'un sans point et
   * l'autre avec aurait laissé croire à deux mécanismes différents.
   */
  AUTH_FLEET_PENDING: 'fleet_pending',
  /**
   * Une entreprise tente d'inviter un conducteur qui n'est pas le sien.
   *
   * Le garde `@Persona('fleet')` dit **qui** a le droit d'émettre une
   * invitation, jamais **pour quel conducteur** : sans ce refus, un compte
   * flotte pouvait inviter n'importe quel `Driver` du réseau non encore
   * inscrit, et créer son compte applicatif à sa place.
   */
  AUTH_DRIVER_NOT_IN_FLEET: 'auth.driver_not_in_fleet',
  AUTH_DRIVER_REGISTRATION_FAILED: 'auth.driver_registration_failed',
  AUTH_DRIVER_NOT_FOUND: 'auth.driver_not_found',
  AUTH_DRIVER_UNKNOWN: 'auth.driver_unknown',
  AUTH_DRIVER_ALREADY_LINKED: 'auth.driver_already_linked',
  AUTH_DRIVER_ALREADY_HAS_ACCOUNT: 'auth.driver_already_has_account',
  AUTH_DRIVER_INVITATION_FAILED: 'auth.driver_invitation_failed',
  AUTH_INVITATION_INVALID: 'auth.invitation_invalid',
  AUTH_TOKEN_INVALID: 'auth.token_invalid',
  AUTH_MISSING_TOKEN: 'auth.missing_token',
  AUTH_SESSION_REVOKED: 'auth.session_revoked',

  // ── Encaissement à la porte ─────────────────────────────────────────────
  //
  // ⚠️ Vingt-cinq codes vivaient ici : remises, confirmations, contestations,
  // plafonds, contreparties. Ils sont partis le 03/08/2026 avec le registre de
  // caisse (`docs/registre_caisse_precis.md`). Il en reste **cinq**, et tous
  // portent sur un seul geste : ce que le transporteur déclare avoir perçu en
  // clôturant la livraison.
  CASH_COD_DECLARATION_REQUIRED: 'cash.cod_declaration_required',
  CASH_AMOUNT_NEGATIVE: 'cash.amount_negative',
  CASH_AMOUNT_EXCEEDS_EXPECTED: 'cash.amount_exceeds_expected',
  CASH_DISCREPANCY_REASON_REQUIRED: 'cash.discrepancy_reason_required',
  /**
   * La déclaration n'a pas pu être écrite sur la commande.
   *
   * Refus délibéré au lieu d'une clôture silencieuse : sans ce code, la
   * livraison se fermerait, le transporteur repartirait avec l'argent, et rien
   * n'en garderait trace. Le transporteur doit réessayer, pas continuer.
   */
  CASH_COLLECTION_NOT_RECORDED: 'cash.collection_not_recorded',

  // ── Commandes ────────────────────────────────────────────────────────────
  /**
   * Le refus n'a pas pu être écrit sur la commande.
   *
   * Refus délibéré au lieu d'un succès muet : un refus non enregistré fait
   * revenir la course au rafraîchissement suivant, et l'écran devient
   * indiscernable d'une fonctionnalité en panne — ce que ce chemin existe
   * précisément pour empêcher.
   */
  ORDER_DECLINE_NOT_RECORDED: 'order.decline_not_recorded',
  ORDER_NOT_FOUND: 'order.not_found',
  ORDER_FORBIDDEN: 'order.forbidden',
  ORDER_FETCH_FAILED: 'order.fetch_failed',
  ORDER_ASSIGN_FAILED: 'order.assign_failed',
  ORDER_CREATE_FAILED: 'order.create_failed',
  ORDER_CANCEL_FAILED: 'order.cancel_failed',
  ORDER_CANCEL_NOT_ALLOWED: 'order.cancel_not_allowed',
  ORDER_ALREADY_TERMINAL: 'order.already_terminal',
  ORDER_ALREADY_STARTED: 'order.already_started',
  ORDER_ALREADY_ACCEPTED: 'order.already_accepted',
  ORDER_ALREADY_DECLINED: 'order.already_declined',
  ORDER_NOT_ASSIGNED_TO_DRIVER: 'order.not_assigned_to_driver',
  ORDER_DECLINE_REASON_REQUIRED: 'order.decline_reason_required',
  ORDER_PROOF_REQUIRED: 'order.proof_required',
  ORDER_PROOF_NOT_FOUND: 'order.proof_not_found',
  ORDER_TRACKING_FAILED: 'order.tracking_failed',
  ORDER_TEMPLATE_FAILED: 'order.template_failed',
  ORDER_MISSING_PUBLIC_ID: 'order.missing_public_id',
  ORDER_RELEASE_FAILED: 'order.release_failed',
  ORDER_ALREADY_TAKEN: 'order.already_taken',
  /** Le rattachement d'une course à une entreprise a échoué côté Fleetbase. */
  ORDER_CLAIM_FAILED: 'order.claim_failed',
  /** Encaissement de la marchandise seule sans rémunération connue :
   *  impossible de savoir combien réclamer à la porte. */
  ORDER_COD_REQUIRES_PRICE: 'order.cod_requires_price',
  /** Les champs personnalisés durables n'ont pas pu être déclarés :
   *  refuser plutôt que d'enregistrer une livraison aux montants fragiles. */
  ORDER_CUSTOM_FIELDS_UNAVAILABLE: 'order.custom_fields_unavailable',
  ORDER_ALREADY_PUBLISHED: 'order.already_published',
  ORDER_PUBLISH_FAILED: 'order.publish_failed',
  ORDER_ACCEPT_FAILED: 'order.accept_failed',
  ORDER_START_FAILED: 'order.start_failed',
  ORDER_COMPLETE_FAILED: 'order.complete_failed',
  ORDER_ACTIVITIES_FETCH_FAILED: 'order.activities_fetch_failed',
  ORDER_ACTIVITY_UPDATE_FAILED: 'order.activity_update_failed',
  ORDER_PROOF_UPLOAD_FAILED: 'order.proof_upload_failed',
  ORDER_NOT_FOUND_UPSTREAM: 'order.not_found_upstream',

  // ── Transporteurs (persona flotte + commerçant) ─────────────────────────
  DRIVER_NOT_FOUND: 'driver.not_found',
  DRIVER_FORBIDDEN: 'driver.forbidden',
  DRIVER_FETCH_FAILED: 'driver.fetch_failed',
  DRIVER_CREATE_FAILED: 'driver.create_failed',
  DRIVER_POSITIONS_FETCH_FAILED: 'driver.positions_fetch_failed',
  DRIVER_INACTIVE: 'driver.inactive',
  DRIVER_UNAVAILABLE: 'driver.unavailable',
  DRIVER_PUBLIC_ID_UNRESOLVED: 'driver.public_id_unresolved',
  DRIVER_POSITION_UPDATE_FAILED: 'driver.position_update_failed',
  DRIVER_ONLINE_TOGGLE_FAILED: 'driver.online_toggle_failed',
  DRIVER_SEARCH_UNAVAILABLE: 'driver.search_unavailable',
  /// Recherche trop large : on demande de préciser plutôt que de tronquer, une
  /// liste balayable étant l'annuaire qu'on refuse d'ouvrir (29/07).
  DRIVER_SEARCH_TOO_BROAD: 'driver.search_too_broad',
  /// Cette personne est déjà dans le réseau : on ne la crée pas une seconde
  /// fois, on demande son rattachement. C'est la garde qui fait tenir toute la
  /// multi-appartenance — sans elle, deux entreprises créent deux conducteurs
  /// pour une seule personne, avec position et historique désynchronisés.
  DRIVER_ALREADY_IN_NETWORK: 'driver.already_in_network',

  // ── Adhésions conducteur ↔ entreprise ────────────────────────────────────
  MEMBERSHIP_NOT_FOUND: 'membership.not_found',
  MEMBERSHIP_ALREADY_EXISTS: 'membership.already_exists',
  /// Le conducteur a déjà répondu — l'entreprise ne peut plus décider à sa place.
  MEMBERSHIP_NOT_PENDING: 'membership.not_pending',
  /// Seul un rattachement actif se suspend, et seul un suspendu se réactive.
  /// Les deux gardes existent parce que **leur absence d'un seul côté** ouvrait
  /// un chemin `pending → suspended → active` qui produisait un rattachement
  /// sans le consentement du conducteur.
  MEMBERSHIP_NOT_ACTIVE: 'membership.not_active',
  MEMBERSHIP_NOT_SUSPENDED: 'membership.not_suspended',

  // ── Flotte (persona petite flotte) ──────────────────────────────────────
  FLEET_NOT_FOUND: 'fleet.not_found',
  FLEET_INACTIVE: 'fleet.inactive',

  // ── Commerçant ───────────────────────────────────────────────────────────
  MERCHANT_NOT_FOUND: 'merchant.not_found',
  MERCHANT_INACTIVE: 'merchant.inactive',
  MERCHANT_ADDRESS_NOT_FOUND: 'merchant.address_not_found',
  /**
   * Le carnet d'adresses n'a pas pu être lu.
   *
   * ⚠️ **Ce code existe parce que son absence produisait un mensonge.** Mesuré
   * le 03/08/2026 en coupant Fleetbase : `GET /commercant/adresses` rendait
   * `{"data": []}` en **HTTP 200** pour un commerçant qui a deux adresses. Rien
   * ne distinguait « votre carnet est vide » de « je n'ai pas pu le lire » —
   * exactement le défaut déjà constaté côté conducteurs (règle 10).
   */
  MERCHANT_ADDRESSES_UNAVAILABLE: 'merchant.addresses_unavailable',
  /** L'historique des transporteurs déjà employés n'a pas pu être lu. */
  MERCHANT_KNOWN_DRIVERS_UNAVAILABLE: 'merchant.known_drivers_unavailable',
  MERCHANT_FAVOURITE_NOT_FOUND: 'merchant.favourite_not_found',
  MERCHANT_FAVOURITE_ALREADY_EXISTS: 'merchant.favourite_already_exists',
  MERCHANT_DRIVER_NOT_IN_NETWORK: 'merchant.driver_not_in_network',
  /** L'entreprise visee n'a pas de compte actif chez nous : elle ne peut
   *  recevoir aucune course, la mettre en favori n'aurait pas de sens. */
  MERCHANT_FLEET_NOT_IN_NETWORK: 'merchant.fleet_not_in_network',
  MERCHANT_FAVOURITE_ADD_UNAVAILABLE: 'merchant.favourite_add_unavailable',
  MERCHANT_ADDRESS_SAVE_FAILED: 'merchant.address_save_failed',
  MERCHANT_ADDRESS_UPDATE_FAILED: 'merchant.address_update_failed',
  MERCHANT_ADDRESS_DELETE_FAILED: 'merchant.address_delete_failed',

  // ── Signalements et notifications ───────────────────────────────────────
  NOTIFICATION_NOT_FOUND: 'notification.not_found',

  // ── Géocodage ────────────────────────────────────────────────────────────
  GEOCODING_UNAVAILABLE: 'geocoding.unavailable',

  // ── Validation générique ─────────────────────────────────────────────────
  VALIDATION_INVALID_ID: 'validation.invalid_id',
  VALIDATION_FAILED: 'validation.failed',

  // ── Erreurs serveur / techniques ─────────────────────────────────────────
  SERVER_SCHEMA_OUT_OF_SYNC: 'server.schema_out_of_sync',
  SERVER_INVALID_PROFILE_TYPE: 'server.invalid_profile_type',
  SERVER_PERSONA_FORBIDDEN: 'server.persona_forbidden',
  /**
   * Panne non prévue : tout ce qui n'est pas une `HttpException`.
   *
   * ⚠️ **Ce code existe parce que son absence était un trou de la règle 3.**
   * `HttpExceptionFilter` est déclaré `@Catch(HttpException)` : une `TypeError`
   * ou une erreur Prisma ne passait pas par lui, sortait par le gestionnaire
   * par défaut de Nest, donc **sans `code`** — et l'application retombait sur
   * son message générique au moment précis où l'on comprend le moins ce qui
   * s'est passé.
   *
   * Il n'est **jamais levé à la main** : c'est le filet, et l'y trouver dans un
   * journal veut dire qu'un chemin d'erreur n'a pas été prévu.
   */
  SERVER_UNEXPECTED: 'server.unexpected',
} as const;

export type ErrorCode = (typeof ErrorCode)[keyof typeof ErrorCode];
