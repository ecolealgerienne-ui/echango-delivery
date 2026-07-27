import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:provider/provider.dart';

import 'package:echango_driver/main.dart';
import 'package:echango_driver/services/bff_api_client.dart';
import 'package:echango_driver/state/auth_state.dart';

class MockAuthState extends Mock implements AuthState {}

class MockBffApiClient extends Mock implements BffApiClient {}

void main() {
  testWidgets('App initializes without crashing', (WidgetTester tester) async {
    final mockAuthState = MockAuthState();
    final mockApiClient = MockBffApiClient();

    await tester.pumpWidget(
      EchangoDriverApp(
        authState: mockAuthState,
        apiClient: mockApiClient,
      ),
    );

    expect(find.byType(MaterialApp), findsWidgets);
  });
}
