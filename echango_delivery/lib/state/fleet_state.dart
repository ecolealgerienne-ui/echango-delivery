import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale;

import '../errors/app_error.dart';
import '../errors/error_translator.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';

/// État du profil « entreprise de transport ».
///
/// ── Ce que cette classe répare ──────────────────────────────────────────────
///
/// Le module BFF `flotte` existe depuis le 28/07 — six routes, cinq validées par
/// test réel avec deux flottes distinctes — et **l'application n'en appelait
/// aucune** : elle affichait « Espace non disponible » (défaut D20). C'est le
/// fil rouge du projet pris à l'envers, celui que CLAUDE.md résume par « le
/// serveur savait, l'app ignorait ».
///
/// ── Deux listes, et elles ne se mélangent pas ───────────────────────────────
///
/// **Mes courses** : celles confiées à cette entreprise, complètes, sur
/// lesquelles elle désigne un conducteur.
/// **Courses libres** : celles que personne n'a prises, servies **expurgées** —
/// la livraison réduite à sa commune tant que l'entreprise ne s'est pas engagée.
/// Les garder séparées n'est pas cosmétique : ce sont deux niveaux de détail
/// différents, et les fusionner ferait croire à une donnée manquante là où il y
/// a une expurgation délibérée.
class FleetState extends ChangeNotifier {
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  FleetState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  List<Map<String, dynamic>> _orders = [];
  List<Map<String, dynamic>> _opportunities = [];
  List<Map<String, dynamic>> _drivers = [];

  bool _isLoading = false;
  String? _errorMessage;

  /// Course en cours de prise, pour que le bouton concerné seul se désactive.
  /// Un indicateur global ferait clignoter toute la liste à chaque geste.
  String? _claimingOrderId;

  List<Map<String, dynamic>> get orders => List.unmodifiable(_orders);
  List<Map<String, dynamic>> get opportunities => List.unmodifiable(_opportunities);
  List<Map<String, dynamic>> get drivers => List.unmodifiable(_drivers);
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  String? get claimingOrderId => _claimingOrderId;

  Locale get _locale => _localeState.locale;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final ordersPage = await _apiClient.getFleetOrders();
      _orders = _rows(ordersPage);

      // ⚠️ Chacune de ces deux lectures a son propre repli.
      //
      // Une entreprise sans conducteur, ou sans opportunité disponible, doit
      // quand même voir ses courses. Faire échouer l'écran entier parce qu'une
      // des trois listes manque, c'est cacher les deux autres — et le
      // diagnostic devient « l'espace flotte ne marche pas ».
      _opportunities = await _apiClient
          .getFleetOpportunities()
          .then(_rows)
          .catchError((_) => <Map<String, dynamic>>[]);

      _drivers = await _apiClient
          .getFleetDrivers()
          .catchError((_) => <Map<String, dynamic>>[]);
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _locale);
    } catch (_) {
      _errorMessage = translateErrorCode(AppError.unknown, _locale);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> page) {
    final data = page['data'];
    if (data is! List) return const [];
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// Prendre une course du pool.
  ///
  /// Rend `null` en cas de succès, ou le message d'erreur traduit. Le second
  /// arrivant reçoit `order.already_taken` — le serveur relit après écriture,
  /// Fleetbase n'offrant aucune écriture conditionnelle.
  Future<String?> claim(String orderId) async {
    _claimingOrderId = orderId;
    notifyListeners();

    try {
      await _apiClient.claimFleetOrder(orderId);
      // Rechargement complet plutôt que retrait local de la ligne : la course
      // passe d'une liste à l'autre, et deux listes tenues à la main finissent
      // par diverger. Le coût est un aller-retour, la contrepartie est qu'on
      // affiche ce que le serveur dit et non ce qu'on suppose.
      await load();
      return null;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _locale);
      return _errorMessage;
    } catch (_) {
      _errorMessage = translateErrorCode(AppError.unknown, _locale);
      return _errorMessage;
    } finally {
      _claimingOrderId = null;
      notifyListeners();
    }
  }

  /// Créer un conducteur et le rattacher à l'entreprise.
  Future<String?> addDriver({
    required String name,
    required String email,
    String? phone,
  }) async {
    try {
      await _apiClient.addFleetDriver(name: name, email: email, phone: phone);
      await load();
      return null;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _locale);
      return _errorMessage;
    } catch (_) {
      _errorMessage = translateErrorCode(AppError.unknown, _locale);
      return _errorMessage;
    }
  }

  /// Désigner un conducteur sur une course de l'entreprise.
  Future<String?> assignDriver(String orderId, String driverUuid) async {
    try {
      await _apiClient.assignFleetDriver(orderId, driverUuid);
      await load();
      return null;
    } on AppException catch (e) {
      _errorMessage = translateErrorCode(e.code, _locale);
      return _errorMessage;
    } catch (_) {
      _errorMessage = translateErrorCode(AppError.unknown, _locale);
      return _errorMessage;
    }
  }
}
