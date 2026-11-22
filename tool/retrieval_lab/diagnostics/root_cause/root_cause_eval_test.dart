// Fixture-driven audit of the production hybrid retrieval stages.
//
// Run from the repository root:
//   flutter test tool/retrieval_lab/diagnostics/root_cause/root_cause_eval_test.dart
//
// The stage-1 vectors are keyed by production-tokenizer input IDs, so no model
// or translation service is needed. The test asserts that its independent
// scoring port reproduces the saved production report before writing results.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/lexical_index.dart';
import 'package:catol/services/local_tokenizer.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = 'tool/retrieval_lab/diagnostics';
const _stage1 = '$_root/stage1_baseline';
const _outputDirectory = '$_root/root_cause';
const _dimensions = 384;
const _productionPool = 50;
const _productionFusionK = 20;
const _defaultThreshold = 0.80;
const _displayFloor = 0.75;
const _displayCeiling = 0.90;
const _lexicalWeight = 0.15;
const _trainingWeight = 0.30;
const _trainingNeighborCount = 3;
const _minimumTrainingCosine = 0.90;

const _offTopicQueries = <String>[
  'What is the best recipe for chicken adobo?',
  'Who won the basketball game last night?',
  'asdf qwer zxcv uiop',
  'How do I install a graphics driver on my laptop?',
  'Ano ang magandang lugar para mag-bakasyon sa Palawan?',
  'Anong oras magbubukas ang mall bukas?',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('diagnose development retrieval components and ablations', () async {
    final cases = (jsonDecode(
      File('$_stage1/cases.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final baselineReport = (jsonDecode(
      File('$_stage1/report.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final vectors =
        (jsonDecode(
          File('$_stage1/vectors.json').readAsStringSync(),
        ) as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key,
            (value as List)
                .cast<num>()
                .map((number) => number.toDouble())
                .toList(),
          ),
        );

    final tokenizer = await LocalTokenizer.load();
    final chunkTokenizer = HuggingFaceTokenizerLoader.fromJsonString(
      File(LocalTokenizer.assetPath).readAsStringSync(),
    )..enableTruncation(maxLength: 256);
    final articles =
        (jsonDecode(File('assets/data/legal_articles.json').readAsStringSync())
                as List)
            .map((value) => CatalystLegalArticle.fromJson(value))
            .toList(growable: false);
    final owners = (jsonDecode(
      File('assets/data/chunk_owners_e5.json').readAsStringSync(),
    ) as List).cast<num>().map((value) => value.toInt()).toList();
    final chunkBytes = File('assets/data/chunk_embeddings_e5.f32')
        .readAsBytesSync();
    final chunkEmbeddings = Float32List.view(
      chunkBytes.buffer,
      chunkBytes.offsetInBytes,
      chunkBytes.lengthInBytes ~/ 4,
    );
    final trainingLabels = jsonDecode(
      File('assets/data/training_query_labels_e5.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final trainingBytes = File('assets/data/training_query_embeddings_e5.f32')
        .readAsBytesSync();
    final trainingEmbeddings = Float32List.view(
      trainingBytes.buffer,
      trainingBytes.offsetInBytes,
      trainingBytes.lengthInBytes ~/ 4,
    );
    final trainingExamples = (trainingLabels['examples'] as List)
        .cast<Map<String, dynamic>>()
        .map(_TrainingExample.fromJson)
        .toList(growable: false);
    final lexicalIndex = Bm25Index.build([
      for (final article in articles) article.articleText,
    ]);

    final vectorProvider = _FixtureVectors(tokenizer, vectors);
    final queryData = <_QueryData>[
      for (final item in cases)
        _prepareQuery(
          item,
          articles: articles,
          owners: owners,
          chunkEmbeddings: chunkEmbeddings,
          trainingEmbeddings: trainingEmbeddings,
          trainingExamples: trainingExamples,
          lexicalIndex: lexicalIndex,
          vectorProvider: vectorProvider,
        ),
    ];
    final negativeData = <_NegativeData>[
      for (final query in _offTopicQueries)
        _prepareNegative(
          query,
          articles: articles,
          owners: owners,
          chunkEmbeddings: chunkEmbeddings,
          lexicalIndex: lexicalIndex,
          trainingEmbeddings: trainingEmbeddings,
          trainingExamples: trainingExamples,
          vectorProvider: vectorProvider,
        ),
    ];

    final experiments = _runExperiments(queryData);
    final negativeExperiments = _runNegativeExperiments(negativeData);
    final production = experiments.firstWhere(
      (experiment) => experiment['name'] == 'production_hybrid',
    );
    final baselineRows = baselineReport
        .where(
          (row) => row['strategy'] == 'hybrid' && row['mode'] == 'baseline',
        )
        .toList(growable: false);
    final legacyBaselineRows = baselineReport
        .where(
          (row) => row['strategy'] == 'denseOnly' && row['mode'] == 'baseline',
        )
        .toList(growable: false);
    final parity = _compareBaseline(
      queryData,
      baselineRows,
      production,
      legacyBaselineRows,
    );
    expect(
      parity['exactOrderedTop15Matches'],
      cases.length,
      reason:
          'The diagnostic port must reproduce every saved production result.',
    );
    expect(
      parity['legacyDenseOnlyExactTop3Matches'],
      cases.length,
      reason:
          'The legacy E5-only comparison must match the saved dense report.',
    );

    final assetAudit = _auditAssets(
      articles: articles,
      owners: owners,
      chunkTokenizer: chunkTokenizer,
      chunkEmbeddings: chunkEmbeddings,
      trainingLabels: trainingLabels,
      trainingExamples: trainingExamples,
      trainingEmbeddings: trainingEmbeddings,
      cases: cases,
    );
    final componentSummary = _summarizeComponents(queryData);
    final failureAnalysis = _analyzeFailures(queryData);
    final caseDetails = [for (final data in queryData) _caseRecord(data)];
    final report = <String, Object?>{
      'metadata': {
        'dataset': 'stage1_baseline/cases.json',
        'queryCount': cases.length,
        'heldoutDataUsed': false,
        'productionBehaviorChanged': false,
        'scoringImplementation':
            'Independent Dart port using production LocalTokenizer, '
            'Bm25Index, QueryAnalysis, corpus/chunk/training assets, and '
            'precomputed production ONNX query vectors.',
        'baselineParity': parity,
        'preprocessing': {
          'used':
              'Offline production path; BM25 includes original query and '
              'query_analysis glossary expansion.',
          'recordedProcessedQueryDifferences': [
            for (final item in cases)
              if (item['recordedProcessedQuery'] != item['query'])
                item['datasetId'],
          ],
          'recordedProcessedQueriesChanged': cases
              .where((item) => item['recordedProcessedQuery'] != item['query'])
              .length,
        },
        'configuration': {
          'queryPrefix': 'query: ',
          'passagePrefix': 'passage: ',
          'embeddingDimensions': _dimensions,
          'candidatePool': _productionPool,
          'fusionK': _productionFusionK,
          'minimumCosine': _defaultThreshold,
          'displayFloor': _displayFloor,
          'displayCeiling': _displayCeiling,
          'bm25Weight': _lexicalWeight,
          'trainingSignalWeight': _trainingWeight,
          'trainingNeighborCount': _trainingNeighborCount,
          'minimumTrainingQueryCosine': _minimumTrainingCosine,
          'resultLimit': 15,
        },
      },
      'baseline': {
        'hybrid': {
          'hitAt1': 11,
          'hitAt3': 16,
          'hitAt15': 20,
          'queryCount': cases.length,
        },
        'legacyDenseOnly': {
          'hitAt1': 2,
          'hitAt3': 6,
          'hitAt15': 6,
          'queryCount': cases.length,
          'note':
              'The saved legacy evaluation returns only three results; '
              'Hit@15 is therefore its all-results hit count.',
        },
        'source': 'stage1_baseline/report.json',
      },
      'assetAudit': assetAudit,
      'queryVectorAudit': vectorProvider.auditSummary,
      'queryDomainAudit': _queryDomainAudit(queryData),
      'componentSummary': componentSummary,
      'experiments': experiments,
      'negativeQueryExperiments': negativeExperiments,
      'failureAnalysis': failureAnalysis,
      'cases': caseDetails,
    };
    Directory(_outputDirectory).createSync(recursive: true);
    File('$_outputDirectory/root_cause_results.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    // Keep a compact review table beside the detailed per-query artifact.
    File('$_outputDirectory/experiment_summary.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'baselineParity': parity,
        'experiments': experiments,
        'negativeQueryExperiments': negativeExperiments,
        'componentSummary': componentSummary,
        'failureAnalysis': failureAnalysis,
        'assetAudit': assetAudit,
      }),
    );
  });
}

Map<String, Object?> _queryDomainAudit(List<_QueryData> data) {
  final confusion = <String, Map<String, int>>{};
  final mismatches = <Map<String, Object?>>[];
  for (final query in data) {
    final expected = switch (_legalGroup(
      query.caseRecord['domain'] as String,
    )) {
      'Family Code' => 'family',
      'Consumer Act' => 'consumer',
      _ => 'civil',
    };
    final actual = query.analysis.domain.name;
    final row = confusion.putIfAbsent(expected, () => <String, int>{});
    row[actual] = (row[actual] ?? 0) + 1;
    if (expected != actual) {
      mismatches.add({
        'datasetId': query.caseRecord['datasetId'],
        'expectedDomain': expected,
        'inferredDomain': actual,
        'language': query.caseRecord['language'],
        'trainingNeighborCount': query.trainingNeighbors.length,
      });
    }
  }
  return {
    'queryCount': data.length,
    'mismatchCount': mismatches.length,
    'confusionMatrix': confusion,
    'mismatches': mismatches,
    'note':
        'Evaluation-domain categories are only a coarse comparison to the '
        'production QueryDomain. A mismatch is not by itself proof that the '
        'query classifier is legally wrong.',
  };
}

class _FixtureVectors {
  _FixtureVectors(this.tokenizer, this.vectors);

  final LocalTokenizer tokenizer;
  final Map<String, List<double>> vectors;
  final Map<String, List<double>> _cache = {};
  final Map<String, double> _norms = {};

  Map<String, Object?> get auditSummary {
    final norms = _norms.values;
    return {
      'fixtureVectorCount': vectors.length,
      'vectorsUsed': _norms.length,
      'minNorm': norms.reduce(math.min),
      'maxNorm': norms.reduce(math.max),
      'maxAbsoluteUnitNormError': norms
          .map((norm) => (norm - 1).abs())
          .reduce(math.max),
    };
  }

  List<double> forText(String text) {
    final encoding = tokenizer.encode('query: $text');
    final key = encoding.ids.join(',');
    final vector = _cache[key] ?? vectors[key];
    if (vector == null) {
      throw StateError(
        'No Stage 1 ONNX vector exists for tokenizer input $key '
        '(query text: ${text.substring(0, math.min(text.length, 100))}).',
      );
    }
    if (vector.length != _dimensions) {
      throw StateError('Expected $_dimensions values for vector key $key.');
    }
    final norm = math.sqrt(
      vector.fold<double>(0, (sum, value) => sum + value * value),
    );
    if (!norm.isFinite || (norm - 1).abs() > 1e-3) {
      throw StateError('Invalid unit-normalized query embedding: $norm.');
    }
    _cache[key] = vector;
    _norms[key] = norm;
    return vector;
  }
}

class _TrainingExample {
  const _TrainingExample({
    required this.domain,
    required this.positive,
    required this.negative,
  });

  factory _TrainingExample.fromJson(Map<String, dynamic> value) =>
      _TrainingExample(
        domain: switch (value['domain']) {
          'civil' => QueryDomain.civil,
          'consumer' => QueryDomain.consumer,
          'family' => QueryDomain.family,
          _ => QueryDomain.unknown,
        },
        positive: (value['positiveArticleIndexes'] as List).cast<int>(),
        negative: (value['negativeArticleIndexes'] as List).cast<int>(),
      );

  final QueryDomain domain;
  final List<int> positive;
  final List<int> negative;
}

class _QueryData {
  const _QueryData({
    required this.caseRecord,
    required this.analysis,
    required this.variants,
    required this.variantCosines,
    required this.bestCosine,
    required this.meanCosine,
    required this.rawCosine,
    required this.rawOrder,
    required this.denseOrders,
    required this.lexical,
    required this.training,
    required this.trainingAllDomains,
    required this.trainingNeighbors,
    required this.trainingExamples,
    required this.relevantIds,
    required this.indexesById,
    required this.articles,
  });

  final Map<String, dynamic> caseRecord;
  final QueryAnalysis analysis;
  final List<String> variants;
  final List<List<double>> variantCosines;
  final List<double> bestCosine;
  final List<double> meanCosine;
  final List<double> rawCosine;
  final List<int> rawOrder;
  final List<List<int>> denseOrders;
  final List<({int index, double score})> lexical;
  final _TrainingRanking training;
  final _TrainingRanking trainingAllDomains;
  final List<({int index, double similarity})> trainingNeighbors;
  final List<_TrainingExample> trainingExamples;
  final Set<String> relevantIds;
  final Map<String, List<int>> indexesById;
  final List<CatalystLegalArticle> articles;
}

class _NegativeData {
  const _NegativeData({
    required this.query,
    required this.analysis,
    required this.bestCosine,
    required this.meanCosine,
    required this.denseOrders,
    required this.lexical,
    required this.trainingAllDomains,
    required this.articles,
  });

  final String query;
  final QueryAnalysis analysis;
  final List<double> bestCosine;
  final List<double> meanCosine;
  final List<List<int>> denseOrders;
  final List<({int index, double score})> lexical;
  final _TrainingRanking trainingAllDomains;
  final List<CatalystLegalArticle> articles;
}

class _TrainingRanking {
  const _TrainingRanking(this.indexes, this.votes);

  final List<int> indexes;
  final Map<int, double> votes;
}

class _RankedResult {
  const _RankedResult({
    required this.index,
    required this.id,
    required this.cosine,
    required this.bm25,
    required this.rrf,
    required this.score,
  });

  final int index;
  final String id;
  final double cosine;
  final double bm25;
  final double rrf;
  final double score;

  Map<String, Object?> toJson(int rank) => {
    'rank': rank,
    'articleIndex': index,
    'articleId': id,
    'bestCosine': cosine,
    'bm25Score': bm25,
    'rrfScore': rrf,
    'finalScore': score,
  };
}

_QueryData _prepareQuery(
  Map<String, dynamic> item, {
  required List<CatalystLegalArticle> articles,
  required List<int> owners,
  required Float32List chunkEmbeddings,
  required Float32List trainingEmbeddings,
  required List<_TrainingExample> trainingExamples,
  required Bm25Index lexicalIndex,
  required _FixtureVectors vectorProvider,
}) {
  final query = item['query'] as String;
  final analysis = analyzeQuery(query);
  final variants = <String>[
    analysis.normalized,
    if (analysis.glossaryQuery != null &&
        analysis.glossaryQuery!.isNotEmpty &&
        analysis.glossaryQuery != analysis.normalized)
      analysis.glossaryQuery!,
  ];
  final cosineLists = [
    for (final variant in variants)
      _articleCosines(
        vectorProvider.forText(variant),
        articles.length,
        owners,
        chunkEmbeddings,
      ),
  ];
  final bestCosine = List<double>.filled(articles.length, -1);
  final meanCosine = List<double>.filled(articles.length, 0);
  for (var article = 0; article < articles.length; article++) {
    for (final scores in cosineLists) {
      bestCosine[article] = math.max(bestCosine[article], scores[article]);
      meanCosine[article] += scores[article] / cosineLists.length;
    }
  }
  final denseOrders = [for (final scores in cosineLists) _rankScores(scores)];
  final rawCosine = _articleCosines(
    vectorProvider.forText(query),
    articles.length,
    owners,
    chunkEmbeddings,
  );
  final processedQuery = query;
  final lexicalQuery = [
    query,
    processedQuery,
    ...analysis.glossaryTerms,
    ...expandLegalWording(query),
  ].join(' ');
  final lexical = lexicalIndex.search(lexicalQuery, limit: articles.length);
  final queryVector = vectorProvider.forText(analysis.normalized);
  final training = _rankTraining(
    domain: analysis.domain,
    queryVector: queryVector,
    trainingEmbeddings: trainingEmbeddings,
    examples: trainingExamples,
  );
  final trainingAllDomains = _rankTraining(
    domain: analysis.domain,
    queryVector: queryVector,
    trainingEmbeddings: trainingEmbeddings,
    examples: trainingExamples,
    filterDomain: false,
  );
  final neighbors = _nearestTrainingExamples(
    domain: analysis.domain,
    queryVector: queryVector,
    trainingEmbeddings: trainingEmbeddings,
    examples: trainingExamples,
  );

  final indexesById = <String, List<int>>{};
  for (var index = 0; index < articles.length; index++) {
    indexesById
        .putIfAbsent(
          normalizedArticleId(articles[index].law, articles[index].article),
          () => <int>[],
        )
        .add(index);
  }
  return _QueryData(
    caseRecord: item,
    analysis: analysis,
    variants: variants,
    variantCosines: cosineLists,
    bestCosine: bestCosine,
    meanCosine: meanCosine,
    rawCosine: rawCosine,
    rawOrder: _rankScores(rawCosine),
    denseOrders: denseOrders,
    lexical: lexical,
    training: training,
    trainingAllDomains: trainingAllDomains,
    trainingNeighbors: neighbors,
    trainingExamples: trainingExamples,
    relevantIds: (item['reviewedRelevantArticleIds'] as List)
        .cast<String>()
        .toSet(),
    indexesById: indexesById,
    articles: articles,
  );
}

_NegativeData _prepareNegative(
  String query, {
  required List<CatalystLegalArticle> articles,
  required List<int> owners,
  required Float32List chunkEmbeddings,
  required Bm25Index lexicalIndex,
  required Float32List trainingEmbeddings,
  required List<_TrainingExample> trainingExamples,
  required _FixtureVectors vectorProvider,
}) {
  final analysis = analyzeQuery(query);
  final variants = <String>[
    analysis.normalized,
    if (analysis.glossaryQuery != null &&
        analysis.glossaryQuery != analysis.normalized)
      analysis.glossaryQuery!,
  ];
  final cosineLists = [
    for (final variant in variants)
      _articleCosines(
        vectorProvider.forText(variant),
        articles.length,
        owners,
        chunkEmbeddings,
      ),
  ];
  final best = List<double>.filled(articles.length, -1);
  final mean = List<double>.filled(articles.length, 0);
  for (var article = 0; article < articles.length; article++) {
    for (final scores in cosineLists) {
      best[article] = math.max(best[article], scores[article]);
      mean[article] += scores[article] / cosineLists.length;
    }
  }
  final lexicalQuery = [
    query,
    query,
    ...analysis.glossaryTerms,
    ...expandLegalWording(query),
  ].join(' ');
  final trainingAllDomains = _rankTraining(
    domain: analysis.domain,
    queryVector: vectorProvider.forText(analysis.normalized),
    trainingEmbeddings: trainingEmbeddings,
    examples: trainingExamples,
    filterDomain: false,
  );
  return _NegativeData(
    query: query,
    analysis: analysis,
    bestCosine: best,
    meanCosine: mean,
    denseOrders: [for (final scores in cosineLists) _rankScores(scores)],
    lexical: lexicalIndex.search(lexicalQuery, limit: articles.length),
    trainingAllDomains: trainingAllDomains,
    articles: articles,
  );
}

List<double> _articleCosines(
  List<double> vector,
  int articleCount,
  List<int> owners,
  Float32List embeddings,
) {
  final scores = List<double>.filled(articleCount, -1);
  for (var chunk = 0; chunk < owners.length; chunk++) {
    var cosine = 0.0;
    final start = chunk * _dimensions;
    for (var dimension = 0; dimension < _dimensions; dimension++) {
      cosine += embeddings[start + dimension] * vector[dimension];
    }
    if (!cosine.isFinite || cosine.abs() > 1.001) {
      throw StateError('Invalid cosine $cosine in chunk $chunk.');
    }
    final owner = owners[chunk];
    if (cosine > scores[owner]) scores[owner] = cosine;
  }
  return scores;
}

List<int> _rankScores(List<double> scores) {
  final indexes = List<int>.generate(scores.length, (index) => index)
    ..sort((left, right) {
      final byScore = scores[right].compareTo(scores[left]);
      return byScore != 0 ? byScore : left.compareTo(right);
    });
  return indexes;
}

List<({int index, double similarity})> _nearestTrainingExamples({
  required QueryDomain domain,
  required List<double> queryVector,
  required Float32List trainingEmbeddings,
  required List<_TrainingExample> examples,
  bool filterDomain = true,
}) {
  if (filterDomain && domain == QueryDomain.unknown) {
    return const [];
  }
  final matches = <({int index, double similarity})>[];
  for (var index = 0; index < examples.length; index++) {
    if (filterDomain && examples[index].domain != domain) continue;
    var similarity = 0.0;
    final start = index * _dimensions;
    for (var dimension = 0; dimension < _dimensions; dimension++) {
      similarity +=
          trainingEmbeddings[start + dimension] * queryVector[dimension];
    }
    if (similarity.isFinite) {
      matches.add((index: index, similarity: similarity));
    }
  }
  matches.sort((left, right) {
    final bySimilarity = right.similarity.compareTo(left.similarity);
    return bySimilarity != 0 ? bySimilarity : left.index.compareTo(right.index);
  });
  return matches;
}

_TrainingRanking _rankTraining({
  required QueryDomain domain,
  required List<double> queryVector,
  required Float32List trainingEmbeddings,
  required List<_TrainingExample> examples,
  bool filterDomain = true,
}) {
  final neighbors = _nearestTrainingExamples(
    domain: domain,
    queryVector: queryVector,
    trainingEmbeddings: trainingEmbeddings,
    examples: examples,
    filterDomain: filterDomain,
  );
  if (neighbors.isEmpty ||
      neighbors.first.similarity < _minimumTrainingCosine) {
    return const _TrainingRanking([], {});
  }
  final votes = <int, double>{};
  var neighborRank = 0;
  for (final neighbor in neighbors) {
    if (neighborRank == _trainingNeighborCount ||
        neighbor.similarity < _minimumTrainingCosine) {
      break;
    }
    final weight =
        math.pow(neighbor.similarity.clamp(0, 1), 3).toDouble() /
        math.sqrt(neighborRank + 1);
    neighborRank++;
    final example = examples[neighbor.index];
    for (final index in example.positive) {
      votes[index] = (votes[index] ?? 0) + weight;
    }
    for (final index in example.negative) {
      votes[index] = (votes[index] ?? 0) - weight;
    }
  }
  final positiveVotes = <int, double>{
    for (final entry in votes.entries)
      if (entry.value > 0) entry.key: entry.value,
  };
  if (positiveVotes.isEmpty) return const _TrainingRanking([], {});
  final maximum = positiveVotes.values.reduce(math.max);
  final indexes = positiveVotes.keys.toList()
    ..sort((left, right) {
      final byVote = positiveVotes[right]!.compareTo(positiveVotes[left]!);
      return byVote != 0 ? byVote : left.compareTo(right);
    });
  return _TrainingRanking(indexes, {
    for (final index in indexes) index: positiveVotes[index]! / maximum,
  });
}

List<Map<String, Object?>> _runExperiments(List<_QueryData> data) {
  final experiments = <Map<String, Object?>>[];
  void add(
    String name, {
    int pool = _productionPool,
    double threshold = _defaultThreshold,
    double lexicalWeight = _lexicalWeight,
    double trainingWeight = _trainingWeight,
    bool includeTraining = true,
    String ranker = 'hybrid',
    int resultLimit = 15,
    bool useAllDomainTraining = false,
  }) {
    final runs = [
      for (final query in data)
        _rankQuery(
          query,
          pool: pool,
          threshold: threshold,
          lexicalWeight: lexicalWeight,
          trainingWeight: trainingWeight,
          includeTraining: includeTraining,
          ranker: ranker,
          resultLimit: resultLimit,
          useAllDomainTraining: useAllDomainTraining,
        ),
    ];
    experiments.add({
      'name': name,
      'candidatePool': pool,
      'minimumCosine': threshold < 0 ? null : threshold,
      'bm25Weight': lexicalWeight,
      'trainingSignalWeight': trainingWeight,
      'trainingSignalEnabled': includeTraining,
      'trainingDomainFiltered': !useAllDomainTraining,
      'ranker': ranker,
      'resultLimit': resultLimit,
      ..._aggregateMetrics(data, runs),
      'candidateCoverage': _candidateCoverage(
        data,
        pool: pool,
        includeTraining: includeTraining,
        ranker: ranker,
        threshold: threshold,
        useAllDomainTraining: useAllDomainTraining,
      ),
    });
  }

  add('production_hybrid');
  add('e5_only', threshold: -1, includeTraining: false, ranker: 'e5');
  add(
    'legacy_dense_only_exact_top3',
    threshold: -1,
    includeTraining: false,
    ranker: 'legacy_e5',
    resultLimit: 3,
  );
  add('bm25_only', includeTraining: false, ranker: 'bm25');
  add('e5_bm25_no_training', includeTraining: false, trainingWeight: 0);
  add('hybrid_training_without_domain_filter', useAllDomainTraining: true);
  add('hybrid_without_cosine_gate', threshold: -1);
  add('hybrid_threshold_0_75', threshold: 0.75);
  add('hybrid_threshold_0_78', threshold: 0.78);
  add('hybrid_threshold_0_82', threshold: 0.82);
  add('hybrid_threshold_0_85', threshold: 0.85);
  add('hybrid_threshold_0_90', threshold: 0.90);
  for (final weight in [0.0, 0.15, 0.30, 0.50]) {
    add('hybrid_bm25_weight_${_numberName(weight)}', lexicalWeight: weight);
  }
  for (final weight in [0.0, 0.15, 0.30, 0.50]) {
    add(
      'hybrid_training_weight_${_numberName(weight)}',
      trainingWeight: weight,
      includeTraining: true,
    );
  }
  for (final pool in [100, 200, 500]) {
    add('hybrid_pool_$pool', pool: pool);
  }
  add('hybrid_pool_500_no_gate', pool: 500, threshold: -1);
  add('hybrid_pool_500_threshold_0_75', pool: 500, threshold: 0.75);
  add('hybrid_pool_500_threshold_0_78', pool: 500, threshold: 0.78);
  for (final bm25Weight in [0.0, 0.15, 0.30, 0.50]) {
    for (final trainingWeight in [0.0, 0.15, 0.30, 0.50]) {
      add(
        'hybrid_weights_bm25_${_numberName(bm25Weight)}_training_${_numberName(trainingWeight)}',
        lexicalWeight: bm25Weight,
        trainingWeight: trainingWeight,
      );
    }
  }
  return experiments;
}

String _numberName(double value) => value.toString().replaceAll('.', '_');

List<_RankedResult> _rankQuery(
  _QueryData query, {
  required int pool,
  required double threshold,
  required double lexicalWeight,
  required double trainingWeight,
  required bool includeTraining,
  required String ranker,
  int resultLimit = 15,
  bool useAllDomainTraining = false,
}) {
  final training = useAllDomainTraining
      ? query.trainingAllDomains
      : query.training;
  final lists = switch (ranker) {
    'e5' => <List<int>>[query.denseOrders.first.take(pool).toList()],
    'legacy_e5' => <List<int>>[query.rawOrder.take(pool).toList()],
    'bm25' => <List<int>>[
      query.lexical.take(pool).map((hit) => hit.index).toList(),
    ],
    _ => <List<int>>[
      for (final order in query.denseOrders) order.take(pool).toList(),
      query.lexical.take(pool).map((hit) => hit.index).toList(),
      if (includeTraining && training.indexes.isNotEmpty)
        training.indexes.take(pool).toList(),
    ],
  };
  final fused = fuseRankings(lists, k: _productionFusionK);
  final lexicalScores = <int, double>{
    for (final hit in query.lexical.take(pool)) hit.index: hit.score,
  };
  final maxLexical = query.lexical.isEmpty ? 0.0 : query.lexical.first.score;
  final eligible = <({int index, double rrf, double score})>[];
  for (final candidate in fused) {
    final index = candidate.index;
    if (ranker != 'bm25' &&
        threshold >= 0 &&
        query.bestCosine[index] < threshold) {
      continue;
    }
    double score;
    if (ranker == 'e5') {
      score = query.variantCosines.first[index];
    } else if (ranker == 'legacy_e5') {
      score = query.rawCosine[index];
    } else if (ranker == 'bm25') {
      score = lexicalScores[index] ?? 0;
    } else {
      final dense =
          ((query.meanCosine[index] - _displayFloor) /
                  (_displayCeiling - _displayFloor))
              .clamp(0.0, 1.0);
      final lexicalPart = maxLexical > 0
          ? (lexicalScores[index] ?? 0) / maxLexical
          : 0.0;
      final corpusScore =
          (1 - lexicalWeight) * dense + lexicalWeight * lexicalPart;
      final trainingPart = includeTraining ? (training.votes[index] ?? 0) : 0.0;
      score =
          (1 - trainingWeight) * corpusScore + trainingWeight * trainingPart;
    }
    eligible.add((index: index, rrf: candidate.score, score: score));
  }
  // The production stable sort retains RRF order for equal blended scores.
  final orderWithinFused = {
    for (var position = 0; position < fused.length; position++)
      fused[position].index: position,
  };
  eligible.sort((left, right) {
    final byScore = right.score.compareTo(left.score);
    return byScore != 0
        ? byScore
        : orderWithinFused[left.index]!.compareTo(
            orderWithinFused[right.index]!,
          );
  });
  final bm25Scores = {for (final hit in query.lexical) hit.index: hit.score};
  final seenIds = <String>{};
  final results = <_RankedResult>[];
  for (final candidate in eligible) {
    final article = query.articles[candidate.index];
    final id = normalizedArticleId(article.law, article.article);
    if (!seenIds.add(id)) continue;
    results.add(
      _RankedResult(
        index: candidate.index,
        id: id,
        cosine: query.bestCosine[candidate.index],
        bm25: bm25Scores[candidate.index] ?? 0,
        rrf: candidate.rrf,
        score: candidate.score,
      ),
    );
    if (results.length == resultLimit) break;
  }
  return results;
}

Map<String, Object?> _candidateCoverage(
  List<_QueryData> data, {
  required int pool,
  required bool includeTraining,
  required String ranker,
  required double threshold,
  bool useAllDomainTraining = false,
}) {
  var queriesWithCandidate = 0;
  var queriesWithEligibleCandidate = 0;
  var labelsInCandidates = 0;
  var labelsInEligibleCandidates = 0;
  var labelsTotal = 0;
  for (final query in data) {
    final training = useAllDomainTraining
        ? query.trainingAllDomains
        : query.training;
    final lists = switch (ranker) {
      'e5' => <List<int>>[query.denseOrders.first.take(pool).toList()],
      'legacy_e5' => <List<int>>[query.rawOrder.take(pool).toList()],
      'bm25' => <List<int>>[
        query.lexical.take(pool).map((hit) => hit.index).toList(),
      ],
      _ => <List<int>>[
        for (final order in query.denseOrders) order.take(pool).toList(),
        query.lexical.take(pool).map((hit) => hit.index).toList(),
        if (includeTraining && training.indexes.isNotEmpty)
          training.indexes.take(pool).toList(),
      ],
    };
    final candidates = fuseRankings(
      lists,
      k: _productionFusionK,
    ).map((entry) => entry.index).toSet();
    final eligible = ranker != 'hybrid' || threshold < 0
        ? candidates
        : candidates
              .where((index) => query.bestCosine[index] >= threshold)
              .toSet();
    var queryHasCandidate = false;
    var queryHasEligible = false;
    for (final id in query.relevantIds) {
      labelsTotal++;
      final indexes = query.indexesById[id] ?? const <int>[];
      if (indexes.any(candidates.contains)) {
        labelsInCandidates++;
        queryHasCandidate = true;
      }
      if (indexes.any(eligible.contains)) {
        labelsInEligibleCandidates++;
        queryHasEligible = true;
      }
    }
    if (queryHasCandidate) queriesWithCandidate++;
    if (queryHasEligible) queriesWithEligibleCandidate++;
  }
  return {
    'queriesWithAnyExpectedCandidate': queriesWithCandidate,
    'queryCandidateRecall': queriesWithCandidate / data.length,
    'queriesWithAnyEligibleExpectedCandidate': queriesWithEligibleCandidate,
    'queryEligibleCandidateRecall': queriesWithEligibleCandidate / data.length,
    'relevantLabelsFound': labelsInCandidates,
    'relevantLabelCount': labelsTotal,
    'relevantLabelCandidateRecall': labelsTotal == 0
        ? 0
        : labelsInCandidates / labelsTotal,
    'relevantLabelsSurvivingCosineGate': labelsInEligibleCandidates,
    'relevantLabelEligibleRecall': labelsTotal == 0
        ? 0
        : labelsInEligibleCandidates / labelsTotal,
  };
}

Map<String, Object?> _aggregateMetrics(
  List<_QueryData> data,
  List<List<_RankedResult>> runs,
) {
  var hit1 = 0;
  var hit3 = 0;
  var hit15 = 0;
  var relevantCount = 0;
  var retrievedRelevantAt1 = 0;
  var retrievedRelevantAt3 = 0;
  var retrievedRelevantAt15 = 0;
  for (var index = 0; index < data.length; index++) {
    final relevant = data[index].relevantIds;
    final ids = runs[index].map((result) => result.id).toList();
    if (ids.isNotEmpty && relevant.contains(ids[0])) hit1++;
    if (ids.take(3).any(relevant.contains)) hit3++;
    if (ids.take(15).any(relevant.contains)) hit15++;
    relevantCount += relevant.length;
    retrievedRelevantAt1 += ids.take(1).where(relevant.contains).length;
    retrievedRelevantAt3 += ids.take(3).where(relevant.contains).length;
    retrievedRelevantAt15 += ids.take(15).where(relevant.contains).length;
  }
  return {
    'queryCount': data.length,
    'hitAt1': hit1,
    'hitAt3': hit3,
    'hitAt15': hit15,
    'hitAt1Rate': hit1 / data.length,
    'hitAt3Rate': hit3 / data.length,
    'hitAt15Rate': hit15 / data.length,
    'relevantArticleCount': relevantCount,
    'relevantRecallAt1': relevantCount == 0
        ? 0
        : retrievedRelevantAt1 / relevantCount,
    'relevantRecallAt3': relevantCount == 0
        ? 0
        : retrievedRelevantAt3 / relevantCount,
    'relevantRecallAt15': relevantCount == 0
        ? 0
        : retrievedRelevantAt15 / relevantCount,
  };
}

Map<String, Object?> _compareBaseline(
  List<_QueryData> data,
  List<Map<String, dynamic>> baselineRows,
  Map<String, Object?> production,
  List<Map<String, dynamic>> legacyBaselineRows,
) {
  var exactOrderedTop15Matches = 0;
  var exactLegacyTop3Matches = 0;
  final mismatches = <Map<String, Object?>>[];
  final legacyMismatches = <Map<String, Object?>>[];
  for (final query in data) {
    final id = query.caseRecord['datasetId'];
    final baseline = baselineRows.firstWhere((row) => row['datasetId'] == id);
    final actual = _rankQuery(
      query,
      pool: _productionPool,
      threshold: _defaultThreshold,
      lexicalWeight: _lexicalWeight,
      trainingWeight: _trainingWeight,
      includeTraining: true,
      ranker: 'hybrid',
    ).map((result) => result.id).toList();
    final expected = (baseline['all'] as List).cast<String>();
    if (_sameList(actual, expected)) {
      exactOrderedTop15Matches++;
    } else {
      mismatches.add({'datasetId': id, 'expected': expected, 'actual': actual});
    }
    final legacyBaseline = legacyBaselineRows.firstWhere(
      (row) => row['datasetId'] == id,
    );
    final legacyActual = _rankQuery(
      query,
      pool: _productionPool,
      threshold: -1,
      lexicalWeight: _lexicalWeight,
      trainingWeight: _trainingWeight,
      includeTraining: false,
      ranker: 'legacy_e5',
      resultLimit: 3,
    ).map((result) => result.id).toList();
    final legacyExpected = (legacyBaseline['all'] as List).cast<String>();
    if (_sameList(legacyActual, legacyExpected)) {
      exactLegacyTop3Matches++;
    } else {
      legacyMismatches.add({
        'datasetId': id,
        'expected': legacyExpected,
        'actual': legacyActual,
      });
    }
  }
  return {
    'savedBaselineMetrics': {'hitAt1': 11, 'hitAt3': 16, 'hitAt15': 20},
    'diagnosticMetrics': {
      'hitAt1': production['hitAt1'],
      'hitAt3': production['hitAt3'],
      'hitAt15': production['hitAt15'],
    },
    'exactOrderedTop15Matches': exactOrderedTop15Matches,
    'legacyDenseOnlyExactTop3Matches': exactLegacyTop3Matches,
    'queryCount': data.length,
    'mismatches': mismatches,
    'legacyMismatches': legacyMismatches,
  };
}

bool _sameList(List<String> first, List<String> second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}

Map<String, Object?> _caseRecord(_QueryData query) {
  final productionRuns = _rankQuery(
    query,
    pool: _productionPool,
    threshold: _defaultThreshold,
    lexicalWeight: _lexicalWeight,
    trainingWeight: _trainingWeight,
    includeTraining: true,
    ranker: 'hybrid',
  );
  final fused = fuseRankings([
    for (final order in query.denseOrders) order.take(_productionPool).toList(),
    query.lexical.take(_productionPool).map((hit) => hit.index).toList(),
    if (query.training.indexes.isNotEmpty)
      query.training.indexes.take(_productionPool).toList(),
  ], k: _productionFusionK);
  final fusedRank = {
    for (var rank = 0; rank < fused.length; rank++) fused[rank].index: rank + 1,
  };
  final bm25Ranks = {
    for (var rank = 0; rank < query.lexical.length; rank++)
      query.lexical[rank].index: (
        rank: rank + 1,
        score: query.lexical[rank].score,
      ),
  };
  final trainingRanks = {
    for (var rank = 0; rank < query.training.indexes.length; rank++)
      query.training.indexes[rank]: rank + 1,
  };
  final finalRanks = {
    for (var rank = 0; rank < productionRuns.length; rank++)
      productionRuns[rank].index: rank + 1,
  };
  final targetDetails = <Map<String, Object?>>[];
  for (final id in query.relevantIds) {
    final indexes = query.indexesById[id] ?? const <int>[];
    final matches = <Map<String, Object?>>[];
    for (final index in indexes) {
      final semanticRanks = [
        for (final order in query.denseOrders) _rankIndex(order, index),
      ];
      final bm25 = bm25Ranks[index];
      final cosine = query.bestCosine[index];
      final inCombined = fusedRank.containsKey(index);
      final survives = inCombined && cosine >= _defaultThreshold;
      matches.add({
        'articleIndex': index,
        'semanticTop50RanksByVariant': semanticRanks
            .map((rank) => rank <= _productionPool ? rank : null)
            .toList(),
        'semanticBestCosine': cosine,
        'semanticMeanCosine': query.meanCosine[index],
        'bm25Top50Rank': bm25 != null && bm25.rank <= _productionPool
            ? bm25.rank
            : null,
        'bm25Score': bm25?.score ?? 0,
        'trainingTop50Rank':
            trainingRanks[index] != null &&
                trainingRanks[index]! <= _productionPool
            ? trainingRanks[index]
            : null,
        'trainingVote': query.training.votes[index] ?? 0,
        'rrfRank': fusedRank[index],
        'rrfScore': inCombined
            ? fused.firstWhere((entry) => entry.index == index).score
            : 0,
        'inCombinedCandidateList': inCombined,
        'survivesCosineThreshold': survives,
        'finalRank': finalRanks[index],
      });
    }
    targetDetails.add({
      'articleId': id,
      'presentInCorpus': indexes.isNotEmpty,
      'corpusIndexes': indexes,
      'candidates': matches,
      'inSemanticTop50': matches.any(
        (match) => (match['semanticTop50RanksByVariant'] as List).any(
          (rank) => rank != null,
        ),
      ),
      'inBm25Top50': matches.any((match) => match['bm25Top50Rank'] != null),
      'inTrainingTop50': matches.any(
        (match) => match['trainingTop50Rank'] != null,
      ),
      'inCombinedCandidateList': matches.any(
        (match) => match['inCombinedCandidateList'] == true,
      ),
      'survivesCosineThreshold': matches.any(
        (match) => match['survivesCosineThreshold'] == true,
      ),
      'finalRank': matches
          .map((match) => match['finalRank'] as int?)
          .whereType<int>()
          .fold<int?>(
            null,
            (best, rank) => best == null || rank < best ? rank : best,
          ),
    });
  }
  final unfiltered = _rankQuery(
    query,
    pool: _productionPool,
    threshold: -1,
    lexicalWeight: _lexicalWeight,
    trainingWeight: _trainingWeight,
    includeTraining: true,
    ranker: 'hybrid',
  );
  final top15 = [
    for (var rank = 0; rank < productionRuns.length; rank++)
      productionRuns[rank].toJson(rank + 1),
  ];
  final candidateDetails = [
    for (final candidate in fused)
      {
        'articleIndex': candidate.index,
        'articleId': normalizedArticleId(
          query.articles[candidate.index].law,
          query.articles[candidate.index].article,
        ),
        'rrfRank': fusedRank[candidate.index],
        'rrfScore': candidate.score,
        'bestCosine': query.bestCosine[candidate.index],
        'bm25Score': bm25Ranks[candidate.index]?.score ?? 0,
        'trainingVote': query.training.votes[candidate.index] ?? 0,
        'survivesCosineThreshold':
            query.bestCosine[candidate.index] >= _defaultThreshold,
        'finalRank': finalRanks[candidate.index],
      },
  ];
  return {
    'datasetId': query.caseRecord['datasetId'],
    'language': query.caseRecord['language'],
    'domain': query.caseRecord['domain'],
    'inferredDomain': query.analysis.domain.name,
    'query': query.caseRecord['query'],
    'recordedProcessedQuery': query.caseRecord['recordedProcessedQuery'],
    'normalizedQuery': query.analysis.normalized,
    'glossaryTerms': query.analysis.glossaryTerms,
    'expectedArticleIds': query.relevantIds.toList()..sort(),
    'semanticVariants': query.variants,
    'nearestTrainingExamples': [
      for (final neighbor in query.trainingNeighbors.take(
        _trainingNeighborCount,
      ))
        {
          'trainingExampleIndex': neighbor.index,
          'cosine': neighbor.similarity,
          'passesMinimumTrainingCosine':
              neighbor.similarity >= _minimumTrainingCosine,
          'positiveArticleIds': [
            for (final index in query.trainingExamples[neighbor.index].positive)
              normalizedArticleId(
                query.articles[index].law,
                query.articles[index].article,
              ),
          ],
          'negativeArticleIds': [
            for (final index in query.trainingExamples[neighbor.index].negative)
              normalizedArticleId(
                query.articles[index].law,
                query.articles[index].article,
              ),
          ],
        },
    ],
    'componentLists': {
      'semanticTop50ByVariant': [
        for (var variant = 0; variant < query.denseOrders.length; variant++)
          {
            'variant': query.variants[variant],
            'candidates': [
              for (var rank = 0; rank < _productionPool; rank++)
                {
                  'rank': rank + 1,
                  'articleIndex': query.denseOrders[variant][rank],
                  'articleId': normalizedArticleId(
                    query.articles[query.denseOrders[variant][rank]].law,
                    query.articles[query.denseOrders[variant][rank]].article,
                  ),
                  'cosine': _scoreAt(
                    query,
                    variant,
                    query.denseOrders[variant][rank],
                  ),
                },
            ],
          },
      ],
      'bm25Top50': [
        for (
          var rank = 0;
          rank < math.min(_productionPool, query.lexical.length);
          rank++
        )
          {
            'rank': rank + 1,
            'articleIndex': query.lexical[rank].index,
            'articleId': normalizedArticleId(
              query.articles[query.lexical[rank].index].law,
              query.articles[query.lexical[rank].index].article,
            ),
            'bm25Score': query.lexical[rank].score,
          },
      ],
      'trainingQueryTop50': [
        for (
          var rank = 0;
          rank < math.min(_productionPool, query.training.indexes.length);
          rank++
        )
          {
            'rank': rank + 1,
            'articleIndex': query.training.indexes[rank],
            'articleId': normalizedArticleId(
              query.articles[query.training.indexes[rank]].law,
              query.articles[query.training.indexes[rank]].article,
            ),
            'normalizedVote':
                query.training.votes[query.training.indexes[rank]],
          },
      ],
      'combinedRrf': {
        'candidateCount': fused.length,
        'cosineGateSurvivorCount': candidateDetails
            .where((candidate) => candidate['survivesCosineThreshold'] == true)
            .length,
        'candidates': candidateDetails,
      },
      'withoutCosineGateTop15': [
        for (var rank = 0; rank < unfiltered.length; rank++)
          unfiltered[rank].toJson(rank + 1),
      ],
      'finalTop15': top15,
    },
    'expectedArticleDiagnostics': targetDetails,
  };
}

double _scoreAt(_QueryData query, int variant, int index) {
  // Dense candidates are stored in ranked order, while scores are retained in
  // article order for exact per-variant reporting.
  return query.variantCosines[variant][index];
}

int _rankIndex(List<int> order, int index) => order.indexOf(index) + 1;

List<Map<String, Object?>> _runNegativeExperiments(List<_NegativeData> data) {
  final output = <Map<String, Object?>>[];
  for (final trainingMode in ['domain_filtered', 'all_domains']) {
    for (final threshold in [0.75, 0.78, 0.80, 0.82, 0.85, 0.90]) {
      var anyReturned = 0;
      var returnedCount = 0;
      final queryResults = <Map<String, Object?>>[];
      for (final query in data) {
        final trainingEnabled = trainingMode == 'all_domains';
        final training = query.trainingAllDomains;
        final fused = fuseRankings([
          for (final order in query.denseOrders)
            order.take(_productionPool).toList(),
          query.lexical.take(_productionPool).map((hit) => hit.index).toList(),
          if (trainingEnabled && training.indexes.isNotEmpty)
            training.indexes.take(_productionPool).toList(),
        ], k: _productionFusionK);
        final lexicalScores = {
          for (final hit in query.lexical.take(_productionPool))
            hit.index: hit.score,
        };
        final maxLexical = query.lexical.isEmpty
            ? 0.0
            : query.lexical.first.score;
        final kept = fused
            .where(
              (candidate) => query.bestCosine[candidate.index] >= threshold,
            )
            .toList();
        final fusedRank = {
          for (var index = 0; index < fused.length; index++)
            fused[index].index: index,
        };
        kept.sort((left, right) {
          double blendedScore(int index) {
            final dense =
                ((query.meanCosine[index] - _displayFloor) /
                        (_displayCeiling - _displayFloor))
                    .clamp(0.0, 1.0);
            final lexicalPart = maxLexical > 0
                ? (lexicalScores[index] ?? 0) / maxLexical
                : 0.0;
            final corpusScore =
                (1 - _lexicalWeight) * dense + _lexicalWeight * lexicalPart;
            final trainingPart = trainingEnabled
                ? (training.votes[index] ?? 0)
                : 0.0;
            return (1 - _trainingWeight) * corpusScore +
                _trainingWeight * trainingPart;
          }

          final byScore = blendedScore(right.index)
              .compareTo(blendedScore(left.index));
          return byScore != 0
              ? byScore
              : fusedRank[left.index]!.compareTo(fusedRank[right.index]!);
        });
        final ids = <String>{};
        for (final candidate in kept) {
          final article = query.articles[candidate.index];
          ids.add(normalizedArticleId(article.law, article.article));
          if (ids.length == 15) break;
        }
        if (ids.isNotEmpty) anyReturned++;
        returnedCount += ids.length;
        queryResults.add({
          'query': query.query,
          'returnedArticleCount': ids.length,
          'falsePositive': ids.isNotEmpty,
          'topArticleIds': ids.toList(),
          'maximumCandidateCosine': query.bestCosine.reduce(math.max),
        });
      }
      output.add({
        'trainingMode': trainingMode,
        'minimumCosine': threshold,
        'noMatchQueryCount': data.length,
        'falsePositiveQueries': anyReturned,
        'falsePositiveRate': anyReturned / data.length,
        'totalDistinctArticlesReturned': returnedCount,
        'meanDistinctArticlesReturnedPerQuery': returnedCount / data.length,
        'queryResults': queryResults,
      });
    }
  }
  return output;
}

Map<String, Object?> _summarizeComponents(List<_QueryData> data) {
  final componentNames = [
    'semanticPrimaryTop50',
    'semanticGlossaryTop50',
    'semanticTop50',
    'bm25Top50',
    'trainingQueryTop50',
    'combinedRrf',
    'cosineGate',
    'finalTop15',
    'finalTop3',
  ];
  final summaries = <String, Object?>{};
  for (final component in componentNames) {
    var queryHits = 0;
    var relevantHits = 0;
    var relevantTotal = 0;
    for (final query in data) {
      var queryHit = false;
      for (final id in query.relevantIds) {
        relevantTotal++;
        final indexes = query.indexesById[id] ?? const <int>[];
        final contains = switch (component) {
          'semanticPrimaryTop50' =>
            query.denseOrders.first.take(_productionPool).any(indexes.contains),
          'semanticGlossaryTop50' =>
            query.denseOrders.length > 1 &&
                query.denseOrders[1]
                    .take(_productionPool)
                    .any(indexes.contains),
          'semanticTop50' => indexes.any(
            (index) => query.denseOrders.any(
              (order) => order.take(_productionPool).contains(index),
            ),
          ),
          'bm25Top50' => indexes.any(
            (index) => query.lexical
                .take(_productionPool)
                .any((hit) => hit.index == index),
          ),
          'trainingQueryTop50' => indexes.any(
            (index) =>
                query.training.indexes.take(_productionPool).contains(index),
          ),
          'combinedRrf' => _isInCombined(query, indexes),
          'cosineGate' => _survivesGate(query, indexes),
          'finalTop15' => _rankQuery(
            query,
            pool: _productionPool,
            threshold: _defaultThreshold,
            lexicalWeight: _lexicalWeight,
            trainingWeight: _trainingWeight,
            includeTraining: true,
            ranker: 'hybrid',
          ).any((result) => result.id == id),
          'finalTop3' => _rankQuery(
            query,
            pool: _productionPool,
            threshold: _defaultThreshold,
            lexicalWeight: _lexicalWeight,
            trainingWeight: _trainingWeight,
            includeTraining: true,
            ranker: 'hybrid',
          ).take(3).any((result) => result.id == id),
          _ => false,
        };
        if (contains) {
          relevantHits++;
          queryHit = true;
        }
      }
      if (queryHit) queryHits++;
    }
    summaries[component] = {
      'queriesWithAnyExpectedCandidate': queryHits,
      'queryRecall': queryHits / data.length,
      'relevantArticleLabels': relevantTotal,
      'relevantLabelsFound': relevantHits,
      'relevantLabelRecall': relevantTotal == 0
          ? 0
          : relevantHits / relevantTotal,
    };
  }
  return summaries;
}

bool _isInCombined(
  _QueryData query,
  List<int> indexes, {
  int pool = _productionPool,
}) {
  final fused = fuseRankings([
    for (final order in query.denseOrders) order.take(pool).toList(),
    query.lexical.take(pool).map((hit) => hit.index).toList(),
    if (query.training.indexes.isNotEmpty)
      query.training.indexes.take(pool).toList(),
  ], k: _productionFusionK);
  return indexes.any((index) => fused.any((entry) => entry.index == index));
}

bool _survivesGate(
  _QueryData query,
  List<int> indexes, {
  int pool = _productionPool,
}) {
  final fused = fuseRankings([
    for (final order in query.denseOrders) order.take(pool).toList(),
    query.lexical.take(pool).map((hit) => hit.index).toList(),
    if (query.training.indexes.isNotEmpty)
      query.training.indexes.take(pool).toList(),
  ], k: _productionFusionK);
  return indexes.any(
    (index) =>
        query.bestCosine[index] >= _defaultThreshold &&
        fused.any((entry) => entry.index == index),
  );
}

Map<String, Object?> _analyzeFailures(List<_QueryData> data) {
  final categoryCounts = <String, int>{
    'candidate_generation': 0,
    'cosine_threshold_counterfactual_loss': 0,
    'ranking_failure': 0,
    'hit_at_15_but_not_top3': 0,
    'corpus_label_missing': 0,
  };
  final byLegalGroup = <String, Map<String, int>>{};
  final byLanguage = <String, Map<String, int>>{};
  final byFailure = <String, Map<String, List<String>>>{};
  final legalGroupOutcomes = <String, Map<String, Object?>>{};
  final languageOutcomes = <String, Map<String, Object?>>{};
  final labelsMissing = <String>[];
  final candidatesRejectedByGate = <String>[];
  for (final query in data) {
    final caseId = query.caseRecord['datasetId'] as String;
    final group = _legalGroup(query.caseRecord['domain'] as String);
    final language = query.caseRecord['language'] as String;
    if (query.relevantIds.any((id) => !query.indexesById.containsKey(id))) {
      labelsMissing.add(caseId);
    }
    final run = _rankQuery(
      query,
      pool: _productionPool,
      threshold: _defaultThreshold,
      lexicalWeight: _lexicalWeight,
      trainingWeight: _trainingWeight,
      includeTraining: true,
      ranker: 'hybrid',
    );
    final finalIds = run.map((result) => result.id).toSet();
    final hit15 = query.relevantIds.intersection(finalIds).isNotEmpty;
    final hit3 = query.relevantIds
        .intersection(run.take(3).map((result) => result.id).toSet())
        .isNotEmpty;
    final hit1 = run.isNotEmpty && query.relevantIds.contains(run.first.id);
    _addOutcome(
      legalGroupOutcomes,
      group,
      caseId,
      hit1: hit1,
      hit3: hit3,
      hit15: hit15,
    );
    _addOutcome(
      languageOutcomes,
      language,
      caseId,
      hit1: hit1,
      hit3: hit3,
      hit15: hit15,
    );
    if (!hit15) {
      final hasCombined = query.relevantIds.any(
        (id) => _isInCombined(query, query.indexesById[id] ?? const []),
      );
      final survives = query.relevantIds.any(
        (id) => _survivesGate(query, query.indexesById[id] ?? const []),
      );
      final wouldHitWithoutGate = _rankQuery(
        query,
        pool: _productionPool,
        threshold: -1,
        lexicalWeight: _lexicalWeight,
        trainingWeight: _trainingWeight,
        includeTraining: true,
        ranker: 'hybrid',
      ).any((result) => query.relevantIds.contains(result.id));
      if (hasCombined && !survives) candidatesRejectedByGate.add(caseId);
      final reason = !hasCombined
          ? 'candidate_generation'
          : !survives && wouldHitWithoutGate
          ? 'cosine_threshold_counterfactual_loss'
          : 'ranking_failure';
      categoryCounts[reason] = categoryCounts[reason]! + 1;
      _addFailure(byFailure, reason, caseId);
      _addGroupedFailure(byLegalGroup, group, reason);
      _addGroupedFailure(byLanguage, language, reason);
    } else if (!hit3) {
      categoryCounts['hit_at_15_but_not_top3'] =
          categoryCounts['hit_at_15_but_not_top3']! + 1;
      _addFailure(byFailure, 'hit_at_15_but_not_top3', caseId);
    }
  }
  categoryCounts['corpus_label_missing'] = labelsMissing.length;
  final failuresByPool = <String, Object?>{};
  final gateCounterfactualByPool = <String, Object?>{};
  for (final pool in [50, 100, 200, 500]) {
    final counts = <String, int>{
      'candidate_generation': 0,
      'cosine_threshold_counterfactual_loss': 0,
      'ranking_failure': 0,
    };
    final idsByCause = <String, List<String>>{};
    final gateRescued = <String>[];
    final gateHarmed = <String>[];
    for (final query in data) {
      final run = _rankQuery(
        query,
        pool: pool,
        threshold: _defaultThreshold,
        lexicalWeight: _lexicalWeight,
        trainingWeight: _trainingWeight,
        includeTraining: true,
        ranker: 'hybrid',
      );
      final hit15 = run.any((result) => query.relevantIds.contains(result.id));
      final withoutGate = _rankQuery(
        query,
        pool: pool,
        threshold: -1,
        lexicalWeight: _lexicalWeight,
        trainingWeight: _trainingWeight,
        includeTraining: true,
        ranker: 'hybrid',
      );
      final wouldHitWithoutGate = withoutGate.any(
        (result) => query.relevantIds.contains(result.id),
      );
      final caseId = query.caseRecord['datasetId'] as String;
      if (hit15 && !wouldHitWithoutGate) gateRescued.add(caseId);
      if (!hit15 && wouldHitWithoutGate) gateHarmed.add(caseId);
      if (hit15) continue;
      final hasCandidate = query.relevantIds.any(
        (id) =>
            _isInCombined(query, query.indexesById[id] ?? const [], pool: pool),
      );
      final survives = query.relevantIds.any(
        (id) =>
            _survivesGate(query, query.indexesById[id] ?? const [], pool: pool),
      );
      final cause = !hasCandidate
          ? 'candidate_generation'
          : !survives && wouldHitWithoutGate
          ? 'cosine_threshold_counterfactual_loss'
          : 'ranking_failure';
      counts[cause] = counts[cause]! + 1;
      (idsByCause[cause] ??= <String>[]).add(
        query.caseRecord['datasetId'] as String,
      );
    }
    failuresByPool['$pool'] = {
      'failureCounts': counts,
      'failedCaseIdsByCause': idsByCause,
    };
    gateCounterfactualByPool['$pool'] = {
      'queriesRescuedByGate': gateRescued,
      'queriesHarmedByGate': gateHarmed,
      'baselineHitAt15': data
          .where(
            (query) => _rankQuery(
              query,
              pool: pool,
              threshold: _defaultThreshold,
              lexicalWeight: _lexicalWeight,
              trainingWeight: _trainingWeight,
              includeTraining: true,
              ranker: 'hybrid',
            ).any((result) => query.relevantIds.contains(result.id)),
          )
          .length,
      'noGateHitAt15': data
          .where(
            (query) => _rankQuery(
              query,
              pool: pool,
              threshold: -1,
              lexicalWeight: _lexicalWeight,
              trainingWeight: _trainingWeight,
              includeTraining: true,
              ranker: 'hybrid',
            ).any((result) => query.relevantIds.contains(result.id)),
          )
          .length,
    };
  }
  return {
    'failureCounts': categoryCounts,
    'failedCaseIdsByCause': byFailure,
    'failedQueriesByLegalGroup': byLegalGroup,
    'failedQueriesByLanguage': byLanguage,
    'performanceByLegalGroup': legalGroupOutcomes,
    'performanceByLanguage': languageOutcomes,
    'failureAttributionByCandidatePool': failuresByPool,
    'cosineGateCounterfactualByCandidatePool': gateCounterfactualByPool,
    'expectedCandidatesRejectedByCosineGate': candidatesRejectedByGate,
    'expectedLabelsMissingFromCorpus': labelsMissing,
    'manualLabelReviewCaveat':
        'Retrieval evidence cannot prove an expected label is legally '
        'incorrect or complete. Missed labels and strong unlabelled neighbors '
        'are review candidates, not automatic label corrections.',
  };
}

void _addOutcome(
  Map<String, Map<String, Object?>> target,
  String group,
  String caseId, {
  required bool hit1,
  required bool hit3,
  required bool hit15,
}) {
  final metrics = target.putIfAbsent(
    group,
    () => {
      'queryCount': 0,
      'hitAt1': 0,
      'hitAt3': 0,
      'hitAt15': 0,
      'missedHitAt15CaseIds': <String>[],
      'missedHitAt3CaseIds': <String>[],
    },
  );
  metrics['queryCount'] = (metrics['queryCount'] as int) + 1;
  if (hit1) metrics['hitAt1'] = (metrics['hitAt1'] as int) + 1;
  if (hit3) {
    metrics['hitAt3'] = (metrics['hitAt3'] as int) + 1;
  } else {
    (metrics['missedHitAt3CaseIds'] as List<String>).add(caseId);
  }
  if (hit15) {
    metrics['hitAt15'] = (metrics['hitAt15'] as int) + 1;
  } else {
    (metrics['missedHitAt15CaseIds'] as List<String>).add(caseId);
  }
}

String _legalGroup(String domain) {
  if (domain.startsWith('Civil')) return 'Civil Code';
  if (domain.startsWith('Family')) return 'Family Code';
  if (domain.startsWith('Consumer')) return 'Consumer Act';
  return 'Other';
}

void _addFailure(
  Map<String, Map<String, List<String>>> target,
  String cause,
  String caseId,
) {
  (target[cause] ??= <String, List<String>>{})
      .putIfAbsent('caseIds', () => <String>[])
      .add(caseId);
}

void _addGroupedFailure(
  Map<String, Map<String, int>> target,
  String group,
  String cause,
) {
  final counts = target.putIfAbsent(group, () => <String, int>{});
  counts[cause] = (counts[cause] ?? 0) + 1;
}

Map<String, Object?> _auditAssets({
  required List<CatalystLegalArticle> articles,
  required List<int> owners,
  required SentencePieceTokenizer chunkTokenizer,
  required Float32List chunkEmbeddings,
  required Map<String, dynamic> trainingLabels,
  required List<_TrainingExample> trainingExamples,
  required Float32List trainingEmbeddings,
  required List<Map<String, dynamic>> cases,
}) {
  final articleIds = <String, List<int>>{};
  for (var index = 0; index < articles.length; index++) {
    final article = articles[index];
    articleIds
        .putIfAbsent(
          normalizedArticleId(article.law, article.article),
          () => <int>[],
        )
        .add(index);
  }
  final duplicateIds = [
    for (final entry in articleIds.entries)
      if (entry.value.length > 1)
        {
          'articleId': entry.key,
          'firstIndex': entry.value.first,
          'duplicateIndexes': entry.value,
          'articleNumbers': [
            for (final index in entry.value) articles[index].article,
          ],
          'titles': [for (final index in entry.value) articles[index].title],
          'chapterTitles': [
            for (final index in entry.value) articles[index].chapterTitle,
          ],
          'articleTextsIdentical':
              entry.value
                  .map((index) => articles[index].articleText)
                  .toSet()
                  .length ==
              1,
          'articleTextPreviews': [
            for (final index in entry.value)
              articles[index].articleText
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .substring(
                    0,
                    math.min(
                      180,
                      articles[index].articleText
                          .replaceAll(RegExp(r'\s+'), ' ')
                          .length,
                    ),
                  ),
          ],
        },
  ];
  final chunkCounts = List<int>.filled(articles.length, 0);
  for (final owner in owners) {
    if (owner < 0 || owner >= articles.length) {
      throw StateError('Chunk owner $owner is out of article range.');
    }
    chunkCounts[owner]++;
  }
  var mismatchedChunkCounts = 0;
  var chunksAbove128Tokens = 0;
  var chunksAt256TokenCap = 0;
  var maximumChunkTokenCount = 0;
  final truncatedLongArticles = <Map<String, Object?>>[];
  for (var index = 0; index < articles.length; index++) {
    final words = articles[index].articleText
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList(growable: false);
    final chunks = <String>[];
    if (words.length <= 75) {
      chunks.add(words.join(' '));
    } else {
      for (
        var start = 0;
        start < words.length && start < 40 * 12;
        start += 40
      ) {
        final end = math.min(start + 60, words.length);
        chunks.add(words.sublist(start, end).join(' '));
        if (end == words.length) break;
      }
    }
    if (chunks.length != chunkCounts[index]) mismatchedChunkCounts++;
    for (final chunk in chunks) {
      final tokenCount = chunkTokenizer.encode('passage: $chunk').ids.length;
      maximumChunkTokenCount = math.max(maximumChunkTokenCount, tokenCount);
      if (tokenCount > 128) chunksAbove128Tokens++;
      if (tokenCount == 256) chunksAt256TokenCap++;
    }
    if (words.length > 500) {
      truncatedLongArticles.add({
        'articleIndex': index,
        'articleId': normalizedArticleId(
          articles[index].law,
          articles[index].article,
        ),
        'wordCount': words.length,
        'chunkCount': chunkCounts[index],
        'approxWordsCovered': 500,
      });
    }
  }
  final expectedIds = {
    for (final item in cases)
      ...(item['reviewedRelevantArticleIds'] as List).cast<String>(),
  };
  final missingExpectedIds =
      expectedIds.where((id) => !articleIds.containsKey(id)).toList()..sort();
  final emptyChunkArticles = [
    for (var index = 0; index < chunkCounts.length; index++)
      if (chunkCounts[index] == 0) index,
  ];
  final positiveIndexes = <int>{};
  final negativeIndexes = <int>{};
  var trainingConflicts = 0;
  for (final example in trainingExamples) {
    positiveIndexes.addAll(example.positive);
    negativeIndexes.addAll(example.negative);
    if (example.positive
        .toSet()
        .intersection(example.negative.toSet())
        .isNotEmpty) {
      trainingConflicts++;
    }
  }
  final chunkNorm = _normStats(chunkEmbeddings, owners.length);
  final trainingNorm = _normStats(trainingEmbeddings, trainingExamples.length);
  return {
    'articleCount': articles.length,
    'chunkCount': owners.length,
    'chunkEmbeddingValues': chunkEmbeddings.length,
    'chunkEmbeddingExpectedValues': owners.length * _dimensions,
    'chunkOwnerOutOfRangeCount': 0,
    'articlesWithoutChunks': emptyChunkArticles,
    'chunkCountMismatchWithCurrentWindowRule': mismatchedChunkCounts,
    'chunkTokenization': {
      'tokenizerPath': LocalTokenizer.assetPath,
      'passagePrefix': 'passage: ',
      'maximumMeasuredTokenCountCappedAt': 256,
      'maximumChunkTokenCount': maximumChunkTokenCount,
      'chunksExceedingProductionQueryLength128': chunksAbove128Tokens,
      'chunksReaching256TokenCap': chunksAt256TokenCap,
      'note':
          'Corpus chunks were exported with a 256-token limit; query and '
          'training examples use 128. This counts source chunks before '
          'embedding and is not itself proof of a retrieval error.',
    },
    'chunkNorms': chunkNorm,
    'trainingIndex': {
      'formatVersion': trainingLabels['formatVersion'],
      'articleCountInMetadata': trainingLabels['articleCount'],
      'exampleCount': trainingExamples.length,
      'embeddingCountInMetadata': trainingLabels['embeddingCount'],
      'embeddingValues': trainingEmbeddings.length,
      'expectedEmbeddingValues': trainingExamples.length * _dimensions,
      'domainCounts': {
        for (final domain in ['civil', 'family', 'consumer'])
          domain: trainingExamples
              .where((example) => example.domain.name == domain)
              .length,
      },
      'uniquePositiveArticleIndexes': positiveIndexes.length,
      'uniqueNegativeArticleIndexes': negativeIndexes.length,
      'labelConflicts': trainingConflicts,
      'embeddingNorms': trainingNorm,
    },
    'duplicateNormalizedArticleIds': duplicateIds,
    'expectedArticleIdsMissingFromCorpus': missingExpectedIds,
    'longArticlesPastChunkWindow': {
      'maxCoveredWordsByCurrentChunkLoop': 500,
      'articleCount': truncatedLongArticles.length,
      'articles': truncatedLongArticles,
      'expectedLabelIdsInAffectedArticles': [
        for (final entry in truncatedLongArticles)
          if (expectedIds.contains(entry['articleId'])) entry['articleId'],
      ],
    },
  };
}

Map<String, Object?> _normStats(Float32List values, int rows) {
  var minimum = double.infinity;
  var maximum = 0.0;
  var maxAbsoluteUnitNormError = 0.0;
  var nonFiniteValues = 0;
  for (var row = 0; row < rows; row++) {
    var squaredNorm = 0.0;
    for (var dimension = 0; dimension < _dimensions; dimension++) {
      final value = values[row * _dimensions + dimension];
      if (!value.isFinite) {
        nonFiniteValues++;
      } else {
        squaredNorm += value * value;
      }
    }
    final norm = math.sqrt(squaredNorm);
    minimum = math.min(minimum, norm);
    maximum = math.max(maximum, norm);
    maxAbsoluteUnitNormError = math.max(
      maxAbsoluteUnitNormError,
      (norm - 1).abs(),
    );
  }
  return {
    'rowCount': rows,
    'minNorm': minimum,
    'maxNorm': maximum,
    'maxAbsoluteUnitNormError': maxAbsoluteUnitNormError,
    'nonFiniteValueCount': nonFiniteValues,
  };
}
