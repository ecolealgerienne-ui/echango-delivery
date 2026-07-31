import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../errors/error_translator.dart';
import '../models/cash.dart';
// `DriverSearchResult` / `KnownDriver` : l'annuaire est celui du commerçant,
// et il sert ici à désigner qui a effectué une course non attribuée.
import '../models/merchant_order.dart' show DriverSearchResult;
import '../services/bff_api_client.dart';
import 'locale_state.dart';

/// Registre de caisse, partagé par les deux profils.
///
/// ── Une seule classe pour deux points de vue ────────────────────────────────
///
/// Transporteur et commerçant regardent **le même registre depuis les deux
/// bouts** : ce que l'un doit est ce que l'autre attend. Les mêmes remises, les
/// mêmes montants, les mêmes confirmations. Deux états séparés auraient fini
/// par diverger sur la seule chose qui doit être commune — le sens de « qui
/// doit combien à qui ».
///
/// [persona] dit de quel bout on regarde, et il détermine deux choses : quelles
/// routes appeler, et quelles remises appellent une action de l'utilisateur
/// (jamais les siennes — le serveur refuse qu'on confirme sa propre
/// déclaration).
class CashState extends ChangeNotifier {
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  /// `driver` ou `merchant`.
  String _persona = 'driver';

  CashLedger? _ledger;
  List<CashRemittance> _remittances = [];

  /// Les encaissements, livraison par livraison.
  ///
  /// Le solde affiché en tête est une **somme de différences** : perçu moins
  /// retenu, moins les remises confirmées. Sans le détail, il ne se vérifie
  /// pas — et c'est pourtant ce qu'on contrôle avant de confirmer une remise,
  /// geste qui éteint une dette.
  List<CashCollectionEntry> _collections = [];

  /// Ce qui sera réclamé aux portes et n'est encore dans la poche de personne.
  ///
  /// Commerçant seulement : le transporteur, lui, sait ce qu'il a à collecter
  /// en regardant ses courses — c'est son écran de travail. Le commerçant n'a
  /// aucun autre endroit où lire ce chiffre.
  PendingCollections _pending = const PendingCollections();
  bool _isLoading = false;
  String? _errorMessage;

  CashState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  /// Message d'erreur générique de la langue courante, pour les échecs qui ne
  /// portent aucun `code` serveur (erreur de parsing, exception inattendue).
  String get _genericError => translateErrorCode(AppError.unknown, _localeState.locale);

  CashLedger? get ledger => _ledger;
  List<CashRemittance> get remittances => _remittances;
  List<CashCollectionEntry> get collections => _collections;
  /// Livraisons en route dont l'argent sera réclamé à une porte.
  List<PendingCollection> get pending => _pending.inFlight;

  /// Livraisons terminées dont **aucun encaissement n'a été déclaré**.
  ///
  /// Séparé de [pending] parce que ce n'est pas la même chose du tout : l'un
  /// est le cours normal des choses, l'autre est une anomalie qui appelle un
  /// appel au transporteur.
  List<PendingCollection> get unrecorded => _pending.unrecorded;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// Total attendu aux portes. Distinct de [total], et il ne faut jamais les
  /// additionner : l'un est détenu par quelqu'un, l'autre ne l'est par
  /// personne.
  double get expectedTotal => _pending.expectedTotal;

  /// Total livré sans encaissement enregistré. À ne mélanger ni avec l'un ni
  /// avec l'autre : c'est un montant dont on ignore s'il a été perçu.
  double get unrecordedTotal => _pending.unrecordedTotal;

  /// Remises en attente de MA confirmation.
  ///
  /// Ce sont les seules qui appellent un geste : celles que j'ai déclarées
  /// attendent l'autre, et les afficher comme actionnables promettrait un
  /// bouton que le serveur rejetterait.
  List<CashRemittance> get awaitingMyConfirmation =>
      _remittances.where((r) => r.awaitsActionFrom(_persona)).toList();

  /// Remises que j'ai déclarées et qui attendent l'autre partie.
  List<CashRemittance> get awaitingOther =>
      _remittances.where((r) => r.isPending && r.declaredBy == _persona).toList();

  /// Dette totale, tous comptes confondus.
  ///
  /// Utile comme repère, jamais comme somme à régler : elle ne se paie pas d'un
  /// coup, puisqu'elle est due à plusieurs personnes différentes.
  double get total => _ledger?.total ?? 0;

  String get currency => _ledger?.currency ?? '';

  void setPersona(String persona) {
    if (_persona == persona) return;
    _persona = persona;
    // Le registre de l'ancien profil n'a plus de sens : le garder ferait
    // afficher les dettes de quelqu'un d'autre le temps d'un chargement.
    _ledger = null;
    _remittances = [];
    _collections = [];
    _pending = const PendingCollections();
    notifyListeners();
  }

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // Trois personas et non plus deux : l'entreprise de transport est une
      // partie du registre au même titre que les deux autres, et sans ses
      // routes une dette envers elle ne serait confirmable par personne.
      final isDriver = _persona == 'driver';
      final isFleet = _persona == 'fleet';
      _ledger = isDriver
          ? await _apiClient.getDriverCashLedger()
          : isFleet
              ? await _apiClient.getFleetCashLedger()
              : await _apiClient.getMerchantCashLedger();
      _remittances = isDriver
          ? await _apiClient.getDriverRemittances()
          : isFleet
              ? await _apiClient.getFleetRemittances()
              : await _apiClient.getMerchantRemittances();
      // Le détail ne conditionne pas l'écran : un total sans son détail reste
      // lisible, alors qu'une page en erreur ne l'est pas. On l'affiche donc
      // s'il arrive, et on se tait s'il manque.
      _collections = isDriver
          ? await _apiClient.getDriverCollections().catchError(
              (_) => <CashCollectionEntry>[])
          : isFleet
              ? await _apiClient.getFleetCollections().catchError(
                  (_) => <CashCollectionEntry>[])
              : await _apiClient.getMerchantCollections().catchError(
                  (_) => <CashCollectionEntry>[]);

      // ⚠️ Pas de `catchError` silencieux ici, contrairement au détail.
      //
      // Un détail manquant laisse un total lisible ; un « attendu » manquant
      // laisse l'écran affirmer qu'aucune somme n'est en attente, ce qui est
      // exactement l'erreur qu'on corrige. Mieux vaut le message d'erreur que
      // la fausse tranquillité — d'où la liste vidée ET l'erreur remontée.
      // « L'argent attendu aux portes » est une lecture propre au commerçant :
      // c'est SA marchandise qui est en route. Ni le conducteur ni l'entreprise
      // n'ont d'équivalent — leur exposition se lit dans les soldes.
      _pending = isDriver || isFleet
          ? const PendingCollections()
          : await _apiClient.getMerchantPendingCollections();
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
    } catch (e) {
      _errorMessage = _genericError;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Encaissements déclarés par le commerçant et qui attendent MA confirmation.
  ///
  /// Transporteur uniquement. Vus du commerçant, ce sont ses propres
  /// déclarations : les lui présenter comme actionnables promettrait un bouton
  /// que le serveur refuserait, exactement comme pour les remises.
  List<CashCollectionEntry> get collectionsToConfirm => _persona == 'driver'
      ? _collections.where((c) => c.awaitsDriverConfirmation).toList()
      : const [];

  /// Régularise une livraison close hors application.
  ///
  /// Renvoie `true` si la déclaration est enregistrée — elle attend alors la
  /// confirmation du transporteur et ne change encore aucune dette.
  Future<bool> declareMissingCollection({
    required String orderId,
    required double collectedAmount,
    String? fleetbaseDriverUuid,
    String? discrepancyReason,
    String? notes,
  }) =>
      _mutate(() => _apiClient.declareMissingCollection(
            orderId: orderId,
            collectedAmount: collectedAmount,
            fleetbaseDriverUuid: fleetbaseDriverUuid,
            discrepancyReason: discrepancyReason,
            notes: notes,
          ));

  /// Cherche un transporteur du réseau, pour désigner celui d'une course qui
  /// n'en nomme aucun.
  ///
  /// Exposée ici plutôt qu'appelée directement par l'écran : `CashState` porte
  /// déjà le client, et un second accès au réseau depuis un widget aurait
  /// contourné la traduction d'erreur commune.
  Future<DriverSearchResult> searchDrivers(String query) =>
      _apiClient.searchDrivers(query);

  Future<bool> confirmCollection(String id) =>
      _mutate(() => _apiClient.confirmDeclaredCollection(id));

  Future<bool> disputeCollection(String id, {String? reason}) =>
      _mutate(() => _apiClient.disputeDeclaredCollection(id, reason: reason));

  /// Déclare une remise. [counterpartyId] est l'autre partie : un commerçant
  /// vu du transporteur, un transporteur vu du commerçant.
  Future<bool> declareRemittance(String counterpartyId, double amount) =>
      _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.declareDriverRemittance(
            merchantId: counterpartyId,
            amount: amount,
          );
        } else if (_persona == 'fleet') {
          await _apiClient.declareFleetRemittance(
            counterpartyId: counterpartyId,
            amount: amount,
          );
        } else {
          await _apiClient.declareMerchantRemittance(
            driverId: counterpartyId,
            amount: amount,
          );
        }
      });

  Future<bool> confirmRemittance(String id) => _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.confirmDriverRemittance(id);
        } else if (_persona == 'fleet') {
          await _apiClient.confirmFleetRemittance(id);
        } else {
          await _apiClient.confirmMerchantRemittance(id);
        }
      });

  Future<bool> disputeRemittance(String id, {String? reason}) => _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.disputeDriverRemittance(id, reason: reason);
        } else if (_persona == 'fleet') {
          await _apiClient.disputeFleetRemittance(id, reason: reason);
        } else {
          await _apiClient.disputeMerchantRemittance(id, reason: reason);
        }
      });

  /// Toute écriture est suivie d'une relecture complète.
  ///
  /// Le solde n'est jamais recalculé localement : il est **dérivé côté serveur**
  /// des encaissements et des remises confirmées, et l'ajuster ici en parallèle
  /// créerait deux vérités dont rien ne dirait laquelle est la bonne. Sur de
  /// l'argent, la divergence n'est pas un détail d'affichage.
  Future<bool> _mutate(Future<void> Function() action) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await action();
      await load();
      return true;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _localeState.locale);
      return false;
    } catch (e) {
      _errorMessage = _genericError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
