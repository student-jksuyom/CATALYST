import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../models/law_match_result.dart';
import 'explanation_builder.dart';
import 'explanation_language.dart';
import 'legal_query_preprocessor.dart';
import 'lexical_index.dart';
import 'bilingual_legal_lexicon.dart';
import 'legal_issue_lexicon.dart';
import 'article_issue_profiles.dart';
import 'corpus_wide_concepts.dart';
import 'tagalog_morphology.dart';
import 'local_tokenizer.dart';
import 'query_analysis.dart';

const String retrievalWarning =
    'Similarity is a retrieval signal, not a probability or legal conclusion.';

const int _embeddingDimensions = 384;
const int _topResultCount = 3;
const int _allResultCount = 15;
const int _candidatePoolSize = 100;

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

/// Conservative two-ranking fusion, limited to one near-miss Top-3 rescue.
///
/// V5 supplies the primary ranking. The installed/base ranking may restore
/// its Top-1 candidate at rank 3 only when (a) the candidate is already V5
/// eligible, (b) it also ranks first in text BM25, and (c) its unbonused
/// retrieval score is no more than 0.05 below V5's third ranked score.
/// This rule uses no reference labels, statute IDs, or narrative lookup table.
///
/// Caller computes both rankings from the SAME query, original corpus,
/// E5 vectors, BM25, and training votes. No additional ONNX run is needed.
({List<int> ranking, bool rescued}) conservativeV51RankFusion({
  required List<int> v5Ranking,
  required int? baselineTopIndex,
  required double baselineTopScore,
  required double baselineTopBm25Ratio,
  required double v5ThirdScore,
  required bool v5CandidateEligible,
  double maximumGap = 0.05,
}) {
  if (v5Ranking.length < 3 || baselineTopIndex == null ||
      !v5CandidateEligible || baselineTopBm25Ratio < 0.99 ||
      !baselineTopScore.isFinite || !v5ThirdScore.isFinite ||
      !maximumGap.isFinite || maximumGap < 0 ||
      v5Ranking.take(3).contains(baselineTopIndex) ||
      v5ThirdScore - baselineTopScore > maximumGap) {
    return (ranking: v5Ranking, rescued: false);
  }
  final updated = <int>[
    ...v5Ranking.take(2),
    baselineTopIndex,
    for (final index in v5Ranking.skip(2))
      if (index != baselineTopIndex) index,
  ];
  return (
    ranking: updated.take(v5Ranking.length).toList(growable: false),
    rescued: true,
  );
}

class LocalSemanticRetrievalService implements CatalystRetrievalService {
  const LocalSemanticRetrievalService({
    LocalQueryEncoder? queryEncoder,
    LegalQueryPreprocessor queryPreprocessor = defaultLegalQueryPreprocessor,
    CatalystRetrievalStrategy strategy = CatalystRetrievalStrategy.hybrid,
    double minimumCosine = _defaultMinimumCosine,
    int resultLimit = _allResultCount,
    this.diagnosticArticleIds = const <String>{},
    this.onDiagnostics,
    bool enableBilingualLegalLexicalExpansion = false,
    bool enableLegalIssueLexicalExpansion = false,
    bool enableArticleIssueProfiles = false,
    bool enableIssueAwareLexicalWeight = false,
    bool enableCorroboratedGate = false,
    bool enableTopBm25BorderlineGate = false,
    bool enableCorpusWideConceptIndex = false,
    bool enableCorpusConceptGate = false,
    bool disableTrainingExampleVotes = false,
    // Optional bounded statute-concept ranking evidence, disabled by default.
    double corpusConceptRerankWeight = 0.0,
    // V4: Prefer distinctive statute/query concept overlap over broad counts.
    // Disabled by default; installed app ranking is unchanged.
    bool useDiscriminativeConceptEvidence = false,
    // V5 experiment: shared operative-clause evidence, not broad article tags.
    bool useClauseLocalEvidence = false,
    // V5 optional morphology alignment; original tokens and E5 unchanged.
    bool useTagalogWordForms = false,
    // V5.1 experiment: preserve a strongly supported installed top-one item
    // when V5 clause reranking narrowly pushes it outside the Top 3.
    // Disabled by default; V5 and installed configurations remain unchanged.
    bool enableV51ConservativeFusion = false,
  }) : assert(corpusConceptRerankWeight >= 0.0 &&
                corpusConceptRerankWeight <= 0.30,
                'Corpus concept bonus must be between 0.0 and 0.30'),
       _corpusConceptRerankWeight = corpusConceptRerankWeight,
       _useDiscriminativeConceptEvidence = useDiscriminativeConceptEvidence,
       _useClauseLocalEvidence = useClauseLocalEvidence,
       _useTagalogWordForms = useTagalogWordForms,
       _enableV51ConservativeFusion = enableV51ConservativeFusion,
       _enableCorpusWideConceptIndex = enableCorpusWideConceptIndex,
       _enableCorpusConceptGate = enableCorpusConceptGate,
       _disableTrainingExampleVotes = disableTrainingExampleVotes,
       _enableBilingualLegalLexicalExpansion = enableBilingualLegalLexicalExpansion,
       _enableLegalIssueLexicalExpansion = enableLegalIssueLexicalExpansion,
       _enableArticleIssueProfiles = enableArticleIssueProfiles,
       _enableIssueAwareLexicalWeight = enableIssueAwareLexicalWeight,
       _enableCorroboratedGate = enableCorroboratedGate,
       _enableTopBm25BorderlineGate = enableTopBm25BorderlineGate,
       _queryEncoder = queryEncoder,
       _queryPreprocessor = queryPreprocessor,
       _strategy = strategy,
       _minimumCosine = minimumCosine,
       _resultLimit = resultLimit;

  /// Optional evaluation observer; no work or logging when absent.
  final Set<String> diagnosticArticleIds;
  final void Function(Map<String, dynamic>)? onDiagnostics;

  static Future<_LocalRetrievalResources>? _resourcesFuture;
  static Future<OrtSession>? _sessionFuture;
  static Bm25Index? _articleProfileLexicalIndex;
  static CorpusWideConceptIndex? _corpusConceptIndex;

  final LocalQueryEncoder? _queryEncoder;
  final LegalQueryPreprocessor _queryPreprocessor;
  final CatalystRetrievalStrategy _strategy;
  final double _minimumCosine;
  final int _resultLimit;
  final bool _enableBilingualLegalLexicalExpansion;
  final bool _enableLegalIssueLexicalExpansion;
  final bool _enableArticleIssueProfiles;
  final bool _enableIssueAwareLexicalWeight;
  final bool _enableCorroboratedGate;
  final bool _enableTopBm25BorderlineGate;
  final bool _enableCorpusWideConceptIndex;
  final bool _enableCorpusConceptGate;
  final bool _disableTrainingExampleVotes;
  final double _corpusConceptRerankWeight;
  final bool _useDiscriminativeConceptEvidence;
  final bool _useClauseLocalEvidence;
  final bool _useTagalogWordForms;
  final bool _enableV51ConservativeFusion;

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
      onDiagnostics?.call({'stop': 'clarification', 'domain': analysis.domain.name});
      return CatalystMatchResponse(
        results: const [],
        originalQuery: normalizedConcern,
        processedQuery: normalizedConcern,
        clarifyingQuestion: analysis.clarifyingQuestion,
        analysis: analysis,
      );
    }
    if (analysis != null && isClearlyOutsideCatalystScope(normalizedConcern)) {
      onDiagnostics?.call({'stop': 'scope_filter', 'domain': analysis.domain.name});
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

    final articles = resources.articles;
    final bestCosine = List<double>.filled(articles.length, -1);
    final cosineSum = List<double>.filled(articles.length, 0);
    final denseLists = <List<int>>[];
    final diagnosticDense = <Map<String, dynamic>>[];
    String articleId(int index) => normalizedArticleId(
      articles[index].law, articles[index].article,
    );
    int? targetRank(Iterable<int> indexes, String id) {
      final seen = <String>{};
      for (final index in indexes) {
        final current = articleId(index);
        if (!seen.add(current)) continue;
        if (current == id) return seen.length;
      }
      return null;
    }
    List<double>? primaryVector;
    for (final variant in variants) {
      final vector = await _encodeQuery(resources, variant);
      _validateQueryEmbedding(vector);
      primaryVector ??= vector;
      final scores = _articleCosines(resources, vector);
      for (var row = 0; row < scores.length; row++) {
        if (scores[row] > bestCosine[row]) bestCosine[row] = scores[row];
        cosineSum[row] += scores[row];
      }
      final order = List<int>.generate(articles.length, (i) => i)
        ..sort((a, b) {
          final byScore = scores[b].compareTo(scores[a]);
          return byScore != 0 ? byScore : a.compareTo(b);
        });
      denseLists.add(order.take(_candidatePoolSize).toList(growable: false));
      if (onDiagnostics != null) {
        diagnosticDense.add({
          'query': variant,
          'targets': {
            for (final id in diagnosticArticleIds)
              id: {
                'rank': targetRank(order, id),
                'bestCosine': order.where((i) => articleId(i) == id).isEmpty
                    ? null : scores[order.firstWhere((i) => articleId(i) == id)],
                'inTop50': denseLists.last.any((i) => articleId(i) == id),
              },
          },
        });
      }
    }

    final trainingMatches = _disableTrainingExampleVotes
        ? (rankedIndexes: <int>[], normalizedVotes: <int, double>{})
        : _rankTrainingExamples(
            resources: resources,
            queryEmbedding: primaryVector!,
            domain: analysis.domain,
          );
    final lexicalQuery = [
      originalQuery,
      processedQuery,
      ...analysis.glossaryTerms,
      ...expandLegalWording(originalQuery),
      if (_enableBilingualLegalLexicalExpansion)
        ...expandBilingualLegalTerms(originalQuery),
      if (_enableLegalIssueLexicalExpansion)
        ...expandLegalIssueTerms(originalQuery),
      if (_useTagalogWordForms)
        ...normalizeTagalogForms(originalQuery),
    ].join(' ');
    final legalIssueTerms = _enableLegalIssueLexicalExpansion
        ? expandLegalIssueTerms(originalQuery)
        : const <String>[];
    final lexicalIndex = _enableArticleIssueProfiles
        ? (_articleProfileLexicalIndex ??= Bm25Index.build([
            for (final article in articles)
              [
                article.title, article.chapterTitle, article.articleText,
                legalArticleIssueProfile(article.law, article.article),
              ].where((part) => part.trim().isNotEmpty).join(' '),
          ]))
        : resources.lexicalIndex;
    final lexical = lexicalIndex.search(
      lexicalQuery,
      limit: _candidatePoolSize,
    );
    // Corpus-wide, statute-derived issue indexing. All articles are processed;
    // no hand-picked article IDs or query-to-answer mappings are used.
    final corpusConcepts = _enableCorpusWideConceptIndex
        ? (_corpusConceptIndex ??= CorpusWideConceptIndex.build([
            for (final article in articles)
              '${article.title} ${article.chapterTitle} ${article.articleText}',
          ]))
        : null;
    final conceptTags = corpusConcepts?.queryTags(
          originalQuery, tagalogWordForms: _useTagalogWordForms,
        ) ?? <String>{};
    final conceptLexical = corpusConcepts?.searchTags(
          conceptTags,
          limit: _candidatePoolSize,
        ) ?? <({int index, double score})>[];
    // Separate installed/base candidate ordering for the V5.1 consensus guard.
    // The V5 candidate list still comes from all four signals below.
    final baselineFused = _enableV51ConservativeFusion
        ? fuseRankings([
            ...denseLists,
            if (lexical.isNotEmpty)
              lexical.map((hit) => hit.index).toList(),
            if (trainingMatches.rankedIndexes.isNotEmpty)
              trainingMatches.rankedIndexes,
          ], k: _fusionK)
        : const <({int index, double score})>[];
    final fused = fuseRankings([
      ...denseLists,
      if (lexical.isNotEmpty) lexical.map((hit) => hit.index).toList(),
      if (conceptLexical.isNotEmpty)
        conceptLexical.map((hit) => hit.index).toList(),
      if (trainingMatches.rankedIndexes.isNotEmpty)
        trainingMatches.rankedIndexes,
    ], k: _fusionK);

    // Keep the supervised example signal modest so it can improve ranking
    // without replacing the corpus-grounded dense and lexical matches.
    final maxLexical = lexical.isEmpty ? 0.0 : lexical.first.score;
    final lexicalScore = {for (final hit in lexical) hit.index: hit.score};
    final maxConceptScore = conceptLexical.isEmpty ? 0.0 : conceptLexical.first.score;
    final conceptScore = {
      for (final hit in conceptLexical) hit.index: hit.score,
    };
    // V3 experimental reranking: use statute-derived concept evidence only
    // when TWO distinct concepts match and E5 independently corroborates.
    // The raw concept BM25 score is normalized to this query's top hit, then
    // bounded by semantic strength and concept diversity. No training labels
    // or known narrative/article pairs enter this scoring rule.
    // With a weight of zero, the v2 installed scorer is bit-for-bit unchanged.
    double conceptEvidenceBonus(int index) {
      if (_corpusConceptRerankWeight <= 0.0 || corpusConcepts == null ||
          conceptTags.length < 2 || maxConceptScore <= 0.0) return 0.0;
      final shared = corpusConcepts.sharedConceptCount(index, conceptTags);
      if (shared < 2 || bestCosine[index] < 0.78) return 0.0;
      final rawConceptScore = conceptScore[index] ?? 0.0;
      if (rawConceptScore <= 0.0) return 0.0;
      final conceptStrength =
          (rawConceptScore / maxConceptScore).clamp(0.0, 1.0).toDouble();
      final semanticStrength =
          ((bestCosine[index] - 0.75) / 0.10).clamp(0.0, 1.0).toDouble();
      // V3 is retained as an experimental control. V4 rewards the
      // IDF-weighted overlap of the query with a specific statute article,
      // and discounts broad concepts shared by many different articles.
      final specificity = _useClauseLocalEvidence
          ? corpusConcepts.clauseLocalEvidence(index, conceptTags)
          : _useDiscriminativeConceptEvidence
              ? corpusConcepts.discriminativeConceptEvidence(index, conceptTags)
              : (shared / 3.0).clamp(0.0, 1.0).toDouble();
      if (specificity <= 0.0) return 0.0;
      return _corpusConceptRerankWeight * conceptStrength *
          semanticStrength * specificity;
    }

    // Preserve the installed app's BM25-vs-dense scoring calibration.
    final effectiveLexicalWeight =
        _enableIssueAwareLexicalWeight && legalIssueTerms.isNotEmpty
            ? 0.45
            : _lexicalWeight;
    double blendedScore(int index) {
      final meanCosine = bestCosine[index];
      final dense =
          ((meanCosine - _displayFloorCosine) /
                  (_displayCeilingCosine - _displayFloorCosine))
              .clamp(0.0, 1.0);
      final lexicalPart = maxLexical > 0
          ? (lexicalScore[index] ?? 0) / maxLexical
          : 0.0;
      // V2: Candidate-only concept channel. Do not let abstract concept tags
      // displace the text-derived BM25 evidence used by the installed app.
      final lexicalEvidence = lexicalPart;
      final corpusScore =
          (1 - effectiveLexicalWeight) * dense +
          effectiveLexicalWeight * lexicalEvidence;
      final trainingPart = trainingMatches.normalizedVotes[index] ?? 0.0;
      return (1 - _trainingSignalWeight) * corpusScore +
          _trainingSignalWeight * trainingPart + conceptEvidenceBonus(index);
    }

    final corroboratedIndexes = <int>{
      if (_enableCorroboratedGate && legalIssueTerms.isNotEmpty && maxLexical > 0)
        for (final hit in lexical.take(5))
          if (hit.score >= maxLexical * 0.60) hit.index,
    };
    // Optional experimental exception: only the best BM25 result may pass
    // a 0.75 cosine floor. Kept off by default, never changes the protected run.
    final topBm25Index = lexical.isNotEmpty ? lexical.first.index : -1;
    final conceptCorroboratedIndexes = <int>{
      if (_enableCorpusConceptGate && corpusConcepts != null &&
          conceptTags.length >= 2 && maxConceptScore > 0)
        for (final hit in conceptLexical.take(8))
          if (hit.score >= maxConceptScore * 0.60 &&
              corpusConcepts.sharedConceptCount(hit.index, conceptTags) >= 2)
            hit.index,
    };
    final blended = <int, double>{};
    final eligible = <int>[
      for (final candidate in fused)
        if (bestCosine[candidate.index] >= _minimumCosine ||
            (_enableCorroboratedGate &&
                bestCosine[candidate.index] >= 0.78 &&
                corroboratedIndexes.contains(candidate.index)) ||
            (_enableTopBm25BorderlineGate &&
                candidate.index == topBm25Index &&
                bestCosine[candidate.index] >= 0.75) ||
            (conceptCorroboratedIndexes.contains(candidate.index) &&
                bestCosine[candidate.index] >= 0.76))
          candidate.index,
    ];
    for (final index in eligible) {
      blended[index] = blendedScore(index);
    }
    // Reconstruct installed/base Top-1 from identical nonconcept channels.
    // The installed scorer is the V5 scorer with clause bonus removed.
    int? baselineTopIndex;
    double baselineTopScore = 0.0;
    if (_enableV51ConservativeFusion && baselineFused.isNotEmpty) {
      final baselineEligible = <int>[
        for (final candidate in baselineFused)
          if (bestCosine[candidate.index] >= _minimumCosine ||
              (_enableCorroboratedGate &&
                  bestCosine[candidate.index] >= 0.78 &&
                  corroboratedIndexes.contains(candidate.index)) ||
              (_enableTopBm25BorderlineGate &&
                  candidate.index == topBm25Index &&
                  bestCosine[candidate.index] >= 0.75))
            candidate.index,
      ];
      final baseOrder = baselineEligible.indexed.toList()
        ..sort((a, b) {
          final aScore = blendedScore(a.$2) - conceptEvidenceBonus(a.$2);
          final bScore = blendedScore(b.$2) - conceptEvidenceBonus(b.$2);
          final byScore = bScore.compareTo(aScore);
          return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
        });
      if (baseOrder.isNotEmpty) {
        final baseFirst = baseOrder.first.$2;
        baselineTopIndex = baseFirst;
        baselineTopScore = blendedScore(baseFirst) -
            conceptEvidenceBonus(baseFirst);
      }
    }
    // Stable sort: equal scores keep the fused (rank-based) order.
    final ordered = eligible.indexed.toList()
      ..sort((a, b) {
        final byScore = blended[b.$2]!.compareTo(blended[a.$2]!);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    final seenIds = <String>{};
    final rankedIndexes = <int>[];
    for (final entry in ordered) {
      final article = articles[entry.$2];
      final id = normalizedArticleId(article.law, article.article);
      if (!seenIds.add(id)) continue;
      rankedIndexes.add(entry.$2);
      if (rankedIndexes.length == _resultLimit) break;
    }

    // V5.1 guard: use the two live rankings, not the archived ranking lists.
    // At most one V5 Top-3 slot changes. This does not alter candidate gating,
    // embeddings, clause evidence, training votes, or the legal corpus.
    bool v51Rescued = false;
    if (_enableV51ConservativeFusion && rankedIndexes.length >= 3) {
      final candidate = baselineTopIndex;
      final bm25Ratio = candidate == null || maxLexical <= 0
          ? 0.0 : (lexicalScore[candidate] ?? 0.0) / maxLexical;
      final fusedOutcome = conservativeV51RankFusion(
        v5Ranking: rankedIndexes,
        baselineTopIndex: candidate,
        baselineTopScore: baselineTopScore,
        baselineTopBm25Ratio: bm25Ratio,
        v5ThirdScore: blended[rankedIndexes[2]]!,
        v5CandidateEligible: candidate != null &&
            eligible.contains(candidate) &&
            !rankedIndexes.take(3).any((index) =>
                articleId(index) == articleId(candidate)),
      );
      v51Rescued = fusedOutcome.rescued;
      if (v51Rescued) {
        rankedIndexes
          ..clear()
          ..addAll(fusedOutcome.ranking);
        // A V5 eligible candidate has a valid blended score already.
      }
    }

    if (onDiagnostics != null) {
      // Full BM25 ranks are diagnostic only; production still uses top 50.
      final allLexical = lexicalIndex.search(
        lexicalQuery, limit: articles.length,
      );
      final fullOrder = ordered.map((entry) => entry.$2).toList();
      final fusedIndexes = fused.map((entry) => entry.index).toList();
      onDiagnostics!({
        'stop': null,
        'domain': analysis.domain.name,
        'minimumCosine': _minimumCosine,
        'candidatePoolPerSignal': _candidatePoolSize,
        'crossEncoderEnabled': false,
        'corpusConceptIndexEnabled': _enableCorpusWideConceptIndex,
        'corpusConceptGateEnabled': _enableCorpusConceptGate,
        'corpusConceptRerankWeight': _corpusConceptRerankWeight,
        'useDiscriminativeConceptEvidence': _useDiscriminativeConceptEvidence,
        'useClauseLocalEvidence': _useClauseLocalEvidence,
        'v51ConservativeFusion': _enableV51ConservativeFusion,
        'v51RescuedBaselineTop1': v51Rescued,
        'v51BaselineTop1Id': baselineTopIndex == null
            ? null : articleId(baselineTopIndex),
        'useTagalogWordForms': _useTagalogWordForms,
        'tagalogMorphologyTerms': _useTagalogWordForms
            ? normalizeTagalogForms(originalQuery) : const <String>[],
        'conceptQueryTags': conceptTags.toList(),
        'corpusArticlesIndexed': corpusConcepts?.indexedArticles,
        'corpusArticlesWithConcepts': corpusConcepts?.conceptTaggedArticles,
        'denseVariants': diagnosticDense,
        'lexicalQuery': lexicalQuery,
        'fusedIds': fusedIndexes.map(articleId).toSet().toList(),
        'eligibleIds': eligible.map(articleId).toSet().toList(),
        'returnedIds': rankedIndexes.map(articleId).toList(),
        'top15Evidence': [
          for (final index in rankedIndexes) {
            'id': articleId(index),
            'bestCosine': bestCosine[index],
            'trainingVote': trainingMatches.normalizedVotes[index] ?? 0.0,
            'normalizedBm25': maxLexical > 0
                ? (lexicalScore[index] ?? 0.0) / maxLexical : 0.0,
            'matchedConceptCount': corpusConcepts?.sharedConceptCount(index, conceptTags),
            'normalizedConceptBm25': maxConceptScore > 0
                ? (conceptScore[index] ?? 0.0) / maxConceptScore : 0.0,
            'conceptBonus': conceptEvidenceBonus(index),
            'discriminativeConceptEvidence': corpusConcepts?.discriminativeConceptEvidence(index, conceptTags),
            'clauseLocalEvidence': corpusConcepts?.clauseLocalEvidence(index, conceptTags),
            'finalScore': blended[index],
          },
        ],
        'targets': {
          for (final id in diagnosticArticleIds)
            id: {
              'inCorpus': articles.asMap().keys.any((i) => articleId(i) == id),
              'bm25Rank': targetRank(allLexical.map((hit) => hit.index), id),
              'conceptRank': targetRank(conceptLexical.map((hit) => hit.index), id),
              'bm25InTop50': lexical.any((hit) => articleId(hit.index) == id),
              'trainingRank': targetRank(trainingMatches.rankedIndexes, id),
              'fusedRank': targetRank(fusedIndexes, id),
              'passedGate': eligible.any((i) => articleId(i) == id),
              'hybridRank': targetRank(fullOrder, id),
              'returnedRank': targetRank(rankedIndexes, id),
              'corpusRows': [
                for (var i = 0; i < articles.length; i++)
                  if (articleId(i) == id) {
                    'index': i,
                    'bestCosine': bestCosine[i],
                    'meanCosine': cosineSum[i] / variants.length,
                    'trainingVote': trainingMatches.normalizedVotes[i] ?? 0.0,
                    'blendScore': blended[i],
                    'conceptBm25Score': conceptScore[i],
                    'conceptBonus': conceptEvidenceBonus(i),
                    'sharedConcepts': corpusConcepts?.sharedConceptCount(i, conceptTags),
                  },
              ],
            },
        },
      });
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
      analysis: analysis,
      queryTexts: queryTexts,
      blendedSimilarity: blended[index],
      matchedFact: _firstConcernStatement(originalQuery),
      matchedProvision: _bestMatchingPassage(resources, index, primaryVector!),
    );

    final results = rankedIndexes.take(_topResultCount).map(toResult).toList();
    return CatalystMatchResponse(
      results: List.unmodifiable(results),
      otherCandidates: List.unmodifiable(
        rankedIndexes.skip(_topResultCount).map(toResult),
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
  }) {
    if (resources.trainingExamples.isEmpty) {
      return (rankedIndexes: const [], normalizedVotes: const {});
    }

    final matchingExamples = <({int index, double similarity})>[];
    final vectors = resources.trainingQueryEmbeddings;
    for (var index = 0; index < resources.trainingExamples.length; index++) {

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
        .take(_candidatePoolSize)
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
    List<double> vector,
  ) {
    if (vector.length != _embeddingDimensions) {
      throw const CatalystRetrievalException(
        CatalystRetrievalFailure.invalidEmbedding,
        'The on-device model returned an invalid query embedding.',
      );
    }
    final scores = List<double>.filled(resources.articles.length, -1);
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
      if (score > scores[owners[chunk]]) scores[owners[chunk]] = score;
    }
    return scores;
  }

  static LawMatchResult _toResult(
    _LocalRetrievalResources resources,
    int index,
    double cosine, {
    QueryAnalysis? analysis,
    List<String> queryTexts = const [],
    double? blendedSimilarity,
    String? matchedFact,
    String? matchedProvision,
  }) {
    final article = resources.articles[index];
    final id = normalizedArticleId(article.law, article.article);
    // The concept evidence bonus may make the internal blended ranking score
    // exceed 1.0. Keep that score unchanged for ranking and diagnostics, but
    // bound ONLY the user-facing match percentage to LawMatchResult's 0-100
    // contract. This display value is not a calibrated probability.
    final similarity = (blendedSimilarity ??
            ((cosine - _displayFloorCosine) /
                (_displayCeilingCosine - _displayFloorCosine)))
        .clamp(0.0, 1.0)
        .toDouble();
    return LawMatchResult(
      lawName: article.law,
      articleNumber: article.article,
      title: article.title,
      chapterTitle: article.chapterTitle,
      description: article.articleText,
      articleText: article.articleText,
      matchScore: double.parse(similarity.toStringAsFixed(4)) * 100,
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
        for (final article in articles)
          // Search section context as well as the official article wording.
          [article.title, article.chapterTitle, article.articleText]
              .where((part) => part.trim().isNotEmpty)
              .join(' '),
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
