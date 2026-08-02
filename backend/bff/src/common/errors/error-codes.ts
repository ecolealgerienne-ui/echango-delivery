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

  // ── Caisse (encaissements, remises) ─────────────────────────────────────
  /**
   * Plusieurs prestataires « plateforme » actifs.
   *
   * Refus délibéré plutôt qu'un choix au hasard : c'est ce compte qui reçoit
   * l'argent des courses du pool, donc en prendre un arbitrairement routerait
   * une somme réelle vers la mauvaise partie, et le défaut ne se verrait qu'au
   * règlement.
   */
  CASH_PLATFORM_AMBIGUOUS: 'cash.platform_ambiguous',
  CASH_AMOUNT_NEGATIVE: 'cash.amount_negative',
  CASH_AMOUNT_EXCEEDS_EXPECTED: 'cash.amount_exceeds_expected',
  CASH_DISCREPANCY_REASON_REQUIRED: 'cash.discrepancy_reason_required',
  CASH_COLLECTION_CONFLICT: 'cash.collection_conflict',
  CASH_REMITTANCE_AMOUNT_MUST_BE_POSITIVE: 'cash.remittance_amount_must_be_positive',
  CASH_NO_DEBT: 'cash.no_debt',
  CASH_REMITTANCE_EXCEEDS_DEBT: 'cash.remittance_exceeds_debt',
  CASH_REMITTANCE_ALREADY_CONFIRMED: 'cash.remittance_already_confirmed',
  CASH_REMITTANCE_DISPUTED: 'cash.remittance_disputed',
  CASH_REMITTANCE_MUST_BE_CONFIRMED_BY_OTHER_PARTY:
    'cash.remittance_must_be_confirmed_by_other_party',
  CASH_REMITTANCE_SELF_DISPUTE_FORBIDDEN: 'cash.remittance_self_dispute_forbidden',
  CASH_REMITTANCE_NOT_FOUND: 'cash.remittance_not_found',
  CASH_CEILING_EXCEEDED: 'cash.ceiling_exceeded',
  CASH_COD_DECLARATION_REQUIRED: 'cash.cod_declaration_required',
  CASH_ORDER_UNKNOWN_TO_REGISTRY: 'cash.order_unknown_to_registry',

  // Régularisation d'une livraison close hors application : le commerçant
  // déclare l'encaissement manquant, le transporteur confirme ou conteste.
  CASH_COLLECTION_ALREADY_DECLARED: 'cash.collection_already_declared',
  CASH_COLLECTION_NOT_FOUND: 'cash.collection_not_found',
  CASH_COLLECTION_NOT_CONFIRMABLE: 'cash.collection_not_confirmable',
  CASH_COLLECTION_ALREADY_CONFIRMED: 'cash.collection_already_confirmed',
  CASH_COLLECTION_DISPUTED: 'cash.collection_disputed',
  CASH_ORDER_NOT_DELIVERED: 'cash.order_not_delivered',
  CASH_ORDER_HAS_NO_COD: 'cash.order_has_no_cod',
  CASH_DRIVER_REQUIRED: 'cash.driver_required',
  CASH_DRIVER_NOT_IN_NETWORK: 'cash.driver_not_in_network',
  /// Le transporteur existe chez Fleetbase mais n'a pas de compte Echango :
  /// personne ne peut confirmer l'encaissement tant qu'il n'est pas provisionné.
  CASH_DRIVER_NO_ACCOUNT: 'cash.driver_no_account',
  CASH_DRIVER_UNKNOWN_TO_MERCHANT: 'cash.driver_unknown_to_merchant',
  /**
   * L'identifiant de contrepartie d'une remise ne correspond à aucun compte.
   *
   * Le serveur type lui-même la contrepartie à partir de son identifiant (voir
   * `declareRemittanceTo`) : ne rien trouver signifie que l'appelant a envoyé
   * un identifiant qui n'existe dans aucune des trois tables.
   */
  CASH_COUNTERPARTY_NOT_FOUND: 'cash.counterparty_not_found',

  // ── Commandes ────────────────────────────────────────────────────────────
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
