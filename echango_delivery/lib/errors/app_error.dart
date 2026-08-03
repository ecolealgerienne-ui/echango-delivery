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

  /// L'entreprise visée n'a pas de compte actif dans le réseau Echango.
  static const String merchantFleetNotInNetwork = 'merchant.fleet_not_in_network';

  // ── Encaissement à la porte ─────────────────────────────────────────────
  //
  // ⚠️ Vingt-cinq codes vivaient ici — remises, confirmations, plafonds,
  // contreparties. Retirés le 03/08/2026 avec le registre de caisse
  // (`docs/registre_caisse_precis.md`). Les cinq qui restent portent tous sur
  // un seul geste : ce que le transporteur déclare avoir perçu en clôturant.
  static const String cashCodDeclarationRequired = 'cash.cod_declaration_required';
  static const String cashAmountNegative = 'cash.amount_negative';
  static const String cashAmountExceedsExpected = 'cash.amount_exceeds_expected';
  static const String cashDiscrepancyReasonRequired = 'cash.discrepancy_reason_required';
  /// La déclaration n'a pas pu être écrite sur la commande : la livraison reste
  /// ouverte, et le transporteur doit réessayer plutôt que continuer.
  static const String cashCollectionNotRecorded = 'cash.collection_not_recorded';

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
  static const String driverSearchTooBroad = 'driver.search_too_broad';
  static const String driverAlreadyInNetwork = 'driver.already_in_network';

  // ── Adhésions conducteur ↔ entreprise ───────────────────────────────────
  //
  // Un rattachement décide **à qui le conducteur devra les espèces** d'une
  // course : ce ne sont pas des codes administratifs.
  static const String membershipNotFound = 'membership.not_found';
  static const String membershipAlreadyExists = 'membership.already_exists';
  static const String membershipNotPending = 'membership.not_pending';
  static const String membershipNotActive = 'membership.not_active';
  static const String membershipNotSuspended = 'membership.not_suspended';

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

  /// Le carnet d'adresses n'a pas pu être lu.
  ///
  /// ⚠️ Le serveur rendait auparavant une liste **vide** en HTTP 200 quand
  /// Fleetbase était injoignable : l'écran affichait « aucune adresse
  /// enregistrée » à quelqu'un qui en a deux, et l'invitait à en ressaisir une.
  /// Ce code permet enfin d'afficher `AppEmptyState.unavailable`.
  static const String merchantAddressesUnavailable = 'merchant.addresses_unavailable';

  /// L'historique des transporteurs déjà employés n'a pas pu être lu.
  static const String merchantKnownDriversUnavailable =
      'merchant.known_drivers_unavailable';

  /// Panne non prévue côté serveur — tout ce qui n'est pas un refus délibéré.
  ///
  /// ⚠️ Existe depuis que le filtre d'exception du BFF attrape **toutes** les
  /// erreurs et non les seules `HttpException` : une `TypeError` ou une erreur
  /// de base sortait auparavant sans code, donc arrivait ici en
  /// [AppError.unknown]. Ce code la distingue — « le serveur a un problème »
  /// n'est pas « nous n'avons pas compris la réponse ».
  static const String serverUnexpected = 'server.unexpected';

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
