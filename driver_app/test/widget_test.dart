import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echango_driver/main.dart';

void main() {
  testWidgets('App initializes without crashing', (WidgetTester tester) async {
    await tester.pumpWidget(const EchangoDriverApp());
    expect(find.byType(MaterialApp), findsWidgets);
  });
}
