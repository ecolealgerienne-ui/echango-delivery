import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Comptes de test proposés en un tap sur l'écran de connexion.
///
/// Pourquoi ça existe : en développement, on relance l'app des dizaines de
/// fois et on bascule entre plusieurs transporteurs pour vérifier l'isolation
/// des commandes. Retaper les identifiants à chaque fois est une friction
/// inutile qui décourage justement les tests qu'on veut faire.
///
/// ⚠️ Deux garde-fous, délibérés :
///
/// 1. **Jamais en release.** [accounts] renvoie une liste vide hors mode
///    debug ([kDebugMode]), donc le sélecteur disparaît des builds
///    distribués. Un raccourci de connexion embarqué dans une app livrée
///    serait une faille, pas une commodité.
/// 2. **Aucun mot de passe versionné par défaut.** La liste est fournie au
///    build via `--dart-define`, elle ne vit pas dans le dépôt :
///
/// ```bash
/// flutter run --dart-define=DEV_ACCOUNTS='[
///   {"label":"Transporteur 1","email":"driver-test-10000@echango.local","password":"motdepasse123"}
/// ]'
/// ```
///
/// Sans cette variable, aucun compte n'est proposé et la connexion se fait
/// normalement — le comportement d'un poste qui n'a rien configuré.
class DevAccount {
  final String label;
  final String email;
  final String password;

  /// Profil du compte, au format `type` du JWT : `transporteur`, `merchant`
  /// ou `fleet`. Nécessaire parce que le BFF a un endpoint de connexion par
  /// persona — sans lui, un raccourci ne saurait pas lequel appeler.
  final String role;

  const DevAccount({
    required this.label,
    required this.email,
    required this.password,
    this.role = 'transporteur',
  });
}

class DevAccounts {
  static const String _raw = String.fromEnvironment('DEV_ACCOUNTS', defaultValue: '');

  /// Comptes disponibles, uniquement en debug.
  ///
  /// Tolérant à un JSON mal formé : une variable de build erronée doit priver
  /// du raccourci, jamais empêcher l'app de démarrer.
  static List<DevAccount> get accounts {
    if (!kDebugMode || _raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(_raw);
      if (decoded is! List) return const [];

      return decoded
          .whereType<Map<String, dynamic>>()
          .where((e) => e['email'] is String && e['password'] is String)
          .map((e) => DevAccount(
                label: (e['label'] ?? e['email']) as String,
                email: e['email'] as String,
                password: e['password'] as String,
                role: (e['role'] as String?) ?? 'transporteur',
              ))
          .toList();
    } catch (e) {
      debugPrint('DEV_ACCOUNTS ignoré (JSON invalide) : $e');
      return const [];
    }
  }
}
