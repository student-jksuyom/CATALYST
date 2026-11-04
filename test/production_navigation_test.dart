import 'dart:async';

import 'package:catol/about_screen.dart';
import 'package:catol/data/mock_xai_chat_content.dart';
import 'package:catol/history_screen.dart';
import 'package:catol/home_screen.dart';
import 'package:catol/landing_screen.dart';
import 'package:catol/law_details_screen.dart';
import 'package:catol/main.dart';
import 'package:catol/match_results_screen.dart';
import 'package:catol/models/law_match_result.dart';
import 'package:catol/processing_screen.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/xai_chatbot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> openHome(
    WidgetTester tester, {
    CatalystRetrievalService? retrievalService,
  }) async {
    await tester.pumpWidget(
      CatalystApp(
        retrievalService: retrievalService ?? _successfulRetrievalService(),
      ),
    );
    expect(find.byType(LandingScreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(HomeScreen), findsOneWidget);
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Open menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('landing replaces itself with Home once after four seconds', (
    tester,
  ) async {
    await tester.pumpWidget(CatalystApp());

    await tester.pump(const Duration(milliseconds: 3999));
    expect(find.byType(LandingScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 8));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(LandingScreen), findsNothing);
  });

  testWidgets('menu opens general chat without legal-result mock content', (
    tester,
  ) async {
    await openHome(tester);

    await openMenu(tester);
    expect(find.text('History'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    await tester.tap(find.text('Chat'));
    await tester.pumpAndSettle();

    expect(find.byType(XaiChatbotScreen), findsOneWidget);
    expect(find.text('Ask CATALYST'), findsOneWidget);
    expect(
      find.textContaining('Describe your legal concern to get started.'),
      findsOneWidget,
    );
    expect(find.text('Preview example'), findsNothing);
    expect(find.text(MockXaiChatContent.question), findsNothing);
    expect(find.text('Family Code of the Philippines'), findsNothing);
  });

  testWidgets('menu closes from outside tap and its header control', (
    tester,
  ) async {
    await openHome(tester);
    await openMenu(tester);
    expect(tester.getTopLeft(find.text('Chat')).dx, lessThan(800));

    await tester.tapAt(const Offset(100, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.text('Chat')).dx, greaterThan(800));

    await openMenu(tester);
    await tester.tap(find.byTooltip('Close menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getTopLeft(find.text('Chat')).dx, greaterThan(800));
  });

  testWidgets('menu navigates to About and History details', (tester) async {
    await openHome(tester);
    await openMenu(tester);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await openMenu(tester);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.byType(HistoryScreen), findsOneWidget);

    await tester.tap(find.text('Hiwalayan ang asawa'));
    await tester.pumpAndSettle();
    expect(find.byType(LawDetailsScreen), findsOneWidget);
    expect(find.text('Family Code of the Philippines'), findsOneWidget);
  });

  testWidgets('Home search opens Processing then local Match Results', (
    tester,
  ) async {
    await openHome(tester);

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ProcessingScreen), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(MatchResultsScreen), findsOneWidget);
    expect(find.text('Civil Code of the Philippines'), findsOneWidget);
    expect(
      find.text('Returned article text from local retrieval.'),
      findsOneWidget,
    );
    expect(find.text('Family Code of the Philippines'), findsNothing);
    expect(
      find.textContaining('not a probability or legal conclusion'),
      findsNothing,
    );

    await tester.tap(find.text('Civil Code of the Philippines').first);
    await tester.pumpAndSettle();
    expect(find.byType(LawDetailsScreen), findsOneWidget);
  });

  testWidgets('returning from Processing preserves Home concern', (
    tester,
  ) async {
    final pendingResponse = Completer<CatalystMatchResponse>();
    await openHome(
      tester,
      retrievalService: _FakeRetrievalService((_) => pendingResponse.future),
    );
    final concernField = find.byType(TextField);
    await tester.enterText(concernField, 'I need to edit this concern');
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(ProcessingScreen), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(
      tester.widget<TextField>(concernField).controller!.text,
      'I need to edit this concern',
    );
    pendingResponse.complete(
      const CatalystMatchResponse(results: <LawMatchResult>[]),
    );
    await tester.pump();
    expect(find.byType(MatchResultsScreen), findsNothing);
  });

  testWidgets('Local retrieval failure shows retry without fallback results', (
    tester,
  ) async {
    var attempts = 0;
    final service = _FakeRetrievalService((_) async {
      attempts++;
      if (attempts == 1) {
        throw const CatalystRetrievalException(
          CatalystRetrievalFailure.inference,
          'The on-device model could not process this concern. Please try again.',
        );
      }
      return const CatalystMatchResponse(
        results: [
          LawMatchResult(
            lawName: 'Local retry result',
            articleNumber: 'Article 1',
            title: 'Retry succeeded',
            chapterTitle: '',
            description: 'Returned after local retry.',
            articleText: 'Returned after local retry.',
            matchScore: 25,
          ),
        ],
      );
    });
    await openHome(tester, retrievalService: service);

    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Unable to retrieve matches'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Local retry result'), findsOneWidget);
    expect(find.text('Family Code of the Philippines'), findsNothing);
    expect(attempts, 2);
  });

  testWidgets('unexpected processing errors show a retryable failure', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ProcessingScreen(
          onProcessingComplete: () async {
            attempts++;
            if (attempts == 1) {
              throw StateError('private error detail');
            }
            throw const CatalystRetrievalException(
              CatalystRetrievalFailure.modelInitialization,
              'The on-device language model could not be initialized. '
              'Please restart the app and try again.',
            );
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Unable to retrieve matches'), findsOneWidget);
    expect(
      find.text(
        'An unexpected error occurred while retrieving matches. Please try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(
      find.text(
        'The on-device language model could not be initialized. '
        'Please restart the app and try again.',
      ),
      findsOneWidget,
    );
    expect(attempts, 2);
  });

  testWidgets('returning from About resets Home concern', (tester) async {
    await openHome(tester);
    final concernField = find.byType(TextField);
    await tester.enterText(concernField, 'Previous concern');
    await openMenu(tester);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(concernField).controller!.text, isEmpty);
  });

  testWidgets('returning home after Law Details resets Home concern', (
    tester,
  ) async {
    await openHome(tester);
    final concernField = find.byType(TextField);
    await tester.enterText(concernField, 'Concern before opening History');
    await openMenu(tester);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hiwalayan ang asawa'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(concernField).controller!.text, isEmpty);
  });

  testWidgets('returning from completed Results resets Home concern', (
    tester,
  ) async {
    await openHome(tester);
    final concernField = find.byType(TextField);
    await tester.enterText(concernField, 'Concern carried to demo results');
    await tester.tap(find.byTooltip('Search'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(MatchResultsScreen), findsOneWidget);
    expect(find.text('“ Concern carried to demo results ”'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(MatchResultsScreen),
        matching: find.byTooltip('Back'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.widget<TextField>(concernField).controller!.text, isEmpty);
  });

  testWidgets(
    'Home concern input is compact, interactive, and grows multiline',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      expect(tester.takeException(), isNull);
      final searchButton = find.byTooltip('Search');
      final concernField = find.byType(TextField);
      final composer = find.byKey(const ValueKey('home-concern-composer'));
      final initialButtonSize = tester.getSize(searchButton);
      final initialFieldHeight = tester.getSize(concernField).height;
      final initialComposerHeight = tester.getSize(composer).height;
      expect(initialComposerHeight, 66);
      expect(tester.widget<TextField>(concernField).minLines, 1);
      expect(tester.widget<TextField>(concernField).maxLines, 4);

      await tester.tap(concernField);
      await tester.showKeyboard(concernField);
      expect(FocusManager.instance.primaryFocus, isNotNull);
      expect(FocusManager.instance.primaryFocus!.hasFocus, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(FocusManager.instance.primaryFocus!.hasFocus, isTrue);
      await tester.enterText(
        concernField,
        'First line\nSecond line\nThird line',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<TextField>(concernField).controller!.text,
        'First line\nSecond line\nThird line',
      );
      expect(find.text('First line\nSecond line\nThird line'), findsOneWidget);
      expect(FocusManager.instance.primaryFocus!.hasFocus, isTrue);

      expect(tester.getSize(searchButton), initialButtonSize);
      expect(tester.getSize(searchButton), const Size(44, 44));
      expect(
        tester.getSize(concernField).height,
        greaterThan(initialFieldHeight),
      );
      expect(
        tester.getSize(composer).height,
        greaterThan(initialComposerHeight),
      );
      expect(tester.getSize(composer).height, lessThanOrEqualTo(122));

      await tester.enterText(
        concernField,
        'First line\nSecond line\nThird line\nFourth line',
      );
      await tester.pump();
      final cappedFieldHeight = tester.getSize(concernField).height;
      await tester.enterText(
        concernField,
        'First line\nSecond line\nThird line\nFourth line\nFifth line\n'
        'Sixth line\nSeventh line\nEighth line',
      );
      await tester.pump();
      expect(tester.getSize(concernField).height, cappedFieldHeight);
      expect(
        tester.widget<TextField>(concernField).controller!.text,
        'First line\nSecond line\nThird line\nFourth line\nFifth line\n'
        'Sixth line\nSeventh line\nEighth line',
      );
      expect(tester.getSize(searchButton), initialButtonSize);
      expect(tester.takeException(), isNull);
    },
  );
}

CatalystRetrievalService _successfulRetrievalService() {
  return _FakeRetrievalService((_) async {
    return const CatalystMatchResponse(
      results: [
        LawMatchResult(
          lawName: 'Civil Code of the Philippines',
          articleNumber: 'Article 100',
          title: 'Test article',
          chapterTitle: 'Test chapter',
          description: 'Returned article text from local retrieval.',
          articleText: 'Returned article text from local retrieval.',
          matchScore: 27.6,
        ),
      ],
    );
  });
}

class _FakeRetrievalService implements CatalystRetrievalService {
  const _FakeRetrievalService(this._matchConcern);

  final Future<CatalystMatchResponse> Function(String concern) _matchConcern;

  @override
  Future<CatalystMatchResponse> matchConcern(String concern) {
    return _matchConcern(concern);
  }
}
