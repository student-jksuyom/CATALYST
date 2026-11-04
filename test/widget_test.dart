import 'package:catol/landing_screen.dart';
import 'package:catol/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CatalystApp starts on the landing screen', (tester) async {
    await tester.pumpWidget(CatalystApp());

    expect(find.byType(LandingScreen), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'CATALYST');

    // Let the landing timer fire so no timer is left pending.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 8));
  });
}
