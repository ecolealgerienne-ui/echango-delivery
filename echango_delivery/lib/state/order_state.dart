import 'dart:async' show unawaited;
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../config/app_rules.dart';
import '../models/order.dart';
import '../services/bff_api_client.dart';
import 'detail_cache.dart';
import 'locale_state.dart';
import 'write_envelope.dart';
import '../errors/error_message.dart';

/// État de gestion des commandes pour le driver.
class OrderState extends ChangeNotifier with WriteEnvelope {

  // Les trois lignes que `WriteEnvelope` demande : le mixin sait écrire les
  // champs sans les posséder, donc les autres références à `_isLoading` et
  // `_errorMessage` de cette classe ne bougent pas.
  @override
  set busy(bool value) => _isLoading = value;
  @override
  set failure(String? value) => _errorMessage = value;
  @override
  Locale get writeLocale => _localeState.locale;
  final BffApiClient _apiClient;
  final LocaleState _localeState;

  List<Order> _orders = [];
  List<Order> _adhocOrders = [];
  List<Order> _historyOrders = [];
  Order? _selectedOrder;
  List<Map<String, dynamic>> _nextActivities = [];

  /// Fiches déjà lues, servies au tap sans spinner puis revalidées en fond.
  /// Une entrée porte la commande ET ses transitions : les boutons d'action
  /// dépendent des deux, les cacher séparément les désynchroniserait.
  final DetailCache<({Order order, List<Map<String, dynamic>> activities})>
      _detailCache = DetailCache(AppRules.orderDetailFreshness);

  /// La fiche en cours de revalidation de fond, s'il y en a une — pour ne pas
  /// en lancer deux sur la même commande.
  String? _revalidating;

  // ⚠️ **Deux attentes distinctes, et les confondre gelait la fiche.**
  //
  // `_isLoading` est ce qu'un écran regarde pour savoir qu'une opération PORTÉE
  // PAR L'UTILISATEUR est en cours — charger un détail, accepter, démarrer,
  // signaler. La fiche transporteur remplace alors ses boutons par un
  // indicateur (`_buildActionButtons`).
  //
  // `_listRefreshing` est le rafraîchissement de fond des trois listes
  // (`loadOrders`), déclenché par le tableau de bord au montage, par le
  // « tirer pour rafraîchir », et par le minuteur de présence toutes les 45 s.
  // Il ne concerne aucun écran de détail. Quand `loadOrders` levait
  // `_isLoading`, un rafraîchissement de fond — surtout après une acceptation,
  // qui enchaîne `selectOrder` PUIS `loadOrders` — laissait la fiche sur son
  // indicateur pendant les 8-15 s que prend `GET /transporteur/commandes` sur
  // un conducteur chargé, assez pour faire expirer le parcours d'intégration
  // (06/09/2026). Séparés, la fiche revient dès que `selectOrder` a fini.
  bool _isLoading = false;
  bool _listRefreshing = false;
  String? _errorMessage;

  OrderState({required BffApiClient apiClient, required LocaleState localeState})
      : _apiClient = apiClient,
        _localeState = localeState;

  // ⚠️ **Un `loadOrders()` en vol se résout APRÈS le dispose, et notifier un
  // `ChangeNotifier` détruit lève (03/08 documenté : « notifier une classe
  // d'état détruite »).** Le conducteur interroge le BFF en boucle
  // (`DriverPresenceState._pollTimer`) ; le timer est bien annulé au dispose,
  // mais `cancel()` n'interrompt pas un appel déjà parti attendre l'endpoint à
  // ~9 s. À son retour, l'`OrderState` peut être détruit — d'où ce garde, seul
  // endroit qui sait que l'objet ne vaut plus la peine d'être réveillé.
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Message d'erreur générique de la langue courante, pour les échecs qui ne
  /// portent aucun `code` serveur (erreur de parsing, exception inattendue).

  List<Order> get orders => _orders;
  Order? get selectedOrder => _selectedOrder;

  /// Transitions applicables à la commande sélectionnée, telles que résolues
  /// par le serveur contre l'OrderConfig et l'état courant.
  ///
  /// C'est la seule source légitime : le détail de commande ne contient
  /// aucune donnée d'activité (journal §6.9), et coder la machine à états
  /// côté client la ferait diverger de la configuration serveur.
  List<Map<String, dynamic>> get nextActivities => _nextActivities;

  /// Une opération portée par l'utilisateur est en cours sur le détail
  /// (chargement, écriture). PAS le rafraîchissement de fond des listes — voir
  /// [_listRefreshing].
  bool get isLoading => _isLoading;

  /// Les trois listes se rafraîchissent en arrière-plan. Le tableau de bord
  /// peut l'indiquer discrètement ; aucun écran de détail n'y réagit.
  bool get isRefreshingLists => _listRefreshing;
  String? get errorMessage => _errorMessage;

  /// Commandes assignées à ce driver et non terminées.
  List<Order> get activeOrders => _orders;

  /// Opportunités diffusées par le dispatch géospatial, pas encore réclamées
  /// (specs_app_transporteur.md §4.1). Elles ne sont assignées à personne :
  /// une vue filtrée sur les commandes du driver ne les montrerait jamais.
  List<Order> get adhocOrders => _adhocOrders;

  /// Commandes terminées ou annulées.
  List<Order> get historyOrders => _historyOrders;

  List<Order> get pendingOrders =>
      _orders.where((order) => order.isPending).toList();
  List<Order> get completedOrders => _historyOrders;

  /// Charge les trois catégories en un seul appel.
  ///
  /// Le BFF les renvoie ensemble sur `GET /transporteur/commandes` sans
  /// paramètre `type` — c'est ce qu'attend l'écran liste (§4.1). L'ancienne
  /// version ne demandait que `type=assigned` : les opportunités adhoc
  /// n'étaient donc jamais chargées, et l'écran restait vide tant qu'aucune
  /// commande n'était déjà assignée au driver.
  ///
  /// Le filtrage par driver est fait côté BFF, jamais par paramètre serveur —
  /// Fleetbase ignore les filtres non supportés et renverrait toute la
  /// compagnie (journal §2.8/§6.4).
  /// Recharge les trois listes.
  ///
  /// [surfaceErrors] : `true` quand c'est le tableau de bord qui demande
  /// (montage, tirer-pour-rafraîchir, minuteur de présence) — un échec doit
  /// alors s'afficher. `false` quand c'est le rafraîchissement de fond qui suit
  /// une écriture réussie ([_mutateOrder]) — poser `_errorMessage` y
  /// écraserait le retour de l'action, et alarmerait sur un geste que
  /// l'utilisateur n'a pas fait. Les listes gardent alors leur contenu.
  Future<void> loadOrders({bool surfaceErrors = true}) async {
    _listRefreshing = true;
    if (surfaceErrors) _errorMessage = null;
    _notify();

    try {
      final buckets = await _apiClient.getOrderBuckets();
      _orders = buckets['active'] ?? [];
      _adhocOrders = buckets['adhoc'] ?? [];
      _historyOrders = buckets['history'] ?? [];
    } catch (e) {
      if (surfaceErrors) {
        _errorMessage = messageForError(e, _localeState.locale);
      } else {
        debugPrint('loadOrders (fond) a échoué : '
            '${messageForError(e, _localeState.locale)}');
      }
    } finally {
      _listRefreshing = false;
      _notify();
    }
  }

  /// Charge les détails d'une commande.
  ///
  /// ── Cache 5 min, revalidé en fond ────────────────────────────────────────
  ///
  /// Une fiche vue il y a moins de [AppRules.orderDetailFreshness] est servie
  /// **immédiatement, sans spinner**, puis rafraîchie en silence ([_revalidate])
  /// — l'écran s'affiche instantané et se corrige en une ou deux secondes s'il
  /// y a lieu. Au-delà, ou fiche jamais vue : lecture bloquante normale.
  ///
  /// [force] saute le cache en lecture — utilisé par [_mutateOrder] après une
  /// écriture, où l'on veut l'état post-action et pas la version d'avant. Le
  /// résultat réalimente quand même le cache.
  Future<void> selectOrder(String orderId, {bool force = false}) async {
    if (!force) {
      final cached = _detailCache.fresh(orderId);
      if (cached != null) {
        _selectedOrder = cached.order;
        _nextActivities = cached.activities;
        _isLoading = false;
        _errorMessage = null;
        _notify();
        unawaited(_revalidate(orderId));
        return;
      }
    }

    _isLoading = true;
    _errorMessage = null;
    _notify();

    try {
      final detail = await _fetchDetail(orderId);
      _selectedOrder = detail.order;
      _nextActivities = detail.activities;
      _detailCache.put(orderId, detail);
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      // Introuvable ou erreur : ne pas continuer à servir cette fiche.
      _detailCache.evict(orderId);
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Le détail d'une commande et ses transitions serveur, en un objet. **Seul
  /// endroit** qui compose ces deux requêtes : [selectOrder] (bloquant) et
  /// [_revalidate] (fond) s'appuient dessus, pour qu'elles ne divergent pas
  /// (règle 5). Lève si `GET .../commandes/:id` échoue (commande introuvable
  /// comprise).
  Future<({Order order, List<Map<String, dynamic>> activities})> _fetchDetail(
      String orderId) async {
    final order = await _apiClient.getOrder(orderId);

    var activities = const <Map<String, dynamic>>[];
    // Une commande adhoc non réclamée n'a pas de transition : elle doit d'abord
    // être acceptée. Interroger le serveur renverrait une erreur.
    if (!(order.adhoc && order.driverId == null)) {
      try {
        activities = await _apiClient.getNextActivities(orderId);
      } catch (_) {
        // Transitions indisponibles : l'écran affiche le détail sans action
        // plutôt que d'échouer entièrement.
        activities = const [];
      }
    }
    return (order: order, activities: activities);
  }

  /// Rafraîchit en fond une fiche servie depuis le cache. Silencieux : un échec
  /// laisse à l'écran les données en cache (comme `loadOrders(surfaceErrors:
  /// false)`), il ne pose pas de bandeau sur une fiche que l'utilisateur
  /// regarde sans avoir rien demandé. N'écrase la sélection courante que si
  /// c'est toujours cette commande — l'utilisateur a pu revenir à la liste
  /// entre-temps.
  Future<void> _revalidate(String orderId) async {
    if (_revalidating == orderId) return;
    _revalidating = orderId;
    try {
      final detail = await _fetchDetail(orderId);
      _detailCache.put(orderId, detail);
      if (_selectedOrder?.id == orderId) {
        _selectedOrder = detail.order;
        _nextActivities = detail.activities;
        _notify();
      }
    } catch (e) {
      // La fiche a pu disparaître (course reprise, annulée) : ne plus la
      // servir depuis le cache. L'écran garde l'affichage courant ; le
      // prochain `selectOrder` fera une lecture bloquante et remontera
      // proprement l'erreur.
      _detailCache.evict(orderId);
      debugPrint('revalidation fiche $orderId : '
          '${messageForError(e, _localeState.locale)}');
    } finally {
      _revalidating = null;
    }
  }

  /// Exécute une action qui change l'état d'une commande, puis relit cet état
  /// depuis le serveur.
  ///
  /// Les versions précédentes écrivaient un statut « optimiste » localement,
  /// avec deux défauts. D'abord les valeurs étaient inventées : `accepted` et
  /// `picked_up` n'existent pas dans Fleetbase, qui utilise `dispatched`,
  /// `started`, `completed`, `canceled` — l'écran affichait donc un statut
  /// qu'aucun filtre ni aucune couleur ne reconnaissait, jusqu'au prochain
  /// rafraîchissement. Ensuite le statut n'est pas la seule chose qui change :
  /// les transitions suivantes en dépendent, et elles viennent du serveur.
  Future<bool> _mutateOrder(
    String orderId,
    Future<void> Function() action,
  ) async {
    // ⚠️ **La relecture BLOQUANTE se limite au détail** — c'est lui que
    // l'utilisateur regarde, et `selectOrder` est ce qui ramène le statut à
    // jour et les transitions suivantes. Le rafraîchissement des trois listes
    // (`GET /transporteur/commandes`, 8-15 s sur un conducteur chargé) part
    // ENSUITE, sans être attendu : le chaîner ici tenait `isLoading` à `true`
    // le temps des deux appels, et la fiche restait sur son indicateur
    // d'attente — assez pour faire expirer le parcours d'intégration
    // (06/09/2026). `_listRefreshing` porte cette seconde attente, qu'aucun
    // écran de détail ne regarde ; `surfaceErrors: false` empêche un
    // hoquet de fond de poser un bandeau sur une action qui, elle, a réussi.
    final ok =
        await runWrite(action, reload: () => selectOrder(orderId, force: true));
    if (ok) unawaited(loadOrders(surfaceErrors: false));
    return ok;
  }

  /// Accepte une commande.
  Future<bool> acceptOrder(String orderId) => _mutateOrder(
        orderId,
        () => _apiClient.acceptOrder(orderId),
      );

  /// Démarre la livraison d'une commande.
  Future<bool> startOrder(String orderId) => _mutateOrder(
        orderId,
        () => _apiClient.startOrder(orderId),
      );

  /// Refus de la dernière course écartée : la course est-elle repartie au
  /// réseau, ou seulement masquée pour ce transporteur ?
  ///
  /// Distinction visible à l'écran : rendre une course assignée engage le
  /// commerçant, écarter une proposition n'engage personne. Confondre les deux
  /// ferait hésiter à refuser — ou refuser sans mesurer.
  bool? _lastDeclineReleasedToPool;
  bool? get lastDeclineReleasedToPool => _lastDeclineReleasedToPool;

  /// Refuse une course, avec un motif.
  ///
  /// Le rechargement qui suit fait disparaître la course de la liste : c'est
  /// le seul retour visible d'un refus sur une opportunité diffusée, et sans
  /// lui l'action serait indiscernable d'une panne.
  Future<bool> declineOrder({
    required String orderId,
    required String reason,
    String? notes,
  }) async {
    _lastDeclineReleasedToPool = null;
    _isLoading = true;
    _errorMessage = null;
    _notify();

    try {
      final response = await _apiClient.declineOrder(
        orderId,
        reason: reason,
        notes: notes,
      );
      _lastDeclineReleasedToPool = response['releasedToPool'] == true;
      // La course a quitté ce transporteur : sa fiche en cache est fausse.
      _detailCache.evict(orderId);

      // Les transitions disparaissent — la course n'est plus au transporteur —
      // mais la fiche reste affichée le temps que l'écran se retire de
      // lui-même. La vider ici ferait clignoter « Commande introuvable »
      // pendant la trame qui précède le retour à la liste. Le nettoyage
      // définitif est fait par `clearSelection()` au retour.
      _nextActivities = [];
      await loadOrders();
      return true;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      return false;
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Envoie une preuve de livraison, sans appliquer de transition.
  ///
  /// Séparé de [completeOrder] parce que le serveur exige une preuve sur des
  /// étapes intermédiaires aussi (drapeau `require_pod` porté par l'activité,
  /// journal §6.9), pas seulement à la clôture.
  ///
  /// Ne recharge pas la commande : l'appelant enchaîne sur la transition, qui
  /// rechargera. Recharger ici ferait deux allers-retours pour un seul geste.
  Future<bool> captureProof(String orderId, String photoBase64) async {
    _isLoading = true;
    _errorMessage = null;
    _notify();

    try {
      await _apiClient.captureProofPhoto(orderId, [photoBase64]);
      return true;
    } catch (e) {
      _errorMessage = messageForError(e, _localeState.locale);
      return false;
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Applique une transition proposée par [nextActivities].
  ///
  /// [activity] doit être renvoyé tel quel : le serveur valide l'objet
  /// complet, pas son seul code.
  ///
  /// [collectedAmount] accompagne la transition terminale d'une course payée à
  /// la réception. Le serveur la refuse sans lui : « livré » et « perçu X »
  /// sont un seul fait.
  Future<bool> applyActivity(
    String orderId,
    Map<String, dynamic> activity, {
    double? collectedAmount,
    String? discrepancyReason,
    String? cashNotes,
  }) =>
      _mutateOrder(
        orderId,
        () => _apiClient.updateActivity(
          orderId,
          activity,
          collectedAmount: collectedAmount,
          discrepancyReason: discrepancyReason,
          cashNotes: cashNotes,
        ),
      );

  /// Marque une commande comme livrée.
  ///
  /// [proofPhotoBase64] est optionnelle : quand elle est fournie, la preuve
  /// est envoyée d'abord, puis la commande est clôturée. L'ordre compte —
  /// une preuve attachée après clôture n'aurait plus de valeur probante.
  ///
  /// [collectedAmount] est **obligatoire sur une course payée à la réception**,
  /// et le serveur refuse la clôture sans lui : « livré » et « perçu X » sont
  /// un seul fait. Un écart avec le montant annoncé exige un motif.
  Future<bool> completeOrder({
    required String orderId,
    String? proofPhotoBase64,
    double? collectedAmount,
    String? discrepancyReason,
    String? cashNotes,
  }) =>
      _mutateOrder(
        orderId,
        () async {
          if (proofPhotoBase64 != null) {
            await _apiClient.captureProofPhoto(orderId, [proofPhotoBase64]);
          }
          await _apiClient.completeOrder(
            orderId,
            collectedAmount: collectedAmount,
            discrepancyReason: discrepancyReason,
            cashNotes: cashNotes,
          );
        },
      );

  /// Rapporte un échec de livraison.
  ///
  /// Le statut Fleetbase n'est PAS modifié par un signalement (§6.5) : le BFF
  /// joint le rapport à la commande, c'est tout. Fabriquer un statut `failed`
  /// local mentirait sur l'état réel et serait écrasé au rechargement.
  /// `false` quand le dernier signalement portait une photo que le serveur n'a
  /// pas réussi à joindre. Le signalement est bien enregistré dans ce cas —
  /// l'envoi de la preuve est volontairement best-effort côté BFF — mais le
  /// transporteur doit l'apprendre : il croit sinon avoir fourni un
  /// justificatif qui ne figure nulle part.
  bool? _lastPhotoUploaded;
  bool? get lastPhotoUploaded => _lastPhotoUploaded;

  Future<bool> reportDeliveryFailure({
    required String orderId,
    required String reason,
    String? photoBase64,
    String? notes,
    String? waypointUuid,
  }) {
    _lastPhotoUploaded = null;
    return _mutateOrder(
      orderId,
      () async {
        final response = await _apiClient.reportDeliveryFailure(
          orderId,
          reason: reason,
          notes: notes,
          waypointUuid: waypointUuid,
          photo: photoBase64,
        );
        if (photoBase64 != null) {
          _lastPhotoUploaded = response['photoUploaded'] == true;
        }
      },
    );
  }

  void clearError() {
    _errorMessage = null;
    _notify();
  }

  void clearSelection() {
    _selectedOrder = null;
    _notify();
  }
}
