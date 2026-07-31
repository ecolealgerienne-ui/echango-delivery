/// Codes d'erreur métier de l'app Echango Delivery.
///
/// ── Miroir du registre serveur ───────────────────────────────────────────
///
/// Mêmes chaînes que `backend/bff/src/common/errors/error-codes.ts`, tenues
/// à la main : les deux dépôts sont dans des langages différents, rien ne
/// partage le type entre eux. La correspondance se vérifie par lecture,
/// comme le reste des contrats entre le BFF et l'app dans ce projet.
///
/// `merchant_pending` ne suit pas la convention `domaine.motif` : c'est
/// l'exception documentée côté serveur (le code existait avant le registre,
/// et `scripts/register-merchant.sh` le compare tel quel).
///
/// ── Ce qui n'est PAS dans le registre serveur ────────────────────────────
///
/// `networkError`, `timeoutError`, `serverError` et `unknown` sont des
/// constats du client : ils n'accompagnent jamais un `code` reçu du BFF,
/// puisqu'ils décrivent précisément l'absence de réponse exploitable
/// (requête qui n'a jamais atteint le serveur, timeout, corps illisible).
class AppError {
  AppError._();

  // ── Authentification ────────────────────────────────────────────────────
  static const String authInvalidCredentials = 'auth.invalid_credentials';
  static const String authEmailTaken = 'auth.email_taken';
  static const String authMerchantPending = 'merchant_pending';
  static const String authMerchantNotFound = 'auth.merchant_not_found';
  static const String authMerchantRegistrationFailed = 'auth.merchant_registration_failed';
  static const String authFleetRegistrationFailed = 'auth.fleet_registration_failed';
  /// Pendant exact de `merchant_pending`, et il suit la même exception de
  /// nommage : l'un sans point et l'autre avec aurait laissé croire à deux
  /// mécanismes différents.
  static const String authFleetPending = 'fleet_pending';
  static const String authDriverNotInFleet = 'auth.driver_not_in_fleet';
  static const String authDriverRegistrationFailed = 'auth.driver_registration_failed';
  static const String authDriverNotFound = 'auth.driver_not_found';
  static const String authDriverUnknown = 'auth.driver_unknown';
  static const String authDriverAlreadyLinked = 'auth.driver_already_linked';
  static const String authDriverAlreadyHasAccount = 'auth.driver_already_has_account';
  static const String authDriverInvitationFailed = 'auth.driver_invitation_failed';
  static const String authInvitationInvalid = 'auth.invitation_invalid';
  static const String authTokenInvalid = 'auth.token_invalid';
  static const String authMissingToken = 'auth.missing_token';
  static const String authSessionRevoked = 'auth.session_revoked';

  // ── Caisse (encaissements, remises) ─────────────────────────────────────
  static const String cashAmountNegative = 'cash.amount_negative';
  static const String cashAmountExceedsExpected = 'cash.amount_exceeds_expected';
  static const String cashDiscrepancyReasonRequired = 'cash.discrepancy_reason_required';
  static const String cashCollectionConflict = 'cash.collection_conflict';
  static const String cashRemittanceAmountMustBePositive =
      'cash.remittance_amount_must_be_positive';
  static const String cashNoDebt = 'cash.no_debt';
  static const String cashRemittanceExceedsDebt = 'cash.remittance_exceeds_debt';
  static const String cashRemittanceAlreadyConfirmed = 'cash.remittance_already_confirmed';
  static const String cashRemittanceDisputed = 'cash.remittance_disputed';
  static const String cashRemittanceMustBeConfirmedByOtherParty =
      'cash.remittance_must_be_confirmed_by_other_party';
  static const String cashRemittanceSelfDisputeForbidden =
      'cash.remittance_self_dispute_forbidden';
  static const String cashRemittanceNotFound = 'cash.remittance_not_found';
  static const String cashCeilingExceeded = 'cash.ceiling_exceeded';
  static const String cashCodDeclarationRequired = 'cash.cod_declaration_required';
  static const String cashOrderUnknownToRegistry = 'cash.order_unknown_to_registry';

  // Régularisation d'une livraison close hors application.
  static const String cashCollectionAlreadyDeclared = 'cash.collection_already_declared';
  static const String cashCollectionNotFound = 'cash.collection_not_found';
  static const String cashCollectionNotConfirmable = 'cash.collection_not_confirmable';
  static const String cashCollectionAlreadyConfirmed = 'cash.collection_already_confirmed';
  static const String cashCollectionDisputed = 'cash.collection_disputed';
  static const String cashOrderNotDelivered = 'cash.order_not_delivered';
  static const String cashOrderHasNoCod = 'cash.order_has_no_cod';
  static const String cashDriverRequired = 'cash.driver_required';
  static const String cashDriverNotInNetwork = 'cash.driver_not_in_network';
  static const String cashCounterpartyNotFound = 'cash.counterparty_not_found';
  static const String cashDriverNoAccount = 'cash.driver_no_account';

  // ── Commandes ────────────────────────────────────────────────────────────
  static const String orderNotFound = 'order.not_found';
  static const String orderForbidden = 'order.forbidden';
  static const String orderFetchFailed = 'order.fetch_failed';
  static const String orderAssignFailed = 'order.assign_failed';
  static const String orderCreateFailed = 'order.create_failed';
  static const String orderCancelFailed = 'order.cancel_failed';
  static const String orderCancelNotAllowed = 'order.cancel_not_allowed';
  static const String orderAlreadyTerminal = 'order.already_terminal';
  static const String orderAlreadyStarted = 'order.already_started';
  static const String orderAlreadyAccepted = 'order.already_accepted';
  static const String orderAlreadyDeclined = 'order.already_declined';
  static const String orderNotAssignedToDriver = 'order.not_assigned_to_driver';
  static const String orderDeclineReasonRequired = 'order.decline_reason_required';
  static const String orderProofRequired = 'order.proof_required';
  static const String orderProofNotFound = 'order.proof_not_found';
  static const String orderTrackingFailed = 'order.tracking_failed';
  static const String orderTemplateFailed = 'order.template_failed';
  static const String orderMissingPublicId = 'order.missing_public_id';
  static const String orderReleaseFailed = 'order.release_failed';
  static const String orderAlreadyTaken = 'order.already_taken';
  static const String orderClaimFailed = 'order.claim_failed';
  static const String orderCodRequiresPrice = 'order.cod_requires_price';
  static const String orderCustomFieldsUnavailable =
      'order.custom_fields_unavailable';
  static const String orderAlreadyPublished = 'order.already_published';
  static const String orderPublishFailed = 'order.publish_failed';
  static const String orderAcceptFailed = 'order.accept_failed';
  static const String orderStartFailed = 'order.start_failed';
  static const String orderCompleteFailed = 'order.complete_failed';
  static const String orderActivitiesFetchFailed = 'order.activities_fetch_failed';
  static const String orderActivityUpdateFailed = 'order.activity_update_failed';
  static const String orderProofUploadFailed = 'order.proof_upload_failed';
  static const String orderNotFoundUpstream = 'order.not_found_upstream';

  // ── Transporteurs ────────────────────────────────────────────────────────
  static const String driverNotFound = 'driver.not_found';
  static const String driverForbidden = 'driver.forbidden';
  static const String driverFetchFailed = 'driver.fetch_failed';
  static const String driverCreateFailed = 'driver.create_failed';
  static const String driverPositionsFetchFailed = 'driver.positions_fetch_failed';
  static const String driverInactive = 'driver.inactive';
  static const String driverUnavailable = 'driver.unavailable';
  static const String driverPublicIdUnresolved = 'driver.public_id_unresolved';
  static const String driverPositionUpdateFailed = 'driver.position_update_failed';
  static const String driverOnlineToggleFailed = 'driver.online_toggle_failed';
  static const String driverSearchUnavailable = 'driver.search_unavailable';

  // ── Flotte (persona petite flotte) ──────────────────────────────────────
  static const String fleetNotFound = 'fleet.not_found';
  static const String fleetInactive = 'fleet.inactive';

  // ── Commerçant ───────────────────────────────────────────────────────────
  static const String merchantNotFound = 'merchant.not_found';
  static const String merchantInactive = 'merchant.inactive';
  static const String merchantAddressNotFound = 'merchant.address_not_found';
  static const String merchantFavouriteNotFound = 'merchant.favourite_not_found';
  static const String merchantFavouriteAlreadyExists = 'merchant.favourite_already_exists';
  static const String merchantDriverNotInNetwork = 'merchant.driver_not_in_network';
  static const String merchantFavouriteAddUnavailable = 'merchant.favourite_add_unavailable';
  static const String merchantAddressSaveFailed = 'merchant.address_save_failed';
  static const String merchantAddressUpdateFailed = 'merchant.address_update_failed';
  static const String merchantAddressDeleteFailed = 'merchant.address_delete_failed';

  // ── Signalements et notifications ───────────────────────────────────────
  static const String notificationNotFound = 'notification.not_found';

  // ── Géocodage ────────────────────────────────────────────────────────────
  static const String geocodingUnavailable = 'geocoding.unavailable';

  // ── Validation générique ─────────────────────────────────────────────────
  static const String validationInvalidId = 'validation.invalid_id';
  static const String validationFailed = 'validation.failed';

  // ── Erreurs serveur / techniques ─────────────────────────────────────────
  static const String serverSchemaOutOfSync = 'server.schema_out_of_sync';
  static const String serverInvalidProfileType = 'server.invalid_profile_type';
  static const String serverPersonaForbidden = 'server.persona_forbidden';

  // ── Constats du client, sans contrepartie serveur ───────────────────────
  static const String networkError = 'network.error';
  static const String serverError = 'server.error';
  static const String timeoutError = 'timeout.error';
  static const String notFound = 'not_found';
  static const String unknown = 'error.unknown';
  static const String locationPermissionDenied = 'location.permission_denied';
  static const String foregroundServiceDenied = 'location.foreground_service_denied';
  static const String photoCameraUnavailable = 'photo.camera_unavailable';
  static const String photoEmpty = 'photo.empty';
  static const String photoTooLarge = 'photo.too_large';
  static const String fleetProfileUnavailable = 'client.fleet_profile_unavailable';
  static const String multipleProfilesMatch = 'client.multiple_profiles_match';
}

/// Exception wrapper pour les erreurs d'app avec mappage d'erreurs.
class AppException implements Exception {
  final String code;
  final String? message;
  final dynamic originalError;

  AppException({
    required this.code,
    this.message,
    this.originalError,
  });

  @override
  String toString() => message ?? code;
}
