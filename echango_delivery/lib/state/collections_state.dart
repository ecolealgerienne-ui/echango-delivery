import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../errors/error_message.dart';
import '../models/collections.dart';
import '../services/bff_api_client.dart';
import 'locale_state.dart';

/// L'argent des commandes du commerçant — **en lecture seule**.
///
/// ── Ce que cette classe n'a pas, et pourquoi ────────────────────────────────
///
/// Elle a remplacé `CashState` le 03/08/2026 (`docs/registre_caisse_precis.md`),
/// qui portait les remises, les confirmations, les contestations et les soldes
/// des trois profils. Il ne reste **aucune écriture** : la plateforme montre ce
/// qui a été déclaré à chaque porte, elle ne tient pas de compte.
///
/// C'est pourquoi il n'y a pas de `WriteEnvelope` ici — le mixin existe pour
/// les classes qui écrivent, et n'avoir rien à écrire est le sujet même de ce
/// chantier.
class CollectionsState extends ChangeNotifier {
  CollectionsState({
    required BffApiClient apiClient,
    required LocaleState localeState,
  })  : _apiClient = apiClient,
        _localeState = localeState;

  final BffApiClient _apiClient;
  final LocaleState _localeState;

  Locale get _locale => _localeState.locale;

  MerchantCollections? _collections;
  bool _isLoading = false;
  String? _errorMessage;

  MerchantCollections? get collections => _collections;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// ⚠️ **Vide et illisible ne se disent pas pareil** (règle 10).
  ///
  /// `collections == null` après un échec veut dire « je n'ai pas pu savoir » ;
  /// une liste vide veut dire « rien à signaler ». Sans cette distinction,
  /// l'écran affirmerait « aucun encaissement » à un commerçant dont le BFF est
  /// injoignable — le défaut exact corrigé deux fois ailleurs dans ce dépôt.
  bool get unavailable => _errorMessage != null && _collections == null;

  Future<void> load() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _collections = await _apiClient.getMerchantCollections();
    } catch (error) {
      // Le bandeau se pose AU-DESSUS de ce qui était lisible, il ne le
      // remplace pas : un rechargement raté ne doit pas effacer la liste
      // précédente. `_collections` est donc laissé tel quel.
      _errorMessage = messageForError(error, _locale);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}
