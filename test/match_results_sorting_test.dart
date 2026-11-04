import 'package:catol/match_results_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

LawMatchResult _r(String law, String article, double score) => LawMatchResult(
  lawName: law,
  articleNumber: article,
  title: 'T',
  description: 'Description $law $article',
  matchScore: score,
);

void main() {
  final unsorted = [
    _r('CivilCode', '111', 53),
    _r('FamilyCode', '69', 53),
    _r('FamilyCode', '111', 62),
    _r('CivilCode', '5', 40),
  ];

  Future<void> pump(WidgetTester tester, List<LawMatchResult> results) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MatchResultsScreen(results: results, userConcern: 'my query'),
      ),
    );
  }

  testWidgets('orders by score descending, ties keep retrieval order', (
    tester,
  ) async {
    await pump(tester, unsorted);
    expect(find.text('Potential retrieval matches to:'), findsOneWidget);

    double top(String text) => tester.getTopLeft(find.textContaining(text)).dy;
    expect(
      top('Description FamilyCode 111'),
      lessThan(top('Description CivilCode 111')),
    );
    expect(
      top('Description CivilCode 111'),
      lessThan(top('Description FamilyCode 69')),
    );
  });

  testWidgets('All Results tab uses the same order', (tester) async {
    await pump(tester, unsorted);
    await tester.tap(find.text('All Results'));
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.textContaining(text)).dy;
    expect(
      top('Description FamilyCode 111'),
      lessThan(top('Description CivilCode 111')),
    );
    expect(
      top('Description FamilyCode 69'),
      lessThan(top('Description CivilCode 5')),
    );
  });

  testWidgets('empty results render without errors', (tester) async {
    await pump(tester, const []);
    expect(tester.takeException(), isNull);
  });
}
