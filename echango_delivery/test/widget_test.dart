import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echango_delivery/config/api_config.dart';
import 'package:echango_delivery/main.dart';
import 'package:echango_delivery/services/bff_api_client.dart';
import 'package:echango_delivery/state/auth_state.dart';

void main() {
  group('UserRole', () {
    // Ce mapping est le pivot de l'app unique : le serveur renvoie un `type`
    // dans le jeton, et c'est lui qui décide de l'espace ouvert. Une erreur
    // ici enverrait un commerçant dans l'espace transporteur.
    test('correspond aux valeurs `type` du JWT émis par le BFF', () {
      expect(UserRole.transporteur.jwtType, 'transporteur');
      expect(UserRole.commercant.jwtType, 'merchant');
      expect(UserRole.flotte.jwtType, 'fleet');
    });

    test('se résout depuis le type renvoyé par le serveur', () {
      expect(UserRoleX.fromJwtType('merchant'), UserRole.commercant);
      expect(UserRoleX.fromJwtType('transporteur'), UserRole.transporteur);
      expect(UserRoleX.fromJwtType('fleet'), UserRole.flotte);
    });

    test('un type inconnu ne se résout pas plutôt que de choisir au hasard', () {
      expect(UserRoleX.fromJwtType('admin'), isNull);
      expect(UserRoleX.fromJwtType(null), isNull);
    });

    test('chaque profil a un espace distinct', () {
      final paths = UserRole.values.map((r) => r.homePath).toSet();
      expect(paths.length, UserRole.values.length);
    });
  });

  testWidgets('démarre sur la connexion quand aucune session n\'existe',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final apiClient = BffApiClient(baseUrl: ApiConfig.bffBaseUrl);
    final authState = AuthState(prefs: prefs, apiClient: apiClient);

    await tester.pumpWidget(
      EchangoDeliveryApp(authState: authState, apiClient: apiClient),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MaterialApp), findsWidgets);
    // Sans jeton, la redirection doit mener à la connexion — jamais à un
    // espace de profil.
    expect(find.text('Se connecter'), findsOneWidget);
  });
}
