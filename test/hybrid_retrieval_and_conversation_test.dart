import 'dart:math';

import 'package:catol/services/case_conversation.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:catol/services/lexical_index.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('query analysis', () {
    test('keeps negation cues and detects the domain', () {
      final analysis = analyzeQuery('Hindi ko pinirmahan yung kontrata.');
      expect(analysis.negationCues, contains('hindi'));
      expect(analysis.original, 'Hindi ko pinirmahan yung kontrata.');
      expect(analysis.needsClarification, isFalse);
    });

    test('adds English glossary terms for Tagalog legal words', () {
      final analysis = analyzeQuery('Ayaw ibalik ng seller yung pera ko');
      expect(analysis.glossaryTerms, isNotEmpty);
    });

    test('flags one-word input for clarification', () {
      final analysis = analyzeQuery('hello');
      expect(analysis.needsClarification, isTrue);
      expect(analysis.clarifyingQuestion, isNotEmpty);
    });

    test('collapses repeated letters and informal spellings', () {
      expect(normalizeQueryText('sobraaaa   na'), isNot(contains('aaa')));
    });
  });

  group('lexical retrieval', () {
    final index = Bm25Index.build([
      'The seller shall refund the price of a defective product.',
      'Marriage requires the consent of the parties.',
      'Support is everything indispensable for sustenance.',
    ]);

    test('ranks the document sharing content words first', () {
      final hits = index.search('refund for defective product');
      expect(hits.first.index, 0);
    });

    test('returns nothing for unknown terms', () {
      expect(index.search('zzzzqqq'), isEmpty);
    });

    test('reciprocal rank fusion rewards agreement between lists', () {
      final fused = fuseRankings([
        [5, 1, 2],
        [1, 7, 5],
      ]);
      expect(fused.first.index, 1);
      expect(fused.map((e) => e.index).toSet(), {5, 1, 2, 7});
    });
  });

  group('explanations', () {
    test('normalizes law and article ids', () {
      expect(normalizedArticleId('Family Code', '176'), 'familycode:176');
      expect(normalizedArticleId('ConsumerAct', '50'), 'consumeract:50');
    });

    test('flags known corpus defects', () {
      expect(knownCorpusIssues.keys, contains('familycode:176'));
      expect(knownCorpusIssues.keys, contains('familycode:213'));
    });
  });

  group('hybrid retrieval service', () {
    test(
      'returns distinct Top-3, extra candidates and grounded points',
      () async {
        final service = LocalSemanticRetrievalService(
          queryEncoder: _VectorEncoder(),
          queryPreprocessor: const _Passthrough(),
          minimumCosine: -1,
        );
        const concern =
            'The seller refuses to refund my money for a defective item';
        final response = await service.matchConcern(concern);

        expect(response.originalQuery, concern);
        expect(response.results.length, lessThanOrEqualTo(3));
        expect(response.results, isNotEmpty);
        final ids = {
          for (final r in response.results)
            normalizedArticleId(r.lawName, r.articleNumber),
        };
        expect(ids, hasLength(response.results.length));
        for (final result in response.results) {
          final points = result.caseExplanationPoints!;
          expect(points.last, legalInformationNotice);
          expect(
            stripEmphasis(points.first),
            contains(result.articleText!.substring(0, 15)),
          );
        }
        expect(
          response.otherCandidates.map(
            (r) => normalizedArticleId(r.lawName, r.articleNumber),
          ),
          everyElement(isNot(isIn(ids))),
        );
      },
    );

    test('shows nothing when no article clears the similarity floor', () async {
      final service = LocalSemanticRetrievalService(
        queryEncoder: _VectorEncoder(),
        queryPreprocessor: const _Passthrough(),
        minimumCosine: 1.01,
      );
      final response = await service.matchConcern(
        'some unrelated question here',
      );
      expect(response.results, isEmpty);
      expect(response.warning, contains('similar enough'));
    });

    test('asks for clarification instead of retrieving on one word', () async {
      final encoder = _VectorEncoder();
      final service = LocalSemanticRetrievalService(
        queryEncoder: encoder,
        queryPreprocessor: const _Passthrough(),
        minimumCosine: -1,
      );
      final response = await service.matchConcern('hello');
      expect(response.results, isEmpty);
      expect(response.clarifyingQuestion, isNotNull);
      expect(encoder.calls, 0);
    });

    test('uses the translated query as one dense variant', () async {
      final encoder = _VectorEncoder();
      final service = LocalSemanticRetrievalService(
        queryEncoder: encoder,
        minimumCosine: -1,
        queryPreprocessor: const _Fixed('I did not sign the contract.'),
      );
      final response = await service.matchConcern(
        'Hindi ko pinirmahan yung kontrata.',
      );
      expect(response.originalQuery, 'Hindi ko pinirmahan yung kontrata.');
      expect(response.processedQuery, 'I did not sign the contract.');
      expect(encoder.calls, greaterThanOrEqualTo(2));
    });
  });

  group('case conversation', () {
    Future<CaseConversation> started() async {
      final service = LocalSemanticRetrievalService(
        queryEncoder: _VectorEncoder(),
        queryPreprocessor: const _Passthrough(),
        minimumCosine: -1,
      );
      final narrative =
          'My landlord refuses to return my deposit after I moved out';
      final response = await service.matchConcern(narrative);
      return CaseConversation.forResponse(
        service: service,
        narrative: narrative,
        response: response,
      );
    }

    test('classifies English and Tagalog follow-ups', () {
      expect(classifyFollowUp('Why is this relevant?'), FollowUpIntent.why);
      expect(classifyFollowUp('Bakit ito ang batas?'), FollowUpIntent.why);
      expect(
        classifyFollowUp('Explain it in simpler words'),
        FollowUpIntent.simpler,
      );
      expect(
        classifyFollowUp('What other law might apply?'),
        FollowUpIntent.otherLaws,
      );
      expect(
        classifyFollowUp('What facts should I clarify?'),
        FollowUpIntent.missingFacts,
      );
      expect(
        classifyFollowUp('What if we were not married?'),
        FollowUpIntent.newFact,
      );
      expect(
        classifyFollowUp('How do I file a case?'),
        FollowUpIntent.procedure,
      );
    });

    test('answers why/simpler from the matched article', () async {
      final conversation = await started();
      await conversation.send('Why is this relevant?');
      await conversation.send('Explain it in simpler words');
      expect(conversation.messages, hasLength(4));
      expect(conversation.messages[1].text, contains('may be relevant'));
      expect(conversation.messages[3].text, contains('paraphrase'));
      expect(conversation.messages[1].text, contains(legalInformationNotice));
    });

    test('procedure questions are refused as outside the corpus', () async {
      final conversation = await started();
      await conversation.send('How do I file a case?');
      expect(conversation.messages.last.text, contains('statutory text only'));
    });

    test(
      'a new fact reruns retrieval and is kept separate from the narrative',
      () async {
        final conversation = await started();
        final narrative = conversation.narrative;
        await conversation.send('What if there was no written lease?');
        expect(conversation.narrative, narrative);
        expect(conversation.newFacts, ['What if there was no written lease?']);
        expect(conversation.messages.last.text, contains('new fact'));
      },
    );

    test('a fresh conversation never inherits earlier case context', () async {
      final first = await started();
      await first.send('What if there was no written lease?');
      final service = LocalSemanticRetrievalService(
        queryEncoder: _VectorEncoder(),
        queryPreprocessor: const _Passthrough(),
        minimumCosine: -1,
      );
      final second = CaseConversation.empty(service: service);
      expect(second.narrative, isNull);
      expect(second.newFacts, isEmpty);
      await second.send('Hindi ako binayaran ng employer ko sa trabaho');
      expect(second.narrative, 'Hindi ako binayaran ng employer ko sa trabaho');
      expect(second.newFacts, isEmpty);
    });

    test('service errors become an error message, not a crash', () async {
      final conversation = CaseConversation.empty(service: _ThrowingService());
      await conversation.send('some legal concern here');
      expect(conversation.messages.last.isError, isTrue);
      expect(conversation.isBusy, isFalse);
    });
  });
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();

  @override
  Future<String> preprocess(String query) async => query;
}

class _Fixed implements LegalQueryPreprocessor {
  const _Fixed(this.text);

  final String text;

  @override
  Future<String> preprocess(String query) async => text;
}

/// Deterministic unit vector derived from the token ids; no ONNX needed.
class _VectorEncoder implements LocalQueryEncoder {
  int calls = 0;

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    calls++;
    final vector = List<double>.filled(384, 0);
    for (final id in inputIds) {
      vector[id % 384] += 1;
    }
    final norm = vector.fold<double>(0, (s, v) => s + v * v);
    final scale = norm == 0 ? 1.0 : 1 / sqrt(norm);
    return [for (final v in vector) v * scale];
  }
}

class _ThrowingService implements CatalystRetrievalService {
  @override
  Future<CatalystMatchResponse> matchConcern(String concern) =>
      throw StateError('boom');
}
