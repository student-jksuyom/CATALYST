import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:catol/main.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:catol/services/local_cross_encoder_reranker.dart';
import 'package:catol/services/local_tokenizer.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the app defaults to local retrieval regardless of proxy configuration',
    () {
      expect(
        CatalystApp().retrievalService,
        isA<LocalSemanticRetrievalService>(),
      );
    },
  );

  test('ranks corpus articles and maps scores and metadata', () async {
    final encoder = _FixedEncoder(_basisVector());
    final service = LocalSemanticRetrievalService(
      queryEncoder: encoder,
      queryPreprocessor: const _PassthroughPreprocessor(),
      strategy: CatalystRetrievalStrategy.denseOnly,
    );

    final response = await service.matchConcern('  defective phone  ');

    expect(response.originalQuery, 'defective phone');
    expect(response.processedQuery, 'defective phone');
    expect(encoder.lastInputIds, isNotEmpty);
    expect(encoder.lastAttentionMask, hasLength(encoder.lastInputIds!.length));
    expect(response.warning, retrievalWarning);
    expect(response.results, hasLength(3));

    final first = response.results[0];
    expect(first.articleText, isNotEmpty);
    expect(first.description, first.articleText);
    expect(first.lawName, isNotEmpty);
    expect(first.articleNumber, isNotEmpty);

    final scores = response.results.map((result) => result.matchScore).toList();
    expect(scores, orderedEquals([...scores]..sort((a, b) => b.compareTo(a))));
    expect(scores, everyElement(inInclusiveRange(0, 100)));
  });

  test(
    'cross-encoder flag reranks candidates and preserves hybrid fallback',
    () async {
      const concern = 'defective phone';
      expect(
        RetrievalExperimentConfig
            .selectedProduction
            .enableCrossEncoderReranking,
        isTrue,
      );
      final config = RetrievalExperimentConfig(
        domainIndependentTraining: true,
        enableCrossEncoderReranking: true,
        crossEncoderCandidateLimit: 15,
        crossEncoderWeight: 0.5,
      );
      final reranker = _TargetLastCandidateReranker();
      RetrievalDiagnosticTrace? trace;
      final baseline = await LocalSemanticRetrievalService(
        queryEncoder: _FixedEncoder(_basisVector()),
        queryPreprocessor: const _PassthroughPreprocessor(),
        minimumCosine: -1,
        experimentConfig: RetrievalExperimentConfig.originalProduction,
        crossEncoderReranker: reranker,
      ).matchConcern(concern);
      expect(reranker.calls, 0);

      final reranked = await LocalSemanticRetrievalService(
        queryEncoder: _FixedEncoder(_basisVector()),
        queryPreprocessor: const _PassthroughPreprocessor(),
        minimumCosine: -1,
        experimentConfig: config,
        crossEncoderReranker: reranker,
        onDiagnosticTrace: (value) => trace = value,
      ).matchConcern(concern);

      expect(config.enableCrossEncoderReranking, isTrue);
      expect(trace?.eligibleIds, isNotEmpty);
      expect(reranker.calls, 1);
      expect(reranker.candidates, hasLength(15));
      expect(
        normalizedArticleId(
          reranked.results.first.lawName,
          reranked.results.first.articleNumber,
        ),
        reranker.candidates.last.articleId,
      );
      expect(
        normalizedArticleId(
          baseline.results.first.lawName,
          baseline.results.first.articleNumber,
        ),
        isNot(reranker.candidates.last.articleId),
      );
      final expectedFinalScore =
          0.5 * (1 / (1 + math.exp(-10))) +
          0.5 * reranker.candidates.last.hybridScore;
      expect(
        reranked.results.first.matchScore,
        double.parse(expectedFinalScore.toStringAsFixed(4)) * 100,
      );
      expect(reranked.results.first.rawCosineScore, isNotNull);
      expect(reranked.results.first.rawCosineScore, inInclusiveRange(-1, 1));
    },
  );

  test('cross-encoder inference failure retains hybrid ranking', () async {
    const concern = 'defective phone';
    const config = RetrievalExperimentConfig(
      domainIndependentTraining: true,
      enableCrossEncoderReranking: true,
      crossEncoderCandidateLimit: 15,
    );
    final baseline = await LocalSemanticRetrievalService(
      queryEncoder: _FixedEncoder(_basisVector()),
      queryPreprocessor: const _PassthroughPreprocessor(),
      minimumCosine: -1,
    ).matchConcern(concern);
    final fallback = await LocalSemanticRetrievalService(
      queryEncoder: _FixedEncoder(_basisVector()),
      queryPreprocessor: const _PassthroughPreprocessor(),
      minimumCosine: -1,
      experimentConfig: config,
      crossEncoderReranker: _FailingCrossEncoderReranker(),
    ).matchConcern(concern);

    expect(
      fallback.results.map(
        (result) => normalizedArticleId(result.lawName, result.articleNumber),
      ),
      baseline.results.map(
        (result) => normalizedArticleId(result.lawName, result.articleNumber),
      ),
    );
    for (var index = 0; index < baseline.results.length; index++) {
      expect(
        fallback.results[index].matchScore,
        baseline.results[index].matchScore,
      );
      expect(
        fallback.results[index].rawCosineScore,
        baseline.results[index].rawCosineScore,
      );
    }
  });

  test('abstains early for explicit unsupported legal topics', () async {
    final encoder = _FixedEncoder(_basisVector());
    final reranker = _TargetLastCandidateReranker();
    final service = LocalSemanticRetrievalService(
      queryEncoder: encoder,
      queryPreprocessor: const _PassthroughPreprocessor(),
      experimentConfig: RetrievalExperimentConfig.developmentCrossEncoder,
      crossEncoderReranker: reranker,
    );

    final response = await service.matchConcern(
      'I was arrested after a police investigation. What criminal charge?',
    );

    expect(response.results, isEmpty);
    expect(response.warning, contains('outside CATALYST’s local database'));
    expect(encoder.lastInputIds, isNull);
    expect(reranker.calls, 0);
  });

  test(
    'explains the local semantic link with concern and provision evidence',
    () async {
      const concern = 'My landlord did not return my deposit after eviction.';
      final service = LocalSemanticRetrievalService(
        queryEncoder: _FixedEncoder(_basisVector()),
        queryPreprocessor: const _PassthroughPreprocessor(),
        minimumCosine: -1,
      );

      final response = await service.matchConcern(concern);
      final result = response.results.first;
      final explanation = result.explanationVariants!['en']!.points.first;
      final quotedPassage = RegExp(
        r'passage similar to the overall concern: “([^”]+)”',
      ).firstMatch(explanation)![1]!;

      expect(explanation, contains('Possible connection found on-device'));
      expect(explanation, contains(concern));
      expect(
        result.articleText!.replaceAll(RegExp(r'\s+'), ' '),
        contains(quotedPassage.replaceAll(RegExp(r'\.\.\.$'), '')),
      );
      final corpus = jsonDecode(
        await rootBundle.loadString('assets/data/legal_articles.json'),
      ) as List;
      final articleIndex = corpus.indexWhere(
        (article) =>
            article['Law'] == result.lawName &&
            article['Article'] == result.articleNumber &&
            article['Article Text'] == result.articleText,
      );
      final owners = jsonDecode(
        await rootBundle.loadString('assets/data/chunk_owners_e5.json'),
      ) as List;
      final vectors = await rootBundle.load(
        'assets/data/chunk_embeddings_e5.f32',
      );
      var bestScore = double.negativeInfinity;
      var bestChunk = 0;
      var chunkNumber = 0;
      for (var i = 0; i < owners.length; i++) {
        if (owners[i] != articleIndex) continue;
        final score = vectors.getFloat32(i * 384 * 4, Endian.little);
        if (score > bestScore) {
          bestScore = score;
          bestChunk = chunkNumber;
        }
        chunkNumber++;
      }
      final words = result.articleText!
          .split(RegExp(r'\s+'))
          .where((word) => word.isNotEmpty)
          .toList();
      final passage = words.length <= 75
          ? words.join(' ')
          : words.skip(bestChunk * 40).take(60).join(' ');
      expect(quotedPassage, firstStatement(passage, maxLength: 300));
      expect(explanation, contains('does not verify'));
      expect(result.hasAiExplanation, isFalse);
    },
  );

  test('rejects empty and oversized concerns before initialization', () async {
    final encoder = _FixedEncoder(_basisVector());
    final service = LocalSemanticRetrievalService(
      queryEncoder: encoder,
      queryPreprocessor: const _PassthroughPreprocessor(),
    );

    await expectLater(
      service.matchConcern(' \n\t '),
      throwsA(
        isA<CatalystRetrievalException>().having(
          (error) => error.failure,
          'failure',
          CatalystRetrievalFailure.invalidInput,
        ),
      ),
    );
    await expectLater(
      service.matchConcern(List.filled(5001, 'x').join()),
      throwsA(
        isA<CatalystRetrievalException>().having(
          (error) => error.failure,
          'failure',
          CatalystRetrievalFailure.invalidInput,
        ),
      ),
    );
    expect(encoder.lastInputIds, isNull);
  });

  test(
    'surfaces inference errors without returning fallback matches',
    () async {
      final service = LocalSemanticRetrievalService(
        queryEncoder: _FailingEncoder(),
        queryPreprocessor: const _PassthroughPreprocessor(),
      );

      await expectLater(
        service.matchConcern('A valid legal concern'),
        throwsA(
          isA<CatalystRetrievalException>()
              .having(
                (error) => error.failure,
                'failure',
                CatalystRetrievalFailure.inference,
              )
              .having(
                (error) => error.message,
                'message',
                contains('on-device language model'),
              ),
        ),
      );
    },
  );

  test('falls back to the original query when translation fails', () async {
    final encoder = _FixedEncoder(_basisVector());
    final service = LocalSemanticRetrievalService(
      queryEncoder: encoder,
      minimumCosine: -1,
      queryPreprocessor: const _FailingPreprocessor(),
    );
    final tokenizer = await LocalTokenizer.load();
    const concern = 'Hindi ko pinirmahan yung kontrata.';

    final response = await service.matchConcern(concern);

    expect(response.originalQuery, concern);
    expect(response.processedQuery, concern);
    expect(
      encoder.allInputIds,
      anyElement(
        orderedEquals(
          tokenizer.encode('query: ${normalizeQueryText(concern)}').ids,
        ),
      ),
    );
    expect(response.results, hasLength(3));
  });

  test(
    'keeps the translation for lexical matching, not dense encoding',
    () async {
      const concern = 'Hindi ko pinirmahan yung kontrata.';
      const translated = 'I did not sign the contract.';
      final encoder = _FixedEncoder(_basisVector());
      final service = LocalSemanticRetrievalService(
        queryEncoder: encoder,
        minimumCosine: -1,
        queryPreprocessor: const _FixedPreprocessor(translated),
      );
      final tokenizer = await LocalTokenizer.load();

      final response = await service.matchConcern(concern);

      expect(response.originalQuery, concern);
      expect(response.processedQuery, translated);
      expect(
        encoder.allInputIds,
        anyElement(
          orderedEquals(
            tokenizer.encode('query: ${normalizeQueryText(concern)}').ids,
          ),
        ),
      );
      expect(
        encoder.allInputIds,
        isNot(
          anyElement(
            orderedEquals(
              tokenizer.encode('query: ${normalizeQueryText(translated)}').ids,
            ),
          ),
        ),
      );
      expect(response.results, hasLength(3));
    },
  );

  test('rejects non-normalized query embeddings', () {
    final articles = List.generate(
      3,
      (index) => CatalystLegalArticle(
        law: 'Law $index',
        article: '$index',
        title: '',
        chapterTitle: '',
        articleText: '',
      ),
    );
    final embeddings = Float32List(3 * 384);
    for (var index = 0; index < 3; index++) {
      embeddings[index * 384] = 1;
    }

    expect(
      () => rankCorpusArticles(
        articles: articles,
        embeddings: embeddings,
        queryEmbedding: List<double>.filled(384, 0),
      ),
      throwsA(
        isA<CatalystRetrievalException>().having(
          (error) => error.failure,
          'failure',
          CatalystRetrievalFailure.invalidEmbedding,
        ),
      ),
    );
  });
}

List<double> _basisVector() {
  final vector = List<double>.filled(384, 0);
  vector[0] = 1;
  return vector;
}

class _FixedEncoder implements LocalQueryEncoder {
  _FixedEncoder(this.vector);

  final List<double> vector;
  List<int>? lastInputIds;
  List<int>? lastAttentionMask;
  final List<List<int>> allInputIds = [];

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    lastInputIds = inputIds;
    allInputIds.add(inputIds);
    lastAttentionMask = attentionMask;
    return vector;
  }
}

class _TargetLastCandidateReranker implements ArticleCrossEncoderReranker {
  int calls = 0;
  List<CrossEncoderCandidate> candidates = const [];

  @override
  Future<List<double>> score(
    String query,
    List<CrossEncoderCandidate> candidates,
  ) async {
    calls++;
    this.candidates = candidates;
    return [
      for (var index = 0; index < candidates.length; index++)
        index == candidates.length - 1 ? 10 : -10,
    ];
  }
}

class _FailingCrossEncoderReranker implements ArticleCrossEncoderReranker {
  @override
  Future<List<double>> score(
    String query,
    List<CrossEncoderCandidate> candidates,
  ) {
    throw StateError('test inference failure');
  }
}

class _FailingEncoder implements LocalQueryEncoder {
  @override
  Future<List<double>> encode(List<int> inputIds, List<int> attentionMask) {
    throw StateError('private inference failure');
  }
}

class _PassthroughPreprocessor implements LegalQueryPreprocessor {
  const _PassthroughPreprocessor();

  @override
  Future<String> preprocess(String query) async => query;
}

class _FailingPreprocessor implements LegalQueryPreprocessor {
  const _FailingPreprocessor();

  @override
  Future<String> preprocess(String query) {
    throw StateError('translation model unavailable');
  }
}

class _FixedPreprocessor implements LegalQueryPreprocessor {
  const _FixedPreprocessor(this.processedQuery);

  final String processedQuery;

  @override
  Future<String> preprocess(String query) async => processedQuery;
}
