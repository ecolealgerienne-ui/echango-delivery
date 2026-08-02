import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Locale;

import '../models/fleet_driver_position.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';
import 'paged_list.dart';
import '../errors/error_message.dart';

/// Le résultat d'une lecture de fiche : la course, ou la raison de son absence.
class FleetOrderDetail {
  const FleetOrderDetail({this.order, this.error});

  final Map<String, dynamic>? order;
  final String? error;
}

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
/// **Courses libres** : celles que personne n'a prises, servies sans le nom ni
/// le téléphone du destinataire tant que l'entreprise ne s'est pas engagée.
/// Les garder séparées n'est pas cosmétique : ce sont deux niveaux de détail
/// différents, et les fusionner ferait croire à une donnée manquante là où il y
/// a un masquage délibéré.
class FleetState extends ChangeNotifier {
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  FleetState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  /// ⚠️ **Les deux listes étaient tronquées à la première page**, en silence.
  ///
  /// Le serveur pagine (`flotte.service.ts` : `query.limit || 25`) et rend le
  /// total ; l'app demandait la page 1 et jetait le reste de la réponse. Une
  /// entreprise passé sa vingt-cinquième course ne voyait plus les
  /// précédentes — et rien ne le disait, ce qui est le pire cas : une liste
  /// tronquée sans mention se lit comme une liste complète. C'est exactement le
  /// défaut corrigé côté commerçant le 29/07/2026, resté ici.
  ///
  /// Le mécanisme est partagé (`PagedList`) et non recopié : si la règle de
  /// pagination change, elle doit changer pour les trois listes (règle 5).
  final PagedList<Map<String, dynamic>> _ordersPage = PagedList<Map<String, dynamic>>();
  final PagedList<Map<String, dynamic>> _opportunitiesPage =
      PagedList<Map<String, dynamic>>();
  List<Map<String, dynamic>> _drivers = [];
  List<FleetDriverPosition> _positions = [];
  bool _positionsLoading = false;
  String? _positionsError;
  List<Map<String, dynamic>> _memberships = [];
  bool _membershipsUnavailable = false;

  bool _isLoading = false;
  String? _errorMessage;

  /// ⚠️ La liste des conducteurs a-t-elle **échoué**, ou est-elle vraiment vide ?
  ///
  /// Le repli `catchError` ci-dessous rend une liste vide sur erreur, pour que
  /// l'écran affiche quand même les deux autres onglets. Sans ce drapeau, une
  /// entreprise dont le BFF est injoignable s'entendait dire « aucun conducteur
  /// rattaché à votre entreprise » — une affirmation possiblement fausse, au
  /// moment précis où elle veut désigner quelqu'un.
  bool _driversUnavailable = false;
  /// La lecture des courses libres a-t-elle échoué ?
  ///
  /// ⚠️ Sans lui, l'onglet affirmait « Aucune course libre pour le moment » sur
  /// un 500 — sans bandeau ni bouton de reprise, **sur l'onglet où une
  /// entreprise vient chercher du travail**. Elle en concluait que le réseau
  /// était vide et refermait l'application.
  ///
  /// Quatrième occurrence de la règle 10 sous cette forme, et la plus gênante :
  /// elle est dans le fichier même où les deux autres listes portent déjà leur
  /// drapeau, dix lignes plus bas.
  bool _opportunitiesUnavailable = false;

  /// Course en cours de prise, pour que le bouton concerné seul se désactive.
  /// Un indicateur global ferait clignoter toute la liste à chaque geste.
  String? _claimingOrderId;

  List<Map<String, dynamic>> get orders => _ordersPage.items;
  List<Map<String, dynamic>> get opportunities => _opportunitiesPage.items;
  List<Map<String, dynamic>> get drivers => List.unmodifiable(_drivers);

  List<FleetDriverPosition> get driverPositions => List.unmodifiable(_positions);
  bool get driverPositionsLoading => _positionsLoading;
  String? get driverPositionsError => _positionsError;

  bool get hasMoreOrders => _ordersPage.hasMore;
  bool get isLoadingMoreOrders => _ordersPage.isLoadingMore;
  bool get hasMoreOpportunities => _opportunitiesPage.hasMore;
  bool get isLoadingMoreOpportunities => _opportunitiesPage.isLoadingMore;

  bool get isLoading => _isLoading;
  bool get driversUnavailable => _driversUnavailable;
  bool get opportunitiesUnavailable => _opportunitiesUnavailable;
  List<Map<String, dynamic>> get memberships => List.unmodifiable(_memberships);
  bool get membershipsUnavailable => _membershipsUnavailable;
  String? get errorMessage => _errorMessage;
  String? get claimingOrderId => _claimingOrderId;

  Locale get _locale => _localeState.locale;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final ordersPage = await _apiClient.getFleetOrders(
        page: 1,
        limit: _ordersPage.pageSize,
      );
      _ordersPage.reset(_rows(ordersPage), _total(ordersPage));

      // ⚠️ Chacune de ces deux lectures a son propre repli.
      //
      // Une entreprise sans conducteur, ou sans opportunité disponible, doit
      // quand même voir ses courses. Faire échouer l'écran entier parce qu'une
      // des trois listes manque, c'est cacher les deux autres — et le
      // diagnostic devient « l'espace flotte ne marche pas ».
      _opportunitiesUnavailable = false;
      final opportunitiesPage = await _apiClient
          .getFleetOpportunities(page: 1, limit: _opportunitiesPage.pageSize)
          .catchError((_) {
        // Le repli reste — une liste qui manque ne doit pas cacher les deux
        // autres — mais il POSE SON DRAPEAU. Un repli muet ne dit pas « vide »,
        // il dit « je n'ai pas pu savoir », et c'est à l'écran de le distinguer.
        _opportunitiesUnavailable = true;
        return <String, dynamic>{};
      });
      _opportunitiesPage.reset(_rows(opportunitiesPage), _total(opportunitiesPage));

      _driversUnavailable = false;
      _drivers = await _apiClient.getFleetDrivers().catchError((_) {
        _driversUnavailable = true;
        return <Map<String, dynamic>>[];
      });
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Charge la page suivante des courses de l'entreprise.
  Future<void> loadMoreOrders() async {
    if (!_ordersPage.beginLoadMore()) return;
    notifyListeners();

    try {
      final page = await _apiClient.getFleetOrders(
        page: _ordersPage.nextPage,
        limit: _ordersPage.pageSize,
      );
      _ordersPage.append(_rows(page), _total(page));
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
    } finally {
      _ordersPage.endLoadMore();
      notifyListeners();
    }
  }

  /// Où sont les conducteurs, maintenant.
  ///
  /// ── Chargée à la demande, et jamais avec le reste ─────────────────────────
  ///
  /// `load()` sert les trois listes à l'ouverture de l'écran. Y ajouter les
  /// positions ferait télécharger la flotte entière — et les tuiles de carte
  /// avec elle — à chaque visite, y compris pour consulter une course. C'est le
  /// défaut corrigé le 30/07 côté commerçant, où la carte se chargeait à chaque
  /// ouverture de fiche : la position est une question qu'on pose, pas une
  /// donnée qu'on ramène en passant.
  ///
  /// ⚠️ **L'échec ne se confond pas avec l'absence.** Rendre une liste vide sur
  /// erreur ferait afficher « aucun conducteur n'a remonté de position » à une
  /// entreprise dont le BFF est injoignable — une affirmation possiblement
  /// fausse, au moment précis où elle cherche quelqu'un. C'est le défaut le
  /// plus répété de ce projet, et il a déjà été payé deux fois sur cet écran.
  Future<void> loadDriverPositions() async {
    _positionsLoading = true;
    _positionsError = null;
    notifyListeners();

    try {
      _positions = await _apiClient.getFleetDriverPositions();
    } catch (e) {
      _positionsError = messageForError(e, _locale);
    } finally {
      _positionsLoading = false;
      notifyListeners();
    }
  }

  /// Charge la page suivante des courses libres.
  Future<void> loadMoreOpportunities() async {
    if (!_opportunitiesPage.beginLoadMore()) return;
    notifyListeners();

    try {
      final page = await _apiClient.getFleetOpportunities(
        page: _opportunitiesPage.nextPage,
        limit: _opportunitiesPage.pageSize,
      );
      _opportunitiesPage.append(_rows(page), _total(page));
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
    } finally {
      _opportunitiesPage.endLoadMore();
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> page) {
    final data = page['data'];
    if (data is! List) return const [];
    return data.whereType<Map<String, dynamic>>().toList();
  }

  /// Le total annoncé par le serveur.
  ///
  /// ⚠️ **Zéro par défaut, et c'est le bon défaut.** Un total absent rend
  /// `hasMore` faux, donc pas de bouton « charger plus » — l'app s'en tient à ce
  /// qu'elle a reçu. Le défaut inverse (« on ne sait pas, donc il y en a
  /// peut-être ») afficherait un bouton qui ne rapporte rien, et le
  /// rafficherait à chaque appui.
  int _total(Map<String, dynamic> page) {
    final pagination = page['pagination'];
    if (pagination is! Map) return 0;
    return (pagination['total'] as num?)?.toInt() ?? 0;
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
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
      return _errorMessage;
    } finally {
      _claimingOrderId = null;
      notifyListeners();
    }
  }

  /// La fiche d'une course, et **ce qui a manqué** si elle n'a pas pu être lue.
  ///
  /// Rendre `null` sans distinguer l'absence de l'erreur ferait afficher « cette
  /// course n'est plus disponible » sur un simple réseau coupé — un message qui
  /// affirme un fait faux, et le défaut le plus répété de ce projet.
  Future<FleetOrderDetail> fetchOrder(String orderId, {required bool unclaimed}) async {
    try {
      final order = unclaimed
          ? await _apiClient.getFleetOpportunityDetail(orderId)
          : await _apiClient.getFleetOrderDetail(orderId);
      return FleetOrderDetail(order: order);
    } catch (e) {
      return FleetOrderDetail(error: messageForError(e, _locale));
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
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
      return _errorMessage;
    }
  }

  /// Chercher un conducteur déjà dans le réseau.
  ///
  /// Rend la liste, ou lève le message traduit — la distinction compte : « aucun
  /// résultat » et « recherche trop large » sont deux réponses différentes, et
  /// les confondre ferait chercher plus longtemps quelqu'un qu'on a déjà trouvé
  /// dix fois.
  Future<({List<Map<String, dynamic>> results, String? error})> searchNetworkDrivers(
    String query,
  ) async {
    try {
      final results = await _apiClient.searchNetworkDrivers(query);
      return (results: results, error: null);
    } catch (e) {
      return (
        results: <Map<String, dynamic>>[],
        error: messageForError(e, _locale),
      );
    }
  }

  /// Demander le rattachement d'un conducteur existant.
  Future<String?> requestMembership(String driverUuid) async {
    try {
      await _apiClient.requestDriverMembership(driverUuid);
      await loadMemberships();
      return null;
    } catch (e) {
      return messageForError(e, _locale);
    }
  }

  /// Les rattachements — demandés, actifs, refusés, suspendus.
  ///
  /// ⚠️ Distinct de `drivers` et il faut que ça le reste : `drivers` répond « à
  /// qui puis-je confier une course », les adhésions répondent « où en est ma
  /// demande ». Les fusionner ferait apparaître dans le sélecteur de conducteur
  /// des gens qui n'ont pas encore accepté.
  Future<void> loadMemberships() async {
    try {
      _memberships = await _apiClient.getFleetMemberships();
      _membershipsUnavailable = false;
    } catch (e) {
      _membershipsUnavailable = true;
      _errorMessage = messageForError(e, _locale);
    }
    notifyListeners();
  }

  Future<String?> setMembershipSuspended(String membershipId, bool suspended) async {
    try {
      await _apiClient.setFleetMembershipSuspended(membershipId, suspended);
      await load();
      await loadMemberships();
      return null;
    } catch (e) {
      return messageForError(e, _locale);
    }
  }

  /// Désigner un conducteur sur une course de l'entreprise.
  Future<String?> assignDriver(String orderId, String driverUuid) async {
    try {
      await _apiClient.assignFleetDriver(orderId, driverUuid);
      await load();
      return null;
    } catch (e) {
      _errorMessage = messageForError(e, _locale);
      return _errorMessage;
    }
  }
}
