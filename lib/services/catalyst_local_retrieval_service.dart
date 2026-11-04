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
const double _defaultMinimumCosine = 0.79;

// Display calibration: cosine 0.75 (noise level) maps to 0% and 0.90 to 100%.
const double _displayFloorCosine = 0.75;
const double _displayCeilingCosine = 0.90;

// Share of the blended score given to the normalized BM25 signal.
const double _lexicalWeight = 0.15;
const String _articlesAssetPath = 'assets/data/legal_articles.json';
const String _chunkEmbeddingsAssetPath = 'assets/data/chunk_embeddings_e5.f32';
const String _chunkOwnersAssetPath = 'assets/data/chunk_owners_e5.json';
const String _encoderAssetPath = 'assets/models/catalyst_encoder_e5.onnx';

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

/// How a result list was produced, so the UI can tell the user whether an
/// internet connection was actually used.
enum RetrievalMode {
  /// On-device only (the app was built without an online service).
  onDevice,

  /// The online reviewer reordered the on-device candidates.
  online,

  /// The online service was tried but failed; on-device results are shown.
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
    this.mode = RetrievalMode.onDevice,
  });

  final List<LawMatchResult> results;
  final String originalQuery;
  final String processedQuery;
  final String warning;
  final RetrievalMode mode;

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
  });

  static Future<_LocalRetrievalResources>? _resourcesFuture;
  static Future<OrtSession>? _sessionFuture;

  final LocalQueryEncoder? _queryEncoder;
  final LegalQueryPreprocessor _queryPreprocessor;
  final CatalystRetrievalStrategy _strategy;
  final double _minimumCosine;
  final int _resultLimit;

  /// A provision from the local corpus by law and article number, or null.
  /// Duplicate ids resolve to the first corpus entry.
  Future<LawMatchResult?> lookupArticle(
    String law,
    String article, {
    double matchScore = 0,
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
    for (final variant in variants) {
      final vector = await _encodeQuery(resources, variant);
      _validateQueryEmbedding(vector);
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
    }

    final lexicalQuery = [
      originalQuery,
      processedQuery,
      ...analysis.glossaryTerms,
    ].join(' ');
    final lexical = resources.lexicalIndex.search(
      lexicalQuery,
      limit: _candidatePoolSize,
    );
    final fused = fuseRankings([
      ...denseLists,
      if (lexical.isNotEmpty) lexical.map((hit) => hit.index).toList(),
    ], k: _fusionK);

    // One blended score both orders the results and is shown on the cards:
    // calibrated dense similarity plus BM25 normalized by the best lexical hit.
    final maxLexical = lexical.isEmpty ? 0.0 : lexical.first.score;
    final lexicalScore = {for (final hit in lexical) hit.index: hit.score};
    double blendedScore(int index) {
      final meanCosine = cosineSum[index] / variants.length;
      final dense =
          ((meanCosine - _displayFloorCosine) /
                  (_displayCeilingCosine - _displayFloorCosine))
              .clamp(0.0, 1.0);
      final lexicalPart = maxLexical > 0
          ? (lexicalScore[index] ?? 0) / maxLexical
          : 0.0;
      return (1 - _lexicalWeight) * dense + _lexicalWeight * lexicalPart;
    }

    final blended = <int, double>{};
    final eligible = <int>[
      for (final candidate in fused)
        if (bestCosine[candidate.index] >= _minimumCosine) candidate.index,
    ];
    for (final index in eligible) {
      blended[index] = blendedScore(index);
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
  }) {
    final article = resources.articles[index];
    final id = normalizedArticleId(article.law, article.article);
    final similarity =
        blendedSimilarity ??
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
    return _LocalRetrievalResources(
      tokenizer: tokenizer,
      articles: articles,
      chunkEmbeddings: embeddings,
      chunkOwners: chunkOwners,
      lexicalIndex: Bm25Index.build([
        for (final article in articles) article.articleText,
      ]),
      duplicateIds: duplicates,
    );
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

class _LocalRetrievalResources {
  const _LocalRetrievalResources({
    required this.tokenizer,
    required this.articles,
    required this.chunkEmbeddings,
    required this.chunkOwners,
    required this.lexicalIndex,
    required this.duplicateIds,
  });

  final LocalTokenizer tokenizer;
  final List<CatalystLegalArticle> articles;
  final Float32List chunkEmbeddings;
  final List<int> chunkOwners;
  final Bm25Index lexicalIndex;
  final Set<String> duplicateIds;
}
