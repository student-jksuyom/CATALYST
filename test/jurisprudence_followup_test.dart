import 'package:catol/models/law_match_result.dart';
import 'package:catol/law_details_screen.dart';
import 'package:catol/services/case_conversation.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/followup_service.dart';
import 'package:catol/services/jurisprudence_service.dart';
import 'package:catol/xai_chatbot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _article = LawMatchResult(
  lawName: 'Civil Code',
  articleNumber: 'Article 493',
  title: 'Co-owner rights',
  description:
      'Each co-owner has full ownership of his part and may alienate it.',
  articleText: 'Each co-owner shall have the full ownership of his part and of the fruits and benefits pertaining thereto.',
  matchScore: 80,
);

const _case = JurisprudenceCase(
  id: 'c1',
  law: 'CivilCode',
  lawName: 'Civil Code',
  topic: 'Co-ownership',
  title: 'Heirs v. Sibling',
  grNo: 'G.R. No. 1',
  date: '2000',
  holding: 'A co-owner may sell only his undivided share of the co-owned property, not the whole land, without consent of the other co-owners.',
  dispositive: '',
  articles: ['493'],
  passages: [],
);

class _Service implements CatalystRetrievalService {
  @override
  Future<CatalystMatchResponse> matchConcern(String concern) async =>
      CatalystMatchResponse(
        originalQuery: concern,
        processedQuery: concern,
        results: const [],
      );
}

class _Fake implements FollowUpAnswerer {
  _Fake(this.reply);
  final FollowUpAnswer? reply;
  int calls = 0;
  List<JurisprudenceCase> sentCases = const [];

  @override
  Future<FollowUpAnswer?> answer({
    required String question,
    required String narrative,
    required String language,
    required List<LawMatchResult> articles,
    required List<JurisprudenceCase> cases,
  }) async {
    calls++;
    sentCases = cases;
    return reply;
  }
}

CaseConversation _conversation(FollowUpAnswerer? followUp) =>
    CaseConversation.forArticle(
      service: _Service(),
      result: _article,
      followUp: followUp,
      loadCases: () async => JurisprudenceIndex([_case]),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('article follow-up discloses online processing before sending', (
    tester,
  ) async {
    final followUp = _Fake(const FollowUpAnswer(text: 'Answer.'));
    final conversation = _conversation(followUp);
    await tester.pumpWidget(
      MaterialApp(
        home: LawDetailsScreen(result: _article, conversation: conversation),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      'Are there Supreme Court cases about this?',
    );
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();
    expect(find.text('Online XAI follow-up'), findsOneWidget);
    expect(followUp.calls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(followUp.calls, 0);
    expect(find.text('Law Details'), findsOneWidget);
  });

  group('JurisprudenceIndex', () {
    test('ranks the matching decision and ignores unrelated queries', () {
      final index = JurisprudenceIndex([_case]);
      final hits = index.search(
        'my sibling sold the co-owned land without consent',
        articles: const [_article],
      );
      expect(hits.single.jurisprudence.id, 'c1');
      expect(index.search('xyzzy quartz'), isEmpty);
      expect(JurisprudenceIndex.empty().search('co-owner'), isEmpty);
    });

    test(
      'the bundled dataset loads and finds co-ownership decisions',
      () async {
        final index = await JurisprudenceIndex.load();
        expect(index.cases.length, greaterThan(30));
        final hits = index.search(
          'co-owner sold the whole property without consent',
        );
        expect(hits, isNotEmpty);
      },
    );
  });

  group('follow-up conversation', () {
    test(
      'online answer is tagged online and lists the cited decision',
      () async {
        final fake = _Fake(
          const FollowUpAnswer(text: 'Plain answer.', citedCases: [_case]),
        );
        final c = _conversation(fake);
        await c.send('Are there Supreme Court cases about this?');
        final reply = c.messages.last;
        expect(fake.calls, 1);
        expect(reply.mode, RetrievalMode.online);
        expect(reply.text, contains('Plain answer.'));
        expect(reply.text, contains('G.R. No. 1'));
      },
    );

    test('failed online answer falls back to the on-device dataset', () async {
      final c = _conversation(_Fake(null));
      await c.send('Are there Supreme Court cases about this?');
      expect(c.messages.last.mode, RetrievalMode.onDeviceFallback);
      expect(c.messages.last.text, contains('G.R. No. 1'));
    });

    test('no answerer means on-device mode', () async {
      final c = _conversation(null);
      await c.send('May kaso ba ng Korte Suprema tungkol dito?');
      expect(c.messages.last.mode, RetrievalMode.onDevice);
    });
  });

  testWidgets('chat bubble shows the source tag', (tester) async {
    final c = _conversation(_Fake(const FollowUpAnswer(text: 'Plain answer.')));
    await tester.pumpWidget(
      MaterialApp(home: XaiChatbotScreen(conversation: c)),
    );
    await tester.enterText(find.byType(TextField), 'Why is this relevant?');
    await tester.tap(find.byTooltip('Send question'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('answer-source-tag')), findsOneWidget);
  });
}
