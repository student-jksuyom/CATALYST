import 'dart:convert';
import 'dart:io';

import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/case_conversation.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/followup_service.dart';
import 'package:catol/services/jurisprudence_service.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixtureEncoder implements LocalQueryEncoder {
  _FixtureEncoder(this.vectors);
  final Map<String, dynamic> vectors;

  @override
  Future<List<double>> encode(List<int> ids, List<int> mask) async {
    final value = vectors[ids.join(',')];
    if (value is! List) throw StateError('Missing cached query vector.');
    return [for (final item in value) (item as num).toDouble()];
  }
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();
  @override
  Future<String> preprocess(String query) async => query;
}

class _Online implements FollowUpAnswerer {
  int calls = 0;
  @override
  Future<FollowUpAnswer?> answer({
    required String question,
    required String narrative,
    required String language,
    required List<LawMatchResult> articles,
    required List<JurisprudenceCase> cases,
  }) async {
    calls++;
    return const FollowUpAnswer(text: 'Invented Article 9999 applies.');
  }
}

class _NoMatch implements CatalystRetrievalService {
  @override
  Future<CatalystMatchResponse> matchConcern(String concern) async =>
      CatalystMatchResponse(
        results: const [],
        warning: 'No local provision matched.',
        originalQuery: concern,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'actual retrieval produces cited, qualified on-device answers',
    () async {
      final cases = (jsonDecode(
        File('tool/retrieval_lab/diagnostics/stage1_baseline/cases.json')
            .readAsStringSync(),
      ) as List).cast<Map<String, dynamic>>();
      final query =
          cases.firstWhere((row) => row['datasetId'] == 'CC-EV-014')['query']
              as String;
      final vectors = jsonDecode(
        File('tool/retrieval_lab/diagnostics/stage1_baseline/vectors.json')
            .readAsStringSync(),
      ) as Map<String, dynamic>;
      final online = _Online();
      final conversation = CaseConversation.empty(
        service: LocalSemanticRetrievalService(
          queryEncoder: _FixtureEncoder(vectors),
          queryPreprocessor: const _Passthrough(),
        ),
        followUp: online,
      );
      await conversation.send(query);
      final answer = conversation.messages.last;
      expect(answer.isError, isFalse);
      expect(answer.mode, RetrievalMode.onDevice);
      expect(answer.text, contains('CivilCode 1956'));
      expect(answer.text, contains('Possible connection'));
      expect(answer.text, isNot(contains('related to 000')));
      expect(answer.text, contains('not legal advice'));
      expect(answer.text, contains('may not cover every relevant law'));
      for (final result in conversation.results) {
        expect(
          answer.text,
          contains('${result.lawName} ${result.articleNumber}'),
        );
      }

      await conversation.send('Why is this relevant?');
      final followUp = conversation.messages.last;
      expect(followUp.mode, RetrievalMode.onDevice);
      expect(followUp.text, contains('CivilCode 1956'));
      expect(followUp.text, contains('Provision excerpt:'));
      expect(followUp.text, isNot(contains('Article 9999')));
      expect(online.calls, 0);
      conversation.dispose();
    },
  );

  test('no-match follow-ups do not call an online answerer', () async {
    final online = _Online();
    final conversation = CaseConversation.empty(
      service: _NoMatch(),
      followUp: online,
      loadCases: () async =>
          throw StateError('Must not load cases without a provision.'),
    );
    await conversation.send(
      'A concern that the local corpus does not address.',
    );
    expect(conversation.messages.last.text, contains('may not contain'));
    await conversation.send('Are there Supreme Court cases about this?');
    expect(
      conversation.messages.last.text,
      contains('No provision has been matched'),
    );
    expect(conversation.messages.last.mode, RetrievalMode.onDevice);
    expect(online.calls, 0);
    conversation.dispose();
  });

  test('statutory follow-ups do not invent missing provision text', () async {
    final online = _Online();
    final conversation = CaseConversation.forArticle(
      service: _NoMatch(),
      result: const LawMatchResult(
        lawName: 'Civil Code',
        articleNumber: 'Article 10',
        title: 'Test',
        description: 'Unverified description',
        matchScore: 80,
      ),
      followUp: online,
    );
    await conversation.send('Why is this relevant?');
    expect(conversation.messages.last.text, contains('text is unavailable'));
    expect(
      conversation.messages.last.text,
      isNot(contains('Provision excerpt:')),
    );
    await conversation.send('Explain it in simpler words');
    expect(conversation.messages.last.text, contains('text is unavailable'));
    expect(
      conversation.messages.last.text,
      isNot(contains('Unverified description')),
    );
    expect(online.calls, 0);
    conversation.dispose();
  });
}
