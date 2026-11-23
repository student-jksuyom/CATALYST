import 'package:catol/law_details_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/history_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const result = LawMatchResult(
    lawName: 'Sample Law',
    articleNumber: 'Article 1',
    title: 'A sample title',
    description: 'A demo-only match description.',
    matchScore: 92,
  );

  testWidgets('a failed bookmark save leaves the bookmark unchanged', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LawDetailsScreen(
          result: result,
          onBookmarkSave: (_) async => throw const HistoryStorageException(),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Bookmark'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Bookmark'), findsOneWidget);
    expect(
      find.text('Could not save bookmark on this device.'),
      findsOneWidget,
    );
  });

  testWidgets('shows result details and graceful content placeholders', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Law Details'), findsOneWidget);
    expect(find.text('Sample Law'), findsOneWidget);
    expect(find.text('Article 1 - A sample title'), findsOneWidget);
    expect(
      find.text('Legal text will appear here when available.'),
      findsOneWidget,
    );
    expect(find.text('Explanation is not available yet.'), findsOneWidget);
    expect(find.text('Follow-up responses will appear here.'), findsNothing);
  });

  testWidgets('shows supplied article text and case explanation', (
    tester,
  ) async {
    const populatedResult = LawMatchResult(
      lawName: 'Sample Law',
      articleNumber: 'Article 1',
      title: 'A sample title',
      description: 'A demo-only match description.',
      matchScore: 92,
      articleText: 'Provision supplied by the retrieval engine.',
      caseExplanationPoints: [
        'First evidence-grounded connection.',
        'Second evidence-grounded connection.',
      ],
    );

    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: populatedResult)),
    );

    expect(
      find.text('Provision supplied by the retrieval engine.'),
      findsOneWidget,
    );
    expect(find.text('First evidence-grounded connection.'), findsOneWidget);
    expect(find.text('Second evidence-grounded connection.'), findsOneWidget);
    expect(
      find.text('Legal text will appear here when available.'),
      findsNothing,
    );
  });

  testWidgets('labels the AI-generated explanation as a possible link', (
    tester,
  ) async {
    const explainedResult = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: 'Article 491',
      title: 'Co-ownership',
      description: 'Consent is required for alterations.',
      matchScore: 92,
      contextualExplanation:
          'You said your sibling changed jointly owned land without asking.',
      hasAiExplanation: true,
    );

    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: explainedResult)),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    expect(find.text('Why this may relate to your concern'), findsOneWidget);
    expect(
      find.text(
        'You said your sibling changed jointly owned land without asking.',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('AI-generated from your concern'),
      findsOneWidget,
    );
  });

  testWidgets('heading shows article name; long text is split and collapsible', (
    tester,
  ) async {
    final items = [
      for (var i = 1; i <= 8; i++)
        '($i) Item number $i describes a separate act that is listed here with enough words to wrap across more than one line on a narrow phone screen;',
    ].join(' ');
    final longText =
        'Article 26. Every person shall respect the dignity, personality, privacy and peace of mind of his neighbors and other persons. The following and similar acts shall produce a cause of action for damages: $items';
    final result = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: '26',
      title: 'TITLE I',
      description: '',
      matchScore: 90,
      articleText: longText,
    );

    await tester.pumpWidget(
      MaterialApp(home: LawDetailsScreen(result: result)),
    );

    expect(
      find.text(
        'Article 26: Every person shall respect the dignity, personality, privacy',
      ),
      findsNothing,
    );
    expect(
      find.textContaining('Article 26: Every person shall respect'),
      findsOneWidget,
    );
    expect(find.text('See more'), findsOneWidget);
    expect(find.textContaining('Item number 8'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See more'));
    await tester.pump();

    expect(find.text('See less'), findsOneWidget);
    expect(
      find.textContaining('Item number 8', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('(8)', skipOffstage: false), findsOneWidget);
  });

  testWidgets(
    'language toggle switches explanation and reminders are labelled',
    (tester) async {
      const result = LawMatchResult(
        lawName: 'Civil Code',
        articleNumber: 'Article 491',
        title: 'TITLE III',
        description: '',
        matchScore: 90,
        articleText: 'Article 491. A short provision.',
        defaultExplanationLanguage: 'tl',
        explanationVariants: {
          'en': ExplanationVariant(
            points: ['English plain explanation.'],
            reminders: ['English disclaimer.'],
          ),
          'tl': ExplanationVariant(
            points: ['Paliwanag sa Tagalog.'],
            reminders: ['Paalala sa Tagalog.'],
          ),
        },
      );
      await tester.pumpWidget(
        const MaterialApp(home: LawDetailsScreen(result: result)),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(
        find.text('Bakit ito posibleng may kaugnayan sa concern mo'),
        findsOneWidget,
      );
      expect(find.text('Paliwanag sa Tagalog.'), findsOneWidget);
      expect(find.text('Paalala'), findsOneWidget);
      expect(find.text('Paalala sa Tagalog.'), findsOneWidget);
      expect(find.text('English plain explanation.'), findsNothing);

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(find.text('Why this may relate to your concern'), findsOneWidget);
      expect(find.text('English plain explanation.'), findsOneWidget);
      expect(find.text('Reminder'), findsOneWidget);
      expect(find.text('English disclaimer.'), findsOneWidget);
      expect(find.text('Paliwanag sa Tagalog.'), findsNothing);
    },
  );

  testWidgets('a single language shows no toggle', (tester) async {
    const result = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: 'Article 5',
      title: 'T',
      description: '',
      matchScore: 90,
      articleText: 'Article 5. Short.',
      explanationVariants: {
        'en': ExplanationVariant(points: ['Only English.']),
      },
    );
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Reminder'), findsNothing);
  });

  testWidgets('short article text has no see-more button', (tester) async {
    const result = LawMatchResult(
      lawName: 'Civil Code',
      articleNumber: '5',
      title: 'T',
      description: '',
      matchScore: 90,
      articleText: 'Article 5. Acts executed against the provisions of mandatory laws are void. (4a)',
    );
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );
    expect(find.text('See more'), findsNothing);
  });

  testWidgets('bookmark states use separate images without layout movement', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );
    await tester.pumpAndSettle();

    final buttonFinder = find.byTooltip('Bookmark');
    final outlineImageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/images/bookmark_outline.png',
    );
    final initialButtonSize = tester.getSize(buttonFinder);
    final initialButtonPosition = tester.getTopLeft(buttonFinder);

    expect(initialButtonSize, const Size(48, 48));
    expect(outlineImageFinder, findsOneWidget);
    expect(tester.getSize(outlineImageFinder), const Size(22.3, 28));

    await tester.tap(buttonFinder);
    await tester.pumpAndSettle();
    final filledButtonFinder = find.byTooltip('Remove bookmark');
    final filledImageFinder = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/images/bookmark_filled.png',
    );
    expect(filledButtonFinder, findsOneWidget);
    expect(filledImageFinder, findsOneWidget);
    expect(tester.getSize(filledButtonFinder), initialButtonSize);
    expect(tester.getTopLeft(filledButtonFinder), initialButtonPosition);
    expect(tester.getSize(filledImageFinder), const Size(22.3, 28));

    await tester.tap(filledButtonFinder);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Bookmark'), findsOneWidget);
    expect(outlineImageFinder, findsOneWidget);
  });

  testWidgets('question input expands to its line limit and keeps its text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );

    final inputFinder = find.byType(TextField);
    final initialHeight = tester.getSize(inputFinder).height;
    await tester.enterText(
      inputFinder,
      'First line\nSecond line\nThird line\nFourth line',
    );
    await tester.pumpAndSettle();
    final expandedHeight = tester.getSize(inputFinder).height;

    expect(expandedHeight, greaterThan(initialHeight));

    const longerText =
        'First line\nSecond line\nThird line\nFourth line\n'
        'Fifth line\nSixth line\nSeventh line\nEighth line';
    await tester.enterText(inputFinder, longerText);
    await tester.pumpAndSettle();

    expect(tester.getSize(inputFinder).height, expandedHeight);
    expect(tester.widget<TextField>(inputFinder).controller!.text, longerText);
  });

  testWidgets('sending a follow-up does not generate an answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LawDetailsScreen(result: result)),
    );

    await tester.enterText(find.byType(TextField), 'Can you explain this?');
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();

    expect(find.text('Ask CATALYST'), findsOneWidget);
    expect(find.text('Can you explain this?'), findsOneWidget);
  });
}
