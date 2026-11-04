import 'package:catol/data/mock_law_match_results.dart';
import 'package:catol/data/mock_xai_chat_content.dart';
import 'package:catol/law_details_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:catol/xai_chatbot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the draft conversation and marks sample response', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(result: mockLawMatchResults.first)),
    );

    expect(find.text('Ask CATALYST'), findsOneWidget);
    expect(
      find.text(
        'Get more context on why a law applies, ask for simpler '
        'explanations, or explore related laws.',
      ),
      findsOneWidget,
    );
    expect(find.text(MockXaiChatContent.question), findsOneWidget);
    expect(find.text('Preview example'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().contains(
              MockXaiChatContent.responseLead.trim(),
            ),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/xai_profile_bubble.png',
      ),
      findsOneWidget,
    );
    for (final suggestion in MockXaiChatContent.faqSuggestions) {
      expect(find.text(suggestion), findsOneWidget);
    }
  });

  testWidgets('FAQ selection fills input without sending it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(result: mockLawMatchResults.first)),
    );

    await tester.tap(find.text(MockXaiChatContent.faqSuggestions.first));
    await tester.pump();

    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, MockXaiChatContent.faqSuggestions.first);
    expect(find.text('Preview example'), findsOneWidget);
    expect(
      find.text(MockXaiChatContent.faqSuggestions.first),
      findsNWidgets(2),
    );
  });

  testWidgets('law result card expands and collapses using result context', (
    tester,
  ) async {
    const result = LawMatchResult(
      lawName: 'Family Code of the Philippines',
      articleNumber: 'Article 55',
      title: 'Grounds for Annulment',
      description: 'Existing concise result summary.',
      matchScore: 97,
      articleText: 'Existing retrieved provision.',
      caseExplanationPoints: ['Existing evidence-grounded explanation.'],
    );

    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(result: result)),
    );

    expect(find.text('Article 55 - Grounds for Annulment'), findsOneWidget);
    expect(
      find.text('Existing evidence-grounded explanation.'),
      findsOneWidget,
    );
    expect(find.text('Existing retrieved provision.'), findsNothing);

    await tester.tap(find.text('Existing evidence-grounded explanation.'));
    await tester.pumpAndSettle();

    expect(find.text('Existing concise result summary.'), findsOneWidget);
    expect(find.text('Existing retrieved provision.'), findsOneWidget);
    expect(
      find.text('Existing evidence-grounded explanation.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Existing retrieved provision.'));
    await tester.pumpAndSettle();
    expect(find.text('Existing retrieved provision.'), findsNothing);
  });

  testWidgets(
    'valid Send passes question and selected result to XAI with empty input',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: LawDetailsScreen(result: mockLawMatchResults.first)),
      );
      await tester.enterText(find.byType(TextField), 'How does this apply?');
      await tester.tap(find.byTooltip('Send question'));
      await tester.pumpAndSettle();

      expect(find.byType(XaiChatbotScreen), findsOneWidget);
      expect(find.text('How does this apply?'), findsOneWidget);
      expect(find.text('Family Code of the Philippines'), findsOneWidget);
      expect(
        find.text('Article 55 - Grounds for Annulment of Marriage'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets('empty or whitespace question does not navigate', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LawDetailsScreen(result: mockLawMatchResults.first)),
    );

    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();
    expect(find.byType(LawDetailsScreen), findsOneWidget);
    expect(find.byType(XaiChatbotScreen), findsNothing);

    await tester.enterText(find.byType(TextField), '   \n  ');
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();
    expect(find.byType(LawDetailsScreen), findsOneWidget);
    expect(find.byType(XaiChatbotScreen), findsNothing);
  });

  testWidgets('initial submitted question is first user message', (
    tester,
  ) async {
    const question = 'What does this article mean for my situation?';
    await tester.pumpWidget(
      MaterialApp(
        home: XaiChatbotScreen(
          result: mockLawMatchResults.first,
          initialUserMessage: question,
        ),
      ),
    );

    final resultTitle = find.text(
      'Article 55 - Grounds for Annulment of Marriage',
    );
    final submittedQuestion = find.text(question);
    final previewResponse = find.text('Preview example');
    expect(submittedQuestion, findsOneWidget);
    expect(
      tester.getTopLeft(resultTitle).dy,
      lessThan(tester.getTopLeft(submittedQuestion).dy),
    );
    expect(
      tester.getTopLeft(submittedQuestion).dy,
      lessThan(tester.getTopLeft(previewResponse).dy),
    );
    expect(find.text(MockXaiChatContent.question), findsNothing);
    expect(previewResponse, findsOneWidget);
    expect(find.text('Your AI response goes here.'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('input has no leading chat icon and avatar is compact', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(result: mockLawMatchResults.first)),
    );

    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
    final avatar = find.byWidgetPredicate(
      (widget) =>
          widget is Image &&
          widget.image is AssetImage &&
          (widget.image as AssetImage).assetName ==
              'assets/images/xai_profile_bubble.png',
    );
    expect(avatar, findsOneWidget);
    expect(tester.getSize(avatar), const Size(34, 34));
  });

  testWidgets('multiline question expands and send adds no assistant reply', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(result: mockLawMatchResults.first)),
    );

    final inputFinder = find.byType(TextField);
    final initialHeight = tester.getSize(inputFinder).height;
    await tester.enterText(inputFinder, 'Question line one\nQuestion line two');
    await tester.pumpAndSettle();
    expect(tester.getSize(inputFinder).height, greaterThan(initialHeight));

    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();

    expect(find.text('Question line one\nQuestion line two'), findsOneWidget);
    expect(find.text('Preview example'), findsOneWidget);
    expect(find.text('Type here...'), findsOneWidget);
    expect(find.text('Your AI response goes here.'), findsNothing);
  });
}
