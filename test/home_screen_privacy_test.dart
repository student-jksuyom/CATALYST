import 'package:catol/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('article search does not show the online review disclosure', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    expect(
      find.byKey(const ValueKey('online-ai-privacy-notice')),
      findsNothing,
    );
  });
}
