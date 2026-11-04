import 'package:catol/law_details_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const articleText =
      'Art. 69. The husband and wife shall fix the family domicile. In case '
      'of disagreement, the court shall decide.';

  List<String> points({
    String query = 'Hindi sumasama ang husband ko sa family domicile',
  }) => buildExplanationPoints(
    analysis: analyzeQuery(query),
    articleId: 'familycode:69',
    articleText: articleText,
    queryTexts: [query],
    hasDuplicateId: false,
  );

  String emphasized(String point) => [
    for (final s in parseEmphasis(point))
      if (s.emphasized) s.text,
  ].join('|');

  test('marks only the stated rule, not the condition that follows', () {
    final first = points().first;
    expect(
      emphasized(first),
      'The husband and wife shall fix the family domicile.',
    );
    expect(stripEmphasis(first), contains('In case of disagreement'));
    expect(
      stripEmphasis(first),
      startsWith('What the provision says: "Art. 69.'),
    );
  });

  test('marks the caution that shared words do not prove applicability', () {
    final shared = points().firstWhere((p) => p.startsWith('Wording shared'));
    expect(emphasized(shared), 'they do not prove the article applies.');
  });

  test('marks the who-did-what check when the facts include negation', () {
    final negation = points().firstWhere(
      (p) => p.contains('refusal or negation'),
    );
    expect(emphasized(negation), startsWith('Check that the article'));
    expect(stripEmphasis(negation), isNot(contains('**')));
  });

  test('each point has at most one emphasized segment; notice is plain', () {
    final all = points();
    for (final point in all) {
      expect(
        parseEmphasis(point).where((s) => s.emphasized).length,
        lessThanOrEqualTo(1),
      );
    }
    expect(all.last, legalInformationNotice);
  });

  test('unbalanced markers fall back to plain text', () {
    final segments = parseEmphasis('a **b');
    expect(segments, hasLength(1));
    expect(segments.single.emphasized, isFalse);
    expect(segments.single.text, 'a b');
  });

  testWidgets('Law Details renders emphasis bold without literal markers', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: LawDetailsScreen(
          result: LawMatchResult(
            lawName: 'FamilyCode',
            articleNumber: '69',
            title: 'TITLE III',
            description: articleText,
            articleText: articleText,
            matchScore: 55,
            caseExplanationPoints: points(),
          ),
        ),
      ),
    );

    expect(find.textContaining('**', findRichText: true), findsNothing);
    final rich = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text)
        .whereType<TextSpan>();
    final boldTexts = <String>[];
    void collect(InlineSpan span) {
      if (span is TextSpan) {
        if (span.style?.fontWeight == FontWeight.w700 && span.text != null) {
          boldTexts.add(span.text!);
        }
        span.children?.forEach(collect);
      }
    }

    rich.forEach(collect);
    expect(boldTexts, contains('they do not prove the article applies.'));
    expect(
      boldTexts,
      contains('The husband and wife shall fix the family domicile.'),
    );
  });
}
