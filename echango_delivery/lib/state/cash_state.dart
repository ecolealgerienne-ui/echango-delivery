import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/cash.dart';
import '../services/bff_api_client.dart';

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

  /// `driver` ou `merchant`.
  String _persona = 'driver';

  CashLedger? _ledger;
  List<CashRemittance> _remittances = [];
  bool _isLoading = false;
  String? _errorMessage;

  CashState({required BffApiClient apiClient}) : _apiClient = apiClient;

  CashLedger? get ledger => _ledger;
  List<CashRemittance> get remittances => _remittances;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

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
    notifyListeners();
  }

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final isDriver = _persona == 'driver';
      _ledger = isDriver
          ? await _apiClient.getDriverCashLedger()
          : await _apiClient.getMerchantCashLedger();
      _remittances = isDriver
          ? await _apiClient.getDriverRemittances()
          : await _apiClient.getMerchantRemittances();
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Chargement du registre impossible';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Déclare une remise. [counterpartyId] est l'autre partie : un commerçant
  /// vu du transporteur, un transporteur vu du commerçant.
  Future<bool> declareRemittance(String counterpartyId, double amount) =>
      _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.declareDriverRemittance(
            merchantId: counterpartyId,
            amount: amount,
          );
        } else {
          await _apiClient.declareMerchantRemittance(
            driverId: counterpartyId,
            amount: amount,
          );
        }
      }, 'Déclaration impossible');

  Future<bool> confirmRemittance(String id) => _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.confirmDriverRemittance(id);
        } else {
          await _apiClient.confirmMerchantRemittance(id);
        }
      }, 'Confirmation impossible');

  Future<bool> disputeRemittance(String id, {String? reason}) => _mutate(() async {
        if (_persona == 'driver') {
          await _apiClient.disputeDriverRemittance(id, reason: reason);
        } else {
          await _apiClient.disputeMerchantRemittance(id, reason: reason);
        }
      }, 'Contestation impossible');

  /// Toute écriture est suivie d'une relecture complète.
  ///
  /// Le solde n'est jamais recalculé localement : il est **dérivé côté serveur**
  /// des encaissements et des remises confirmées, et l'ajuster ici en parallèle
  /// créerait deux vérités dont rien ne dirait laquelle est la bonne. Sur de
  /// l'argent, la divergence n'est pas un détail d'affichage.
  Future<bool> _mutate(Future<void> Function() action, String fallback) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await action();
      await load();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = fallback;
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
