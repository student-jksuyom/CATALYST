import 'package:catol/match_results_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/gemma_article_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const results = [
    LawMatchResult(
      lawName: 'Law A',
      articleNumber: 'Article 1',
      title: 'First',
      description: 'First description',
      matchScore: 88,
    ),
    LawMatchResult(
      lawName: 'Law B',
      articleNumber: 'Article 2',
      title: 'Second',
      description: 'Second description',
      matchScore: 96,
    ),
    LawMatchResult(
      lawName: 'Law C',
      articleNumber: 'Article 3',
      title: 'Third',
      description: 'Third description',
      matchScore: 77,
    ),
    LawMatchResult(
      lawName: 'Law D',
      articleNumber: 'Article 4',
      title: 'Fourth',
      description: 'Fourth description',
      matchScore: 69,
    ),
  ];

  testWidgets('Top Matches shows the three highest scores', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MatchResultsScreen(results: results)),
    );
    final semantics = tester.ensureSemantics();

    expect(find.text('96%'), findsOneWidget);
    expect(find.text('88%'), findsOneWidget);
    expect(find.byTooltip('Relevance score'), findsWidgets);
    expect(find.bySemanticsLabel('Relevance score: 96%'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('77%'), findsOneWidget);
    expect(find.text('69%'), findsNothing);
    semantics.dispose();
  });

  testWidgets('All Results shows the full sorted result list', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MatchResultsScreen(results: results)),
    );
    await tester.tap(find.text('All Results'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('Fourth description'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Fourth description'), findsOneWidget);
    expect(find.text('69%'), findsOneWidget);
  });

  testWidgets('empty results show an empty state', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MatchResultsScreen(results: [])),
    );

    expect(find.text('No matching results yet.'), findsOneWidget);
  });

  testWidgets('Gemma results can be switched to baseline', (tester) async {
    const gemmaResult = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: 'Article 1308',
      title: 'Binding effect',
      description: 'The contract must bind both parties.',
      matchScore: 90,
      contextualExplanation: 'It says the contract binds both parties.',
      supportingQuote: 'must bind both parties',
      hasAiExplanation: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: MatchResultsScreen(
          results: results,
          aiCandidates: results,
          onGemmaAssessment: () async => GemmaArticleAssessment(
            decision: GemmaArticleDecision.select,
            results: const [gemmaResult],
            explanation: 'This article directly addresses the contract.',
            elapsed: Duration.zero,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('run-gemma-assessment')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('AI #1'), findsOneWidget);
    expect(find.textContaining('Supporting text:'), findsOneWidget);
    await tester.tap(find.text('Baseline'));
    await tester.pumpAndSettle();
    expect(find.text('96%'), findsOneWidget);
  });

  testWidgets('Gemma abstention leaves the comparison controls visible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MatchResultsScreen(
          results: results,
          aiCandidates: results,
          onGemmaAssessment: () async => GemmaArticleAssessment(
            decision: GemmaArticleDecision.abstain,
            results: const [],
            explanation: 'No supplied article directly addresses the concern.',
            elapsed: Duration.zero,
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('run-gemma-assessment')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text('No supplied article directly addresses the concern.'),
      findsNWidgets(2),
    );
    expect(find.text('Baseline'), findsOneWidget);
    expect(find.text('Gemma'), findsOneWidget);
    await tester.tap(find.text('Baseline'));
    await tester.pumpAndSettle();
    expect(find.text('96%'), findsOneWidget);
  });

  testWidgets('shows an AI explanation linking a result to the concern', (
    tester,
  ) async {
    const explainedResult = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: 'Article 491',
      title: 'Co-ownership',
      description: 'Consent is required for alterations.',
      matchScore: 92,
      contextualExplanation: 'You said your sibling changed the jointly owned land without asking you.',
      hasAiExplanation: true,
      explanationVariants: {
        'en': ExplanationVariant(
          points: [
            'The article requires consent.',
            'You described your sibling changing co-owned land without asking; '
                'Article 491 requires co-owner consent for alterations.',
            'It depends on whether the property was co-owned.',
          ],
        ),
      },
    );

    await tester.pumpWidget(
      const MaterialApp(home: MatchResultsScreen(results: [explainedResult])),
    );

    expect(find.text('Why this may relate'), findsOneWidget);
    expect(
      find.text(
        'You said your sibling changed the jointly owned land without asking you.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('does not present similarity as an explanation', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: MatchResultsScreen(results: results)),
    );

    expect(
      find.textContaining(
        'Similarity ranking alone does not show that this provision applies.',
      ),
      findsWidgets,
    );
  });

  testWidgets('selecting a result invokes the details callback', (
    tester,
  ) async {
    LawMatchResult? selectedResult;

    await tester.pumpWidget(
      MaterialApp(
        home: MatchResultsScreen(
          results: results,
          onResultSelected: (result) => selectedResult = result,
        ),
      ),
    );
    await tester.tap(find.text('Law B'));

    expect(selectedResult?.lawName, 'Law B');
  });
}
