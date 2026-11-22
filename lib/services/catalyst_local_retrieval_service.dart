import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../models/law_match_result.dart';
import 'explanation_builder.dart';
import 'explanation_language.dart';
import 'legal_query_preprocessor.dart';
import 'lexical_index.dart';
import 'local_cross_encoder_reranker.dart';
import 'local_tokenizer.dart';
import 'query_analysis.dart';

const String retrievalWarning =
    'Similarity is a retrieval signal, not a probability or legal conclusion.';

const int _embeddingDimensions = 384;
const int _topResultCount = 3;
const int _allResultCount = 15;
const int _candidatePoolSize = 50;

// Reciprocal-rank-fusion constant; 10-30 performed equivalently on the lab set.
const int _fusionK = 20;

// multilingual-e5-small is trained with this query prefix.
const String _queryPrefix = 'query: ';

/// Candidates whose best cosine similarity is below this are not returned.
// Heuristic for multilingual-e5-small, whose cosines sit in a narrow band:
// off-topic probes peaked around 0.75-0.80 and the on-topic lab queries
// started at 0.80. It is a coarse gate, not a relevance guarantee.
const double _defaultMinimumCosine = 0.80;

// Display calibration: cosine 0.75 (noise level) maps to 0% and 0.90 to 100%.
const double _displayFloorCosine = 0.75;
const double _displayCeilingCosine = 0.90;

// Share of the blended score given to the normalized BM25 signal.
const double _lexicalWeight = 0.15;
const String _articlesAssetPath = 'assets/data/legal_articles.json';
const String _chunkEmbeddingsAssetPath = 'assets/data/chunk_embeddings_e5.f32';
const String _chunkOwnersAssetPath = 'assets/data/chunk_owners_e5.json';
const String _trainingQueryEmbeddingsAssetPath =
    'assets/data/training_query_embeddings_e5.f32';
const String _trainingQueryLabelsAssetPath =
    'assets/data/training_query_labels_e5.json';
const String _encoderAssetPath = 'assets/models/catalyst_encoder_e5.onnx';
const int _trainingNeighborCount = 3;
const double _minimumTrainingQueryCosine = 0.90;
const double _trainingSignalWeight = 0.30;

abstract interface class CatalystRetrievalService {
  Future<CatalystMatchResponse> matchConcern(String concern);
}

abstract interface class LocalQueryEncoder {
  Future<List<double>> encode(List<int> inputIds, List<int> attentionMask);
}

enum CatalystRetrievalStrategy {
  /// Legacy path: one dense query, plain cosine Top-3.
  denseOnly,

  /// Dense variants fused with BM25; the default for the app.
  hybrid,
}

enum RetrievalRankingMode { calibratedScore, rankBased }

class RetrievalExperimentConfig {
  const RetrievalExperimentConfig({
    this.domainIndependentTraining = false,
    this.bm25Weight = _lexicalWeight,
    this.trainingQueryWeight = _trainingSignalWeight,
    this.rrfK = _fusionK,
    this.rankingMode = RetrievalRankingMode.calibratedScore,
    this.candidatePoolSize = _candidatePoolSize,
    this.experimentalConceptExpansion = false,
    this.experimentalChunkAggregation = false,
    this.experimentalGateRecovery = false,
    this.experimentalOverlapReranking = false,
    this.enableDenseRetrieval = true,
    this.enableLexicalRetrieval = true,
    this.enableTrainingExampleRetrieval = true,
    this.disableTrainingSignal = false,
    this.enableCrossEncoderReranking = false,
    this.crossEncoderCandidateLimit = 100,
    this.crossEncoderWeight = 0.5,
  }) : assert(bm25Weight >= 0 && bm25Weight <= 1),
       assert(trainingQueryWeight >= 0 && trainingQueryWeight <= 1),
       assert(crossEncoderWeight >= 0 && crossEncoderWeight <= 1),
       assert(rrfK > 0),
       assert(candidatePoolSize > 0),
       assert(crossEncoderCandidateLimit > 0);

  static const originalProduction = RetrievalExperimentConfig();
  static const highestMetricDevelopment = RetrievalExperimentConfig(
    domainIndependentTraining: true,
    bm25Weight: 0.15,
    trainingQueryWeight: 0.45,
    rrfK: 20,
    rankingMode: RetrievalRankingMode.rankBased,
  );
  static const selectedProduction = RetrievalExperimentConfig(
    domainIndependentTraining: true,
    bm25Weight: 0.15,
    trainingQueryWeight: 0.30,
    rrfK: 20,
    rankingMode: RetrievalRankingMode.calibratedScore,
    enableCrossEncoderReranking: true,
    crossEncoderCandidateLimit: 100,
    crossEncoderWeight: 0.5,
  );
  static const developmentCrossEncoder = RetrievalExperimentConfig(
    domainIndependentTraining: true,
    enableCrossEncoderReranking: true,
    crossEncoderCandidateLimit: 100,
    crossEncoderWeight: 0.5,
  );

  final bool domainIndependentTraining;
  final double bm25Weight;
  final double trainingQueryWeight;
  final int rrfK;
  final RetrievalRankingMode rankingMode;
  final int candidatePoolSize;
  final bool experimentalConceptExpansion;
  final bool experimentalChunkAggregation;
  final bool experimentalGateRecovery;
  final bool experimentalOverlapReranking;
  final bool enableDenseRetrieval;
  final bool enableLexicalRetrieval;
  final bool enableTrainingExampleRetrieval;
  final bool disableTrainingSignal;
  final bool enableCrossEncoderReranking;
  final int crossEncoderCandidateLimit;
  final double crossEncoderWeight;
}

class RetrievalDiagnosticTrace {
  const RetrievalDiagnosticTrace({
    required this.semanticLists,
    required this.lexicalIds,
    required this.trainingIds,
    required this.combinedIds,
    required this.eligibleIds,
    required this.cosines,
  });

  final List<List<String>> semanticLists;
  final List<String> lexicalIds;
  final List<String> trainingIds;
  final List<String> combinedIds;
  final List<String> eligibleIds;
  final Map<String, double> cosines;
}

enum CatalystRetrievalFailure {
  invalidInput,
  assetsUnavailable,
  modelInitialization,
  inference,
  invalidEmbedding,
}

class CatalystRetrievalException implements Exception {
  const CatalystRetrievalException(this.failure, this.message);

  final CatalystRetrievalFailure failure;
  final String message;

  @override
  String toString() => message;
}

/// Whether an XAI follow-up answer used the internet.
enum RetrievalMode {
  /// The answer was produced on-device.
  onDevice,

  /// The configured online follow-up service returned the answer.
  online,

  /// Online follow-up failed and the app returned an on-device answer.
  onDeviceFallback,
}

class CatalystMatchResponse {
  const CatalystMatchResponse({
    required this.results,
    this.originalQuery = '',
    this.processedQuery = '',
    this.warning = retrievalWarning,
    this.clarifyingQuestion,
    this.otherCandidates = const [],
    this.analysis,
  });

  final List<LawMatchResult> results;
  final String originalQuery;
  final String processedQuery;
  final String warning;

  /// Set instead of results when the narrative is too thin to search.
  final String? clarifyingQuestion;

  /// Next-best distinct provisions after the Top-3, for "other laws" requests.
  final List<LawMatchResult> otherCandidates;
  final QueryAnalysis? analysis;
}

class CatalystLegalArticle {
  const CatalystLegalArticle({
    required this.law,
    required this.article,
    required this.title,
    required this.chapterTitle,
    required this.articleText,
  });

  factory CatalystLegalArticle.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('A legal article entry is not an object.');
    }

    String readString(String key) {
      final field = value[key];
      if (field is! String) {
        throw FormatException('A legal article is missing the "$key" field.');
      }
      return field;
    }

    return CatalystLegalArticle(
      law: readString('Law'),
      article: readString('Article'),
      title: readString('Title'),
      chapterTitle: readString('Chapter Title'),
      articleText: readString('Article Text'),
    );
  }

  final String law;
  final String article;
  final String title;
  final String chapterTitle;
  final String articleText;
}

class LocalSemanticRetrievalService implements CatalystRetrievalService {
  const LocalSemanticRetrievalService({
    this._queryEncoder,
    this._queryPreprocessor = defaultLegalQueryPreprocessor,
    this._strategy = CatalystRetrievalStrategy.hybrid,
    this._minimumCosine = _defaultMinimumCosine,
    this._resultLimit = _allResultCount,
    this.experimentConfig = RetrievalExperimentConfig.selectedProduction,
    this.onDiagnosticTrace,
    this.crossEncoderReranker,
  });

  static Future<_LocalRetrievalResources>? _resourcesFuture;
  static Future<OrtSession>? _sessionFuture;
  static final ArticleCrossEncoderReranker _defaultCrossEncoderReranker =
      LocalCrossEncoderReranker();

  final LocalQueryEncoder? _queryEncoder;
  final LegalQueryPreprocessor _queryPreprocessor;
  final CatalystRetrievalStrategy _strategy;
  final double _minimumCosine;
  final int _resultLimit;
  final RetrievalExperimentConfig experimentConfig;
  final void Function(RetrievalDiagnosticTrace)? onDiagnosticTrace;
  final ArticleCrossEncoderReranker? crossEncoderReranker;

  /// A provision from the local corpus by law and article number, or null.
  /// Duplicate ids resolve to the first corpus entry.
  Future<LawMatchResult?> lookupArticle(
    String law,
    String article, {
    double matchScore = 0,
    String? contextualExplanation,
    bool hasAiExplanation = false,
    List<String> explanationPoints = const [],
    Map<String, ExplanationVariant>? explanationVariants,
    String? defaultExplanationLanguage,
  }) async {
    final resources = await _loadResources();
    final wanted = normalizedArticleId(law, article);
    for (final entry in resources.articles) {
      if (normalizedArticleId(entry.law, entry.article) != wanted) continue;
      return LawMatchResult(
        lawName: entry.law,
        articleNumber: entry.article,
        title: entry.title,
        chapterTitle: entry.chapterTitle,
        description: entry.articleText,
        articleText: entry.articleText,
        matchScore: matchScore.clamp(0, 100).toDouble(),
        contextualExplanation: contextualExplanation,
        hasAiExplanation: hasAiExplanation,
        caseExplanationPoints: explanationPoints,
        explanationVariants: explanationVariants,
        defaultExplanationLanguage: defaultExplanationLanguage,
      );
    }
    return null;
  }

  @override
  Future<CatalystMatchResponse> matchConcern(String concern) async {
    final normalizedConcern = concern.trim();
    if (normalizedConcern.isEmpty) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidInput,
        'Please enter a legal concern before searching.',
      );
    }
    if (normalizedConcern.length > 5000) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidInput,
        'Your concern is too long. Please keep it under 5,000 characters.',
      );
    }

    final QueryAnalysis? analysis =
        _strategy == CatalystRetrievalStrategy.hybrid
        ? analyzeQuery(normalizedConcern)
        : null;
    if (analysis != null && analysis.needsClarification) {
      return CatalystMatchResponse(
        results: const [],
        originalQuery: normalizedConcern,
        processedQuery: normalizedConcern,
        clarifyingQuestion: analysis.clarifyingQuestion,
        analysis: analysis,
      );
    }
    if (analysis != null && isClearlyOutsideCatalystScope(normalizedConcern)) {
      return CatalystMatchResponse(
        results: const [],
        originalQuery: normalizedConcern,
        processedQuery: normalizedConcern,
        warning:
            'This may need legal rules outside CATALYST’s local database. '
            'No article was selected. If your concern also involves a loan, '
            'lease, family matter, or consumer product, add those details so '
            'relevant provisions can still be considered.',
        analysis: analysis,
      );
    }

    final _LocalRetrievalResources resources;
    try {
      resources = await _loadResources();
    } on CatalystRetrievalException {
      rethrow;
    } catch (error, stackTrace) {
      developer.log(
        'Local retrieval assets could not be loaded (${error.runtimeType})',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.assetsUnavailable,
        'The local legal corpus or tokenizer could not be loaded. '
        'Please restart the app and try again.',
      );
    }

    var processedQuery = normalizedConcern;
    try {
      final candidate = await _queryPreprocessor.preprocess(normalizedConcern);
      if (candidate.trim().isEmpty) {
        throw StateError('The query preprocessor returned an empty query.');
      }
      processedQuery = candidate.trim();
    } catch (error, stackTrace) {
      developer.log(
        'Query translation failed (${error.runtimeType}); using the original query',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (_strategy == CatalystRetrievalStrategy.hybrid) {
      return _matchHybrid(
        resources: resources,
        analysis: analysis!,
        originalQuery: normalizedConcern,
        processedQuery: processedQuery,
      );
    }

    final List<double> queryVector = await _encodeQuery(
      resources,
      processedQuery,
    );

    try {
      final scores = _articleCosines(resources, queryVector);
      final order = List<int>.generate(scores.length, (i) => i)
        ..sort((a, b) {
          final byScore = scores[b].compareTo(scores[a]);
          return byScore != 0 ? byScore : a.compareTo(b);
        });
      final results = [
        for (final index in order.take(_topResultCount))
          _toResult(resources, index, scores[index]),
      ];
      return CatalystMatchResponse(
        results: List.unmodifiable(results),
        originalQuery: normalizedConcern,
        processedQuery: processedQuery,
      );
    } on CatalystRetrievalException {
      rethrow;
    } catch (error, stackTrace) {
      developer.log(
        'Local legal article ranking failed (${error.runtimeType})',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The local model returned invalid matching data. Please try again.',
      );
    }
  }

  Future<List<double>> _encodeQuery(
    _LocalRetrievalResources resources,
    String text,
  ) async {
    try {
      final encoding = resources.tokenizer.encode('$_queryPrefix$text');
      return _queryEncoder == null
          ? await _encodeWithOnnx(encoding.ids, encoding.attentionMask)
          : await _queryEncoder.encode(encoding.ids, encoding.attentionMask);
    } on CatalystRetrievalException {
      rethrow;
    } catch (error, stackTrace) {
      developer.log(
        'On-device query inference failed (${error.runtimeType})',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.inference,
        'The on-device language model could not process this concern. '
        'Please try again.',
      );
    }
  }

  /// Dense multi-variant retrieval fused with BM25 by reciprocal rank.
  ///
  /// Dense variants: the user's normalized wording and English keywords from
  /// the Filipino glossary (when any). The machine translation feeds only the
  /// lexical signal: the multilingual encoder reads Filipino directly, and in
  /// the offline comparison dense translated variants scored no better.
  /// Each article is scored by its best-matching chunk, so a long article
  /// is not diluted by its unrelated clauses.
  Future<CatalystMatchResponse> _matchHybrid({
    required _LocalRetrievalResources resources,
    required QueryAnalysis analysis,
    required String originalQuery,
    required String processedQuery,
  }) async {
    final variants = <String>[];
    void addVariant(String? text) {
      final value = text?.trim() ?? '';
      if (value.isNotEmpty && !variants.contains(value)) variants.add(value);
    }

    addVariant(analysis.normalized);
    addVariant(analysis.glossaryQuery);

    final useDenseRetrieval = experimentConfig.enableDenseRetrieval;
    final useLexicalRetrieval = experimentConfig.enableLexicalRetrieval;
    final useTrainingExamples =
        experimentConfig.enableTrainingExampleRetrieval &&
        !experimentConfig.disableTrainingSignal;
    final hasCorpusRetrieval = useDenseRetrieval || useLexicalRetrieval;
    final denseWeight = !useDenseRetrieval
        ? 0.0
        : useLexicalRetrieval
        ? 1 - experimentConfig.bm25Weight
        : 1.0;
    final lexicalWeight = !useLexicalRetrieval
        ? 0.0
        : useDenseRetrieval
        ? experimentConfig.bm25Weight
        : 1.0;
    final trainingWeight = !experimentConfig.enableTrainingExampleRetrieval
        ? 0.0
        : experimentConfig.disableTrainingSignal || hasCorpusRetrieval
        ? experimentConfig.trainingQueryWeight
        : 1.0;

    final articles = resources.articles;
    final bestCosine = List<double>.filled(articles.length, -1);
    final cosineSum = List<double>.filled(articles.length, 0);
    final denseLists = <List<int>>[];
    List<double>? primaryVector;
    for (final variant in variants) {
      final vector = await _encodeQuery(resources, variant);
      _validateQueryEmbedding(vector);
      primaryVector ??= vector;
      final gateScores = experimentConfig.experimentalChunkAggregation
          ? List<double>.filled(articles.length, -1)
          : null;
      if (useDenseRetrieval) {
        final scores = _articleCosines(
          resources,
          vector,
          averageTopTwo: experimentConfig.experimentalChunkAggregation,
          bestScores: gateScores,
        );
        for (var row = 0; row < scores.length; row++) {
          final gateScore = gateScores?[row] ?? scores[row];
          if (gateScore > bestCosine[row]) bestCosine[row] = gateScore;
          cosineSum[row] += scores[row];
        }
        final order = List<int>.generate(articles.length, (i) => i)
          ..sort((a, b) {
            final byScore = scores[b].compareTo(scores[a]);
            return byScore != 0 ? byScore : a.compareTo(b);
          });
        denseLists.add(
          order
              .take(experimentConfig.candidatePoolSize)
              .toList(growable: false),
        );
      }
    }

    final trainingMatches = !useTrainingExamples
        ? (rankedIndexes: <int>[], normalizedVotes: <int, double>{})
        : _rankTrainingExamples(
            resources: resources,
            queryEmbedding: primaryVector!,
            domain: analysis.domain,
            domainIndependent: experimentConfig.domainIndependentTraining,
            candidatePoolSize: experimentConfig.candidatePoolSize,
          );
    final lexicalQuery = [
      originalQuery,
      processedQuery,
      ...analysis.glossaryTerms,
      ...expandLegalWording(originalQuery),
      if (experimentConfig.experimentalConceptExpansion)
        ...expandExperimentalLegalConcepts(originalQuery),
    ].join(' ');
    final lexical = useLexicalRetrieval
        ? resources.lexicalIndex.search(
            lexicalQuery,
            limit: experimentConfig.candidatePoolSize,
          )
        : <({int index, double score})>[];
    final fused = fuseRankings([
      ...denseLists,
      if (lexical.isNotEmpty) lexical.map((hit) => hit.index).toList(),
      if (trainingMatches.rankedIndexes.isNotEmpty)
        trainingMatches.rankedIndexes,
    ], k: experimentConfig.rrfK);

    // Keep the supervised example signal modest so it can improve ranking
    // without replacing the corpus-grounded dense and lexical matches.
    final maxLexical = lexical.isEmpty ? 0.0 : lexical.first.score;
    final lexicalScore = {for (final hit in lexical) hit.index: hit.score};
    final semanticRankScores = <int, double>{};
    for (final list in denseLists) {
      for (var rank = 0; rank < list.length; rank++) {
        final index = list[rank];
        semanticRankScores[index] =
            (semanticRankScores[index] ?? 0) +
            _normalizedReciprocalRank(rank, experimentConfig.rrfK) /
                denseLists.length;
      }
    }
    final lexicalRankScores = <int, double>{
      for (var rank = 0; rank < lexical.length; rank++)
        lexical[rank].index: _normalizedReciprocalRank(
          rank,
          experimentConfig.rrfK,
        ),
    };
    final trainingRankScores = <int, double>{
      for (var rank = 0; rank < trainingMatches.rankedIndexes.length; rank++)
        trainingMatches.rankedIndexes[rank]: _normalizedReciprocalRank(
          rank,
          experimentConfig.rrfK,
        ),
    };
    double blendedScore(int index) {
      final trainingPart = trainingMatches.normalizedVotes[index] ?? 0.0;
      if (experimentConfig.rankingMode == RetrievalRankingMode.rankBased) {
        final semanticPart = semanticRankScores[index] ?? 0.0;
        final lexicalPart = lexicalRankScores[index] ?? 0.0;
        final trainingRankPart = trainingRankScores[index] ?? 0.0;
        final corpusPart =
            denseWeight * semanticPart + lexicalWeight * lexicalPart;
        return (1 - trainingWeight) * corpusPart +
            trainingWeight * trainingRankPart;
      }
      final dense = useDenseRetrieval
          ? ((cosineSum[index] / variants.length - _displayFloorCosine) /
                    (_displayCeilingCosine - _displayFloorCosine))
                .clamp(0.0, 1.0)
          : 0.0;
      final lexicalPart = maxLexical > 0
          ? (lexicalScore[index] ?? 0) / maxLexical
          : 0.0;
      final corpusScore = denseWeight * dense + lexicalWeight * lexicalPart;
      return (1 - trainingWeight) * corpusScore + trainingWeight * trainingPart;
    }

    final blended = <int, double>{};
    final gated = <int>[
      for (final candidate in fused)
        if (!useDenseRetrieval || bestCosine[candidate.index] >= _minimumCosine)
          candidate.index,
    ];
    final originalTerms =
        experimentConfig.experimentalGateRecovery ||
            experimentConfig.experimentalOverlapReranking
        ? resources.lexicalIndex.knownTerms(originalQuery).toSet()
        : <String>{};
    final topLexical = experimentConfig.experimentalGateRecovery
        ? lexical.take(3).map((hit) => hit.index).toSet()
        : <int>{};
    int overlapCount(int index) => originalTerms
        .intersection(contentTerms(articles[index].articleText).toSet())
        .length;
    final eligible =
        experimentConfig.experimentalGateRecovery && gated.isNotEmpty
        ? [
            for (final candidate in fused)
              if (bestCosine[candidate.index] >= _minimumCosine ||
                  (bestCosine[candidate.index] >= _minimumCosine - 0.02 &&
                      topLexical.contains(candidate.index) &&
                      overlapCount(candidate.index) >= 3))
                candidate.index,
          ]
        : gated;
    for (final index in eligible) {
      blended[index] =
          (blendedScore(index) +
                  (experimentConfig.experimentalOverlapReranking &&
                          originalTerms.isNotEmpty
                      ? 0.05 * overlapCount(index) / originalTerms.length
                      : 0))
              .clamp(0.0, 1.0);
    }
    if (onDiagnosticTrace != null) {
      String id(int index) =>
          normalizedArticleId(articles[index].law, articles[index].article);
      onDiagnosticTrace!(
        RetrievalDiagnosticTrace(
          semanticLists: [
            for (final list in denseLists)
              [for (final index in list) id(index)],
          ],
          lexicalIds: [for (final hit in lexical) id(hit.index)],
          trainingIds: [
            for (final index in trainingMatches.rankedIndexes) id(index),
          ],
          combinedIds: [for (final candidate in fused) id(candidate.index)],
          eligibleIds: [for (final index in eligible) id(index)],
          cosines: {
            for (var index = 0; index < articles.length; index++)
              id(index): bestCosine[index],
          },
        ),
      );
    }
    // Stable sort: equal scores keep the fused (rank-based) order.
    final ordered = eligible.indexed.toList()
      ..sort((a, b) {
        final byScore = blended[b.$2]!.compareTo(blended[a.$2]!);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    final seenIds = <String>{};
    final rankedIndexes = <int>[];
    final candidateResultLimit = experimentConfig.enableCrossEncoderReranking
        ? math.max(_resultLimit, experimentConfig.crossEncoderCandidateLimit)
        : _resultLimit;
    for (final entry in ordered) {
      final article = articles[entry.$2];
      final id = normalizedArticleId(article.law, article.article);
      if (!seenIds.add(id)) continue;
      rankedIndexes.add(entry.$2);
      if (rankedIndexes.length == candidateResultLimit) break;
    }

    if (kDebugMode) {
      developer.log(
        'Cross-encoder enabled=${experimentConfig.enableCrossEncoderReranking} '
        'eligible=${eligible.length} '
        'rerankCandidates=${math.min(experimentConfig.crossEncoderCandidateLimit, rankedIndexes.length)}',
        name: 'catol.retrieval',
      );
    }

    var finalRankedIndexes = rankedIndexes;
    var finalRankingScores = blended;
    if (experimentConfig.enableCrossEncoderReranking &&
        rankedIndexes.isNotEmpty) {
      final reranker = crossEncoderReranker ?? _defaultCrossEncoderReranker;
      final rerankCount = math.min(
        experimentConfig.crossEncoderCandidateLimit,
        rankedIndexes.length,
      );
      final rerankIndexes = rankedIndexes.take(rerankCount).toList();
      final rerankStopwatch = Stopwatch()..start();
      var inferenceSucceeded = false;
      try {
        final logits = await reranker.score(originalQuery, [
          for (final index in rerankIndexes)
            CrossEncoderCandidate(
              articleId: normalizedArticleId(
                articles[index].law,
                articles[index].article,
              ),
              articleText: articles[index].articleText,
              hybridScore: double.parse(blended[index]!.toStringAsFixed(4)),
            ),
        ]);
        if (logits.length != rerankIndexes.length ||
            logits.any((logit) => !logit.isFinite)) {
          throw const FormatException(
            'The cross-encoder returned invalid candidate scores.',
          );
        }
        final rerankedScores = <int, double>{
          for (var index = 0; index < rerankIndexes.length; index++)
            rerankIndexes[index]: _crossEncoderBlendScore(
              logits[index],
              blended[rerankIndexes[index]]!,
              experimentConfig.crossEncoderWeight,
            ),
        };
        final rerankedPrefix =
            List<int>.generate(rerankIndexes.length, (index) => index)
              ..sort((left, right) {
                final leftScore = rerankedScores[rerankIndexes[left]]!;
                final rightScore = rerankedScores[rerankIndexes[right]]!;
                final byScore = rightScore.compareTo(leftScore);
                return byScore != 0 ? byScore : left.compareTo(right);
              });
        inferenceSucceeded = true;
        finalRankingScores = {...blended, ...rerankedScores};
        finalRankedIndexes = [
          for (final index in rerankedPrefix) rerankIndexes[index],
          ...rankedIndexes.skip(rerankCount),
        ];
        rerankStopwatch.stop();
        if (kDebugMode) {
          developer.log(
            'Cross-encoder inference=success fallback=false '
            'eligible=${eligible.length} reranked=${rerankIndexes.length} '
            'elapsedMs=${rerankStopwatch.elapsedMilliseconds}',
            name: 'catol.retrieval',
          );
        }
      } catch (error, stackTrace) {
        rerankStopwatch.stop();
        developer.log(
          'Cross-encoder inference=${inferenceSucceeded ? 'success' : 'failure'} '
          'fallback=true eligible=${eligible.length} '
          'reranked=${rerankIndexes.length} '
          'elapsedMs=${rerankStopwatch.elapsedMilliseconds} '
          'error=${error.runtimeType}; retaining hybrid order.',
          name: 'catol.retrieval',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    final queryTexts = [
      originalQuery,
      processedQuery,
      ...analysis.glossaryTerms,
    ];
    LawMatchResult toResult(int index) => _toResult(
      resources,
      index,
      bestCosine[index],
      rawCosineScore: useDenseRetrieval ? bestCosine[index] : null,
      analysis: analysis,
      queryTexts: queryTexts,
      rankingScore: finalRankingScores[index],
      matchedFact: _firstConcernStatement(originalQuery),
      matchedProvision: _bestMatchingPassage(resources, index, primaryVector!),
    );

    final responseIndexes = finalRankedIndexes.take(_resultLimit);
    final results = responseIndexes
        .take(_topResultCount)
        .map(toResult)
        .toList();
    return CatalystMatchResponse(
      results: List.unmodifiable(results),
      otherCandidates: List.unmodifiable(
        responseIndexes.skip(_topResultCount).map(toResult),
      ),
      originalQuery: originalQuery,
      processedQuery: processedQuery,
      analysis: analysis,
      warning: results.isEmpty
          ? 'No provision in the local corpus was similar enough to your '
                'description. Try adding more detail.'
          : retrievalWarning,
    );
  }

  static double _crossEncoderBlendScore(
    double logit,
    double hybridScore,
    double crossEncoderWeight,
  ) {
    final boundedLogit = logit.clamp(-80.0, 80.0).toDouble();
    final crossEncoderScore = 1 / (1 + math.exp(-boundedLogit));
    final roundedHybridScore = double.parse(hybridScore.toStringAsFixed(4));
    return crossEncoderWeight * crossEncoderScore +
        (1 - crossEncoderWeight) * roundedHybridScore;
  }

  static String _bestMatchingPassage(
    _LocalRetrievalResources resources,
    int articleIndex,
    List<double> queryEmbedding,
  ) {
    final words = resources.articles[articleIndex].articleText
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    var passageNumber = 0;
    var bestStart = 0;
    var bestSimilarity = double.negativeInfinity;
    for (var chunk = 0; chunk < resources.chunkOwners.length; chunk++) {
      if (resources.chunkOwners[chunk] != articleIndex) continue;
      var similarity = 0.0;
      final offset = chunk * _embeddingDimensions;
      for (var dimension = 0; dimension < _embeddingDimensions; dimension++) {
        similarity +=
            resources.chunkEmbeddings[offset + dimension] *
            queryEmbedding[dimension];
      }
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestStart = passageNumber * 40;
      }
      passageNumber++;
    }
    if (passageNumber == 0 || bestStart >= words.length) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The local provision passage index is invalid.',
      );
    }
    final passage = words.length <= 75
        ? words.join(' ')
        : words.skip(bestStart).take(60).join(' ');
    return firstStatement(passage, maxLength: 300);
  }

  static String _firstConcernStatement(String concern) {
    final flat = concern.replaceAll(RegExp(r'\s+'), ' ').trim();
    final sentenceEnd = RegExp(r'[.!?](?=\s|$)').firstMatch(flat)?.end;
    final statement = sentenceEnd == null
        ? flat
        : flat.substring(0, sentenceEnd);
    if (statement.length <= 200) return statement;
    final cut = statement.substring(0, 200);
    final lastSpace = cut.lastIndexOf(' ');
    return '${cut.substring(0, lastSpace > 120 ? lastSpace : 200)}...';
  }

  static ({List<int> rankedIndexes, Map<int, double> normalizedVotes})
  _rankTrainingExamples({
    required _LocalRetrievalResources resources,
    required List<double> queryEmbedding,
    required QueryDomain domain,
    required bool domainIndependent,
    required int candidatePoolSize,
  }) {
    if ((!domainIndependent && domain == QueryDomain.unknown) ||
        resources.trainingExamples.isEmpty) {
      return (rankedIndexes: const [], normalizedVotes: const {});
    }

    final matchingExamples = <({int index, double similarity})>[];
    final vectors = resources.trainingQueryEmbeddings;
    for (var index = 0; index < resources.trainingExamples.length; index++) {
      if (!domainIndependent &&
          resources.trainingExamples[index].domain != domain) {
        continue;
      }

      var similarity = 0.0;
      final start = index * _embeddingDimensions;
      for (var dimension = 0; dimension < _embeddingDimensions; dimension++) {
        similarity += vectors[start + dimension] * queryEmbedding[dimension];
      }
      if (similarity.isFinite) {
        matchingExamples.add((index: index, similarity: similarity));
      }
    }
    matchingExamples.sort((left, right) {
      final bySimilarity = right.similarity.compareTo(left.similarity);
      return bySimilarity != 0
          ? bySimilarity
          : left.index.compareTo(right.index);
    });

    if (matchingExamples.isEmpty ||
        matchingExamples.first.similarity < _minimumTrainingQueryCosine) {
      return (rankedIndexes: const [], normalizedVotes: const {});
    }

    final votes = <int, double>{};
    var neighborRank = 0;
    for (final match in matchingExamples) {
      if (neighborRank == _trainingNeighborCount) break;
      if (match.similarity < _minimumTrainingQueryCosine) break;
      final similarity = match.similarity.clamp(0.0, 1.0);
      final weight =
          math.pow(similarity, 3).toDouble() / math.sqrt(neighborRank + 1);
      neighborRank++;
      final example = resources.trainingExamples[match.index];
      for (final articleIndex in example.positiveArticleIndexes) {
        votes[articleIndex] = (votes[articleIndex] ?? 0) + weight;
      }
      for (final articleIndex in example.negativeArticleIndexes) {
        votes[articleIndex] = (votes[articleIndex] ?? 0) - weight;
      }
    }

    final positiveVotes = <int, double>{
      for (final entry in votes.entries)
        if (entry.value > 0) entry.key: entry.value,
    };
    if (positiveVotes.isEmpty) {
      return (rankedIndexes: const [], normalizedVotes: const {});
    }
    final maxVote = positiveVotes.values.reduce(math.max);
    final ranked = positiveVotes.keys.toList()
      ..sort((left, right) {
        final byVote = positiveVotes[right]!.compareTo(positiveVotes[left]!);
        return byVote != 0 ? byVote : left.compareTo(right);
      });
    final rankedIndexes = ranked
        .take(candidatePoolSize)
        .toList(growable: false);
    return (
      rankedIndexes: rankedIndexes,
      normalizedVotes: {
        for (final index in rankedIndexes)
          index: positiveVotes[index]! / maxVote,
      },
    );
  }

  /// Best chunk cosine per article; chunks are unit vectors like the query.
  static List<double> _articleCosines(
    _LocalRetrievalResources resources,
    List<double> vector, {
    bool averageTopTwo = false,
    List<double>? bestScores,
  }) {
    if (vector.length != _embeddingDimensions) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The on-device model returned an invalid query embedding.',
      );
    }
    final scores = List<double>.filled(resources.articles.length, -1);
    final second = averageTopTwo
        ? List<double>.filled(resources.articles.length, -1)
        : null;
    final owners = resources.chunkOwners;
    for (var chunk = 0; chunk < owners.length; chunk++) {
      var score = 0.0;
      final start = chunk * _embeddingDimensions;
      for (var d = 0; d < _embeddingDimensions; d++) {
        score += resources.chunkEmbeddings[start + d] * vector[d];
      }
      if (!score.isFinite || score.abs() > 1.001) {
        throw const CatalystRetrievalException(
          CatalystRetrievalFailure.invalidEmbedding,
          'The local model produced an invalid cosine similarity.',
        );
      }
      final owner = owners[chunk];
      if (score > scores[owner]) {
        if (second != null) second[owner] = scores[owner];
        scores[owner] = score;
      } else if (second != null && score > second[owner]) {
        second[owner] = score;
      }
    }
    if (bestScores != null) bestScores.setAll(0, scores);
    if (second != null) {
      for (var index = 0; index < scores.length; index++) {
        if (second[index] > -1) {
          scores[index] = (scores[index] + second[index]) / 2;
        }
      }
    }
    return scores;
  }

  static LawMatchResult _toResult(
    _LocalRetrievalResources resources,
    int index,
    double cosine, {
    double? rawCosineScore,
    QueryAnalysis? analysis,
    List<String> queryTexts = const [],
    double? rankingScore,
    String? matchedFact,
    String? matchedProvision,
  }) {
    final article = resources.articles[index];
    final id = normalizedArticleId(article.law, article.article);
    final similarity =
        rankingScore ??
        ((cosine - _displayFloorCosine) /
                (_displayCeilingCosine - _displayFloorCosine))
            .clamp(0.0, 1.0);
    return LawMatchResult(
      lawName: article.law,
      articleNumber: article.article,
      title: article.title,
      chapterTitle: article.chapterTitle,
      description: article.articleText,
      articleText: article.articleText,
      matchScore: double.parse(similarity.toStringAsFixed(4)) * 100,
      rawCosineScore: rawCosineScore,
      caseExplanationPoints: analysis == null
          ? const []
          : buildExplanationPoints(
              analysis: analysis,
              articleId: id,
              articleText: article.articleText,
              queryTexts: queryTexts,
              hasDuplicateId: resources.duplicateIds.contains(id),
            ),
      explanationVariants: analysis == null
          ? null
          : buildExplanationVariants(
              analysis: analysis,
              articleId: id,
              articleText: article.articleText,
              queryTexts: queryTexts,
              hasDuplicateId: resources.duplicateIds.contains(id),
              matchedFact: matchedFact,
              matchedProvision: matchedProvision,
            ),
      defaultExplanationLanguage: queryTexts.isEmpty
          ? null
          : detectQueryLanguage(queryTexts.first).code,
    );
  }

  static Future<_LocalRetrievalResources> _loadResources() async {
    final current = _resourcesFuture;
    if (current != null) {
      return current;
    }

    final pending = _readResources();
    _resourcesFuture = pending;
    try {
      return await pending;
    } catch (_) {
      if (identical(_resourcesFuture, pending)) {
        _resourcesFuture = null;
      }
      rethrow;
    }
  }

  static Future<_LocalRetrievalResources> _readResources() async {
    final tokenizer = await LocalTokenizer.load();
    final articlesJson = await rootBundle.loadString(_articlesAssetPath);
    final decodedArticles = jsonDecode(articlesJson);
    if (decodedArticles is! List) {
      throw const FormatException('The local legal corpus is not a list.');
    }

    final articles = decodedArticles
        .map(CatalystLegalArticle.fromJson)
        .toList(growable: false);
    if (articles.length < _topResultCount) {
      throw const FormatException(
        'The local legal corpus has fewer than three articles.',
      );
    }

    final ownersJson = jsonDecode(
      await rootBundle.loadString(_chunkOwnersAssetPath),
    );
    if (ownersJson is! List) {
      throw const FormatException('The chunk index is not a list.');
    }
    final chunkOwners = [
      for (final owner in ownersJson) (owner as num).toInt(),
    ];
    if (chunkOwners.any((owner) => owner < 0 || owner >= articles.length)) {
      throw const FormatException(
        'The chunk index references a missing article.',
      );
    }

    final embeddingData = await rootBundle.load(_chunkEmbeddingsAssetPath);
    final expectedBytes = chunkOwners.length * _embeddingDimensions * 4;
    if (embeddingData.lengthInBytes != expectedBytes) {
      throw FormatException(
        'The local embedding matrix has ${embeddingData.lengthInBytes} bytes; '
        '$expectedBytes bytes were expected.',
      );
    }

    final alignedBytes = Uint8List.fromList(
      embeddingData.buffer.asUint8List(
        embeddingData.offsetInBytes,
        embeddingData.lengthInBytes,
      ),
    );
    final embeddings = Float32List.view(alignedBytes.buffer);
    _validateCorpusEmbeddings(embeddings, chunkOwners.length);
    final articleIds = [
      for (final article in articles)
        normalizedArticleId(article.law, article.article),
    ];
    final seen = <String>{};
    final duplicates = <String>{
      for (final id in articleIds)
        if (!seen.add(id)) id,
    };
    final trainingLabels = jsonDecode(
      await rootBundle.loadString(_trainingQueryLabelsAssetPath),
    );
    if (trainingLabels is! Map<String, dynamic> ||
        trainingLabels['formatVersion'] != 1 ||
        trainingLabels['articleCount'] != articles.length) {
      throw const FormatException(
        'The training query index does not match the local article corpus.',
      );
    }
    final examplesValue = trainingLabels['examples'];
    if (examplesValue is! List) {
      throw const FormatException('The training query labels are not a list.');
    }
    final trainingExamples = <_TrainingQueryExample>[];
    for (final value in examplesValue) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('A training query label is not an object.');
      }
      final domain = switch (value['domain']) {
        'civil' => QueryDomain.civil,
        'consumer' => QueryDomain.consumer,
        'family' => QueryDomain.family,
        _ => throw const FormatException(
          'A training query has an unsupported domain.',
        ),
      };
      final positiveIndexes = _readArticleIndexes(
        value['positiveArticleIndexes'],
        articles.length,
      );
      final negativeIndexes = _readArticleIndexes(
        value['negativeArticleIndexes'],
        articles.length,
      );
      if (positiveIndexes
          .toSet()
          .intersection(negativeIndexes.toSet())
          .isNotEmpty) {
        throw const FormatException(
          'A training query labels an article both relevant and non-relevant.',
        );
      }
      trainingExamples.add(
        _TrainingQueryExample(
          domain: domain,
          positiveArticleIndexes: positiveIndexes,
          negativeArticleIndexes: negativeIndexes,
        ),
      );
    }
    if (trainingLabels['embeddingCount'] != trainingExamples.length) {
      throw const FormatException(
        'The training query label and embedding counts do not match.',
      );
    }

    final trainingEmbeddingData = await rootBundle.load(
      _trainingQueryEmbeddingsAssetPath,
    );
    final expectedTrainingBytes =
        trainingExamples.length * _embeddingDimensions * 4;
    if (trainingEmbeddingData.lengthInBytes != expectedTrainingBytes) {
      throw FormatException(
        'The training query embedding matrix has '
        '${trainingEmbeddingData.lengthInBytes} bytes; '
        '$expectedTrainingBytes bytes were expected.',
      );
    }
    final alignedTrainingBytes = Uint8List.fromList(
      trainingEmbeddingData.buffer.asUint8List(
        trainingEmbeddingData.offsetInBytes,
        trainingEmbeddingData.lengthInBytes,
      ),
    );
    final trainingQueryEmbeddings = Float32List.view(
      alignedTrainingBytes.buffer,
    );
    _validateCorpusEmbeddings(trainingQueryEmbeddings, trainingExamples.length);

    return _LocalRetrievalResources(
      tokenizer: tokenizer,
      articles: articles,
      chunkEmbeddings: embeddings,
      chunkOwners: chunkOwners,
      trainingQueryEmbeddings: trainingQueryEmbeddings,
      trainingExamples: trainingExamples,
      lexicalIndex: Bm25Index.build([
        for (final article in articles) article.articleText,
      ]),
      duplicateIds: duplicates,
    );
  }

  static List<int> _readArticleIndexes(Object? value, int articleCount) {
    if (value is! List) {
      throw const FormatException(
        'A training query article list is not a list.',
      );
    }
    final indexes = <int>[];
    for (final index in value) {
      if (index is! int || index < 0 || index >= articleCount) {
        throw const FormatException(
          'A training query references an invalid article index.',
        );
      }
      indexes.add(index);
    }
    return indexes;
  }

  static void _validateCorpusEmbeddings(Float32List embeddings, int rowCount) {
    for (var row = 0; row < rowCount; row++) {
      var squaredNorm = 0.0;
      final rowStart = row * _embeddingDimensions;
      for (var dimension = 0; dimension < _embeddingDimensions; dimension++) {
        final value = embeddings[rowStart + dimension];
        if (!value.isFinite) {
          throw FormatException(
            'The local embedding at row ${row + 1} contains an invalid value.',
          );
        }
        squaredNorm += value * value;
      }
      if ((math.sqrt(squaredNorm) - 1).abs() > 1e-3) {
        throw FormatException(
          'The local embedding at row ${row + 1} is not unit-normalized.',
        );
      }
    }
  }

  static Future<OrtSession> _loadSession() async {
    final current = _sessionFuture;
    if (current != null) {
      return current;
    }

    final pending = OnnxRuntime().createSessionFromAsset(
      _encoderAssetPath,
      options: OrtSessionOptions(
        intraOpNumThreads: 2,
        interOpNumThreads: 1,
        providers: const [OrtProvider.CPU],
      ),
    );
    _sessionFuture = pending;
    try {
      return await pending;
    } catch (error, stackTrace) {
      if (identical(_sessionFuture, pending)) {
        _sessionFuture = null;
      }
      developer.log(
        'The local ONNX model could not be initialized (${error.runtimeType})',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.modelInitialization,
        'The on-device language model could not be initialized. '
        'Please restart the app and try again.',
      );
    }
  }

  static Future<List<double>> _encodeWithOnnx(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    if (inputIds.isEmpty || inputIds.length != attentionMask.length) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The tokenizer returned invalid input for the on-device model.',
      );
    }

    final session = await _loadSession();
    final inputIdsTensor = await OrtValue.fromList(
      Int64List.fromList(inputIds),
      [1, inputIds.length],
    );
    try {
      final attentionMaskTensor = await OrtValue.fromList(
        Int64List.fromList(attentionMask),
        [1, attentionMask.length],
      );
      Map<String, OrtValue>? outputs;
      try {
        outputs = await session.run({
          'input_ids': inputIdsTensor,
          'attention_mask': attentionMaskTensor,
        });
        final embedding = outputs['sentence_embedding'];
        if (embedding == null ||
            embedding.shape.length != 2 ||
            embedding.shape[0] != 1 ||
            embedding.shape[1] != _embeddingDimensions) {
          throw const CatalystRetrievalException(
            CatalystRetrievalFailure.invalidEmbedding,
            'The on-device model returned an unexpected embedding shape.',
          );
        }

        final values = await embedding.asFlattenedList();
        final vector = values
            .map((value) => (value as num).toDouble())
            .toList();
        _validateQueryEmbedding(vector);
        return vector;
      } finally {
        if (outputs != null) {
          for (final output in outputs.values) {
            await output.dispose();
          }
        }
        await attentionMaskTensor.dispose();
      }
    } finally {
      await inputIdsTensor.dispose();
    }
  }
}

List<LawMatchResult> rankCorpusArticles({
  required List<CatalystLegalArticle> articles,
  required Float32List embeddings,
  required List<double> queryEmbedding,
}) {
  if (queryEmbedding.length != _embeddingDimensions ||
      embeddings.length != articles.length * _embeddingDimensions) {
    throw const CatalystRetrievalException(
      CatalystRetrievalFailure.invalidEmbedding,
      'The query or corpus embedding dimensions are invalid.',
    );
  }
  _validateQueryEmbedding(queryEmbedding);

  final scores = <({int index, double score})>[];
  for (var row = 0; row < articles.length; row++) {
    var score = 0.0;
    final rowStart = row * _embeddingDimensions;
    for (var dimension = 0; dimension < _embeddingDimensions; dimension++) {
      score += embeddings[rowStart + dimension] * queryEmbedding[dimension];
    }
    if (!score.isFinite || score.abs() > 1.001) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The local model produced an invalid cosine similarity.',
      );
    }
    scores.add((index: row, score: score));
  }

  scores.sort((left, right) {
    final scoreOrder = right.score.compareTo(left.score);
    return scoreOrder != 0 ? scoreOrder : left.index.compareTo(right.index);
  });

  return scores
      .take(_topResultCount)
      .map((match) {
        final article = articles[match.index];
        final similarity = match.score.clamp(0.0, 1.0);
        final roundedSimilarity = double.parse(similarity.toStringAsFixed(4));
        return LawMatchResult(
          lawName: article.law,
          articleNumber: article.article,
          title: article.title,
          chapterTitle: article.chapterTitle,
          description: article.articleText,
          articleText: article.articleText,
          matchScore: roundedSimilarity * 100,
          rawCosineScore: match.score,
        );
      })
      .toList(growable: false);
}

void _validateQueryEmbedding(List<double> queryEmbedding) {
  if (queryEmbedding.length != _embeddingDimensions ||
      queryEmbedding.any((value) => !value.isFinite)) {
    throw const CatalystRetrievalException(
      CatalystRetrievalFailure.invalidEmbedding,
      'The on-device model returned an invalid query embedding.',
    );
  }

  final norm = math.sqrt(
    queryEmbedding.fold<double>(0, (sum, value) => sum + value * value),
  );
  if ((norm - 1).abs() > 1e-3) {
    throw const CatalystRetrievalException(
      CatalystRetrievalFailure.invalidEmbedding,
      'The on-device model returned an unnormalized query embedding.',
    );
  }
}

class _TrainingQueryExample {
  const _TrainingQueryExample({
    required this.domain,
    required this.positiveArticleIndexes,
    required this.negativeArticleIndexes,
  });

  final QueryDomain domain;
  final List<int> positiveArticleIndexes;
  final List<int> negativeArticleIndexes;
}

double _normalizedReciprocalRank(int rank, int k) => (k + 1) / (k + rank + 1);

class _LocalRetrievalResources {
  const _LocalRetrievalResources({
    required this.tokenizer,
    required this.articles,
    required this.chunkEmbeddings,
    required this.chunkOwners,
    required this.trainingQueryEmbeddings,
    required this.trainingExamples,
    required this.lexicalIndex,
    required this.duplicateIds,
  });

  final LocalTokenizer tokenizer;
  final List<CatalystLegalArticle> articles;
  final Float32List chunkEmbeddings;
  final List<int> chunkOwners;
  final Float32List trainingQueryEmbeddings;
  final List<_TrainingQueryExample> trainingExamples;
  final Bm25Index lexicalIndex;
  final Set<String> duplicateIds;
}
