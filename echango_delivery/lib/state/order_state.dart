import 'package:flutter/foundation.dart';

import '../errors/app_error.dart';
import '../models/order.dart';
import '../services/bff_api_client.dart';

/// État de gestion des commandes pour le driver.
class OrderState extends ChangeNotifier {
  final BffApiClient _apiClient;

  List<Order> _orders = [];
  List<Order> _adhocOrders = [];
  List<Order> _historyOrders = [];
  Order? _selectedOrder;
  List<Map<String, dynamic>> _nextActivities = [];
  bool _isLoading = false;
  String? _errorMessage;

  OrderState({required BffApiClient apiClient}) : _apiClient = apiClient;

  List<Order> get orders => _orders;
  Order? get selectedOrder => _selectedOrder;

  /// Transitions applicables à la commande sélectionnée, telles que résolues
  /// par le serveur contre l'OrderConfig et l'état courant.
  ///
  /// C'est la seule source légitime : le détail de commande ne contient
  /// aucune donnée d'activité (journal §6.9), et coder la machine à états
  /// côté client la ferait diverger de la configuration serveur.
  List<Map<String, dynamic>> get nextActivities => _nextActivities;
  bool get isLoading => _isLoading;
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
  Future<void> loadOrders() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final buckets = await _apiClient.getOrderBuckets();
      _orders = buckets['active'] ?? [];
      _adhocOrders = buckets['adhoc'] ?? [];
      _historyOrders = buckets['history'] ?? [];
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Failed to load orders';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Charge les détails d'une commande.
  Future<void> selectOrder(String orderId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _selectedOrder = await _apiClient.getOrder(orderId);

      // Une commande adhoc non réclamée n'a pas de transition : elle doit
      // d'abord être acceptée. Interroger le serveur renverrait une erreur.
      if (_selectedOrder != null &&
          !(_selectedOrder!.adhoc && _selectedOrder!.driverId == null)) {
        try {
          _nextActivities = await _apiClient.getNextActivities(orderId);
        } catch (_) {
          // Transitions indisponibles : l'écran affiche le détail sans
          // action plutôt que d'échouer entièrement.
          _nextActivities = [];
        }
      } else {
        _nextActivities = [];
      }
    } on AppException catch (e) {
      _errorMessage = e.message;
    } catch (e) {
      _errorMessage = 'Failed to load order';
    } finally {
      _isLoading = false;
      notifyListeners();
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
    String fallbackError,
  ) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await action();
      await selectOrder(orderId);
      await loadOrders();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = fallbackError;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Accepte une commande.
  Future<bool> acceptOrder(String orderId) => _mutateOrder(
        orderId,
        () => _apiClient.acceptOrder(orderId),
        'Impossible d\'accepter cette commande',
      );

  /// Démarre la livraison d'une commande.
  Future<bool> startOrder(String orderId) => _mutateOrder(
        orderId,
        () => _apiClient.startOrder(orderId),
        'Impossible de démarrer cette livraison',
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
    notifyListeners();

    try {
      final response = await _apiClient.declineOrder(
        orderId,
        reason: reason,
        notes: notes,
      );
      _lastDeclineReleasedToPool = response['releasedToPool'] == true;

      // Les transitions disparaissent — la course n'est plus au transporteur —
      // mais la fiche reste affichée le temps que l'écran se retire de
      // lui-même. La vider ici ferait clignoter « Commande introuvable »
      // pendant la trame qui précède le retour à la liste. Le nettoyage
      // définitif est fait par `clearSelection()` au retour.
      _nextActivities = [];
      await loadOrders();
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Impossible de refuser cette course';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
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
    notifyListeners();

    try {
      await _apiClient.captureProofPhoto(orderId, [photoBase64]);
      return true;
    } on AppException catch (e) {
      _errorMessage = e.message;
      return false;
    } catch (e) {
      _errorMessage = 'Envoi de la preuve impossible';
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
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
        'Impossible d\'appliquer cette étape',
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
        'Impossible de clôturer cette commande',
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
      'Impossible d\'enregistrer ce signalement',
    );
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  void clearSelection() {
    _selectedOrder = null;
    notifyListeners();
  }
}
