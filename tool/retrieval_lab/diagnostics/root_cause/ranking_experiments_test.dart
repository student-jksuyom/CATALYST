// Batched experiments against the production Flutter retrieval service.
//
// Run from the repository root:
//   flutter test tool/retrieval_lab/diagnostics/root_cause/ranking_experiments_test.dart
//
// Query embeddings are the saved production ONNX vectors from Stage 1 and are
// memoized by tokenizer input IDs. Each configuration therefore exercises the
// real production ranking code without rerunning ONNX inference.
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

const _directory = 'tool/retrieval_lab/diagnostics/root_cause';
const _casesPath = 'tool/retrieval_lab/diagnostics/stage1_baseline/cases.json';
const _baselinePath =
    'tool/retrieval_lab/diagnostics/stage1_baseline/report.json';
const _vectorsPath =
    'tool/retrieval_lab/diagnostics/stage1_baseline/vectors.json';
const _coownershipVectorsPath = 'test/fixtures/coownership_query_vectors.json';
const _coownershipQuery =
    'May kupa kami na minana naming magkakapatid. Ngayon nalaman ko na '
    'binenta na pala ng kuya ko yung buong lupa nang hindi namin alam o '
    'pinayagan. pwede ba niyang gawin yon?';
const _negativeQueries = <String>[
  'What is the best recipe for chicken adobo?',
  'Who won the basketball game last night?',
  'asdf qwer zxcv uiop',
  'How do I install a graphics driver on my laptop?',
  'Ano ang magandang lugar para mag-bakasyon sa Palawan?',
  'Anong oras magbubukas ang mall bukas?',
];

const _bm25Weights = [0.10, 0.15, 0.25, 0.35];
const _trainingWeights = [0.00, 0.15, 0.30, 0.45];
const _rrfConstants = [10, 20, 40, 60];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'batch rank production retrieval configurations on development cases',
    () async {
      final cases = (jsonDecode(File(_casesPath).readAsStringSync()) as List)
          .cast<Map<String, dynamic>>();
      final originalReport =
          (jsonDecode(File(_baselinePath).readAsStringSync()) as List)
              .cast<Map<String, dynamic>>()
              .where(
                (row) =>
                    row['strategy'] == 'hybrid' && row['mode'] == 'baseline',
              )
              .toList(growable: false);
      final vectors =
          (jsonDecode(
            File(_vectorsPath).readAsStringSync(),
          ) as Map<String, dynamic>).map(
            (key, value) => MapEntry(
              key,
              (value as List)
                  .cast<num>()
                  .map((number) => number.toDouble())
                  .toList(growable: false),
            ),
          );
      final encoder = _CachedEncoder(vectors);
      final configurations = _configurations();
      final baseline = configurations.firstWhere(
        (configuration) => configuration.id == 'original_production',
      );

      final warmupStopwatch = Stopwatch()..start();
      final warmup = await _evaluateQuery(cases.first, baseline, encoder);
      warmupStopwatch.stop();
      expect(warmup.ids, isNotEmpty);

      final results = <_ConfigurationResult>[];
      for (final configuration in configurations) {
        final stopwatch = Stopwatch()..start();
        final queryResults = <_QueryResult>[
          for (final item in cases)
            await _evaluateQuery(item, configuration, encoder),
        ];
        stopwatch.stop();

        final negativeStopwatch = Stopwatch()..start();
        final negativeResults = <_NegativeResult>[
          for (final query in _negativeQueries)
            await _evaluateNegative(query, configuration, encoder),
        ];
        negativeStopwatch.stop();

        results.add(
          _summarize(
            configuration: configuration,
            cases: cases,
            queryResults: queryResults,
            negativeResults: negativeResults,
            runtimeMilliseconds: stopwatch.elapsedMicroseconds / 1000,
            negativeRuntimeMilliseconds:
                negativeStopwatch.elapsedMicroseconds / 1000,
          ),
        );
      }

      final originalConfiguration = results.firstWhere(
        (result) => result.configuration.id == 'original_production',
      );
      expect(originalConfiguration.hitAt1, 11);
      expect(originalConfiguration.hitAt3, 16);
      expect(originalConfiguration.hitAt15, 20);
      for (var index = 0; index < cases.length; index++) {
        final saved = originalReport.firstWhere(
          (row) => row['datasetId'] == cases[index]['datasetId'],
        );
        expect(
          originalConfiguration.queryResults[index].ids,
          (saved['all'] as List).cast<String>(),
          reason:
              'Original production config must match Stage 1 for '
              '${cases[index]['datasetId']}.',
        );
      }

      final coownershipVectors =
          (jsonDecode(
            File(_coownershipVectorsPath).readAsStringSync(),
          ) as Map<String, dynamic>).map(
            (key, value) => MapEntry(
              key,
              (value as List)
                  .cast<num>()
                  .map((number) => number.toDouble())
                  .toList(growable: false),
            ),
          );
      final coownershipEncoder = _FixtureEncoder(coownershipVectors);
      final coownershipCompatibility = <String, bool>{};
      for (final result in results) {
        final ids = await _evaluateCoownershipRegression(
          result.configuration,
          coownershipEncoder,
        );
        coownershipCompatibility[result.configuration.id] =
            _passesCoownershipRegression(ids);
      }
      expect(
        coownershipCompatibility['original_production'],
        isTrue,
        reason: 'The compatibility fixture must pass with rollback settings.',
      );

      final developmentImprovements =
          results
              .where(
                (result) =>
                    result.hitAt3 > originalConfiguration.hitAt3 &&
                    result.hitAt1 >= originalConfiguration.hitAt1 &&
                    result.hitAt15 >= originalConfiguration.hitAt15 &&
                    result.falsePositiveQueries <=
                        originalConfiguration.falsePositiveQueries &&
                    result.negativeReturnedArticles <=
                        originalConfiguration.negativeReturnedArticles,
              )
              .toList()
            ..sort(_compareResults);
      final safeImprovements = developmentImprovements
          .where(
            (result) =>
                coownershipCompatibility[result.configuration.id] == true,
          )
          .toList();
      final developmentMetricBest = developmentImprovements.isEmpty
          ? null
          : developmentImprovements.first;
      final best = safeImprovements.isEmpty ? null : safeImprovements.first;
      final productionDefaultQueryResults = <_QueryResult>[
        for (final item in cases)
          await _evaluateProductionDefault(item, encoder),
      ];
      final productionDefaultNegativeResults = <_NegativeResult>[
        for (final query in _negativeQueries)
          await _evaluateProductionDefaultNegative(query, encoder),
      ];
      final defaultQueryMismatches = <String>[
        for (var index = 0; index < cases.length; index++)
          if (best == null ||
              !listEquals(
                productionDefaultQueryResults[index].ids,
                best.queryResults[index].ids,
              ))
            cases[index]['datasetId'] as String,
      ];
      final defaultNegativeMismatches = <String>[
        for (var index = 0; index < _negativeQueries.length; index++)
          if (best == null ||
              !listEquals(
                productionDefaultNegativeResults[index].ids,
                best.negativeResults[index].ids,
              ))
            'negative-${index + 1}',
      ];
      final productionDefaultParity = {
        'positiveTop15Matches': cases.length - defaultQueryMismatches.length,
        'positiveQueryCount': cases.length,
        'positiveMismatches': defaultQueryMismatches,
        'negativeResultsMatchSelectedConfig': defaultNegativeMismatches.isEmpty,
        'negativeProbeCount': _negativeQueries.length,
        'negativeMismatches': defaultNegativeMismatches,
      };
      expect(defaultQueryMismatches, isEmpty);
      expect(defaultNegativeMismatches, isEmpty);

      Directory(_directory).createSync(recursive: true);
      File('$_directory/ranking_experiments.csv').writeAsStringSync(
        _csv(results, originalConfiguration, coownershipCompatibility),
      );
      File('$_directory/best_configuration.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(
          _bestConfiguration(
            best: best,
            baseline: originalConfiguration,
            encoder: encoder,
            configurationCount: configurations.length,
            productionDefaultParity: productionDefaultParity,
            developmentMetricBest: developmentMetricBest,
            coownershipCompatibility: coownershipCompatibility,
          ),
        ),
      );
      File('$_directory/before_after_comparison.md').writeAsStringSync(
        _comparisonMarkdown(
          best: best,
          baseline: originalConfiguration,
          allResults: results,
          encoder: encoder,
          warmupMilliseconds: warmupStopwatch.elapsedMilliseconds,
          productionDefaultParity: productionDefaultParity,
          developmentMetricBest: developmentMetricBest,
          coownershipCompatibility: coownershipCompatibility,
        ),
      );

      expect(results.length, 256);
      expect(encoder.missingKeys, isEmpty);
      expect(
        safeImprovements,
        isNotEmpty,
        reason:
            'The measured batch should select an improvement that preserves '
            'the co-ownership regression.',
      );
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

class _Configuration {
  const _Configuration({
    required this.id,
    required this.domainIndependentTraining,
    required this.bm25Weight,
    required this.trainingWeight,
    required this.rrfK,
    required this.rankingMode,
  });

  final String id;
  final bool domainIndependentTraining;
  final double bm25Weight;
  final double trainingWeight;
  final int rrfK;
  final RetrievalRankingMode rankingMode;

  RetrievalExperimentConfig get serviceConfig => RetrievalExperimentConfig(
    domainIndependentTraining: domainIndependentTraining,
    bm25Weight: bm25Weight,
    trainingQueryWeight: trainingWeight,
    rrfK: rrfK,
    rankingMode: rankingMode,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'domainIndependentTraining': domainIndependentTraining,
    'bm25Weight': bm25Weight,
    'trainingQueryWeight': trainingWeight,
    'rrfK': rrfK,
    'rankingMode': rankingMode.name,
  };
}

class _QueryResult {
  const _QueryResult(this.datasetId, this.ids, this.relevantIds);

  final String datasetId;
  final List<String> ids;
  final Set<String> relevantIds;

  int? get firstRelevantRank {
    final index = ids.indexWhere(relevantIds.contains);
    return index < 0 ? null : index + 1;
  }

  int get relevantAt3 => ids.take(3).where(relevantIds.contains).length;
}

class _NegativeResult {
  const _NegativeResult(this.query, this.ids);

  final String query;
  final List<String> ids;
}

class _ConfigurationResult {
  const _ConfigurationResult({
    required this.configuration,
    required this.hitAt1,
    required this.hitAt3,
    required this.precisionAt3,
    required this.hitAt15,
    required this.queryResults,
    required this.falsePositiveQueries,
    required this.negativeReturnedArticles,
    required this.negativeResults,
    required this.runtimeMilliseconds,
    required this.negativeRuntimeMilliseconds,
  });

  final _Configuration configuration;
  final int hitAt1;
  final int hitAt3;
  final double precisionAt3;
  final int hitAt15;
  final List<_QueryResult> queryResults;
  final int falsePositiveQueries;
  final int negativeReturnedArticles;
  final List<_NegativeResult> negativeResults;
  final double runtimeMilliseconds;
  final double negativeRuntimeMilliseconds;
}

class _CachedEncoder implements LocalQueryEncoder {
  _CachedEncoder(this.vectors);

  final Map<String, List<double>> vectors;
  final Set<String> _usedKeys = {};
  final Set<String> missingKeys = {};
  var callCount = 0;

  int get uniqueVectorCount => _usedKeys.length;

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    callCount++;
    final key = inputIds.join(',');
    final vector = vectors[key];
    if (vector == null) {
      missingKeys.add(key);
      throw StateError('No cached Stage 1 ONNX vector for input IDs $key.');
    }
    _usedKeys.add(key);
    return vector;
  }
}

class _FixtureEncoder implements LocalQueryEncoder {
  _FixtureEncoder(this.vectors);

  final Map<String, List<double>> vectors;

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    final vector = vectors[inputIds.join(',')];
    if (vector == null) {
      throw StateError('No co-ownership fixture vector for this query.');
    }
    return vector;
  }
}

List<_Configuration> _configurations() {
  final configurations = <_Configuration>[];
  for (final domainIndependent in [false, true]) {
    for (final bm25Weight in _bm25Weights) {
      for (final trainingWeight in _trainingWeights) {
        for (final rrfK in _rrfConstants) {
          for (final rankingMode in RetrievalRankingMode.values) {
            final id = [
              domainIndependent ? 'all_domains' : 'domain_filtered',
              'bm25_${_weightId(bm25Weight)}',
              'training_${_weightId(trainingWeight)}',
              'rrf_$rrfK',
              rankingMode.name,
            ].join('__');
            configurations.add(
              _Configuration(
                id: id,
                domainIndependentTraining: domainIndependent,
                bm25Weight: bm25Weight,
                trainingWeight: trainingWeight,
                rrfK: rrfK,
                rankingMode: rankingMode,
              ),
            );
          }
        }
      }
    }
  }
  configurations.removeWhere(
    (configuration) =>
        !configuration.domainIndependentTraining &&
        configuration.bm25Weight == 0.15 &&
        configuration.trainingWeight == 0.30 &&
        configuration.rrfK == 20 &&
        configuration.rankingMode == RetrievalRankingMode.calibratedScore,
  );
  configurations.insert(
    0,
    const _Configuration(
      id: 'original_production',
      domainIndependentTraining: false,
      bm25Weight: 0.15,
      trainingWeight: 0.30,
      rrfK: 20,
      rankingMode: RetrievalRankingMode.calibratedScore,
    ),
  );
  return configurations;
}

String _weightId(double value) => value.toStringAsFixed(2).replaceAll('.', '');

Future<_QueryResult> _evaluateQuery(
  Map<String, dynamic> item,
  _Configuration configuration,
  _CachedEncoder encoder,
) async {
  final service = LocalSemanticRetrievalService(
    queryEncoder: encoder,
    queryPreprocessor: const _PassThroughPreprocessor(),
    experimentConfig: configuration.serviceConfig,
  );
  final response = await service.matchConcern(item['query'] as String);
  final ids = <String>[];
  for (final result in [...response.results, ...response.otherCandidates]) {
    final id = normalizedArticleId(result.lawName, result.articleNumber);
    if (!ids.contains(id)) ids.add(id);
  }
  return _QueryResult(
    item['datasetId'] as String,
    ids,
    (item['reviewedRelevantArticleIds'] as List).cast<String>().toSet(),
  );
}

Future<_QueryResult> _evaluateProductionDefault(
  Map<String, dynamic> item,
  _CachedEncoder encoder,
) async {
  final service = LocalSemanticRetrievalService(
    queryEncoder: encoder,
    queryPreprocessor: const _PassThroughPreprocessor(),
  );
  final response = await service.matchConcern(item['query'] as String);
  final ids = <String>[];
  for (final result in [...response.results, ...response.otherCandidates]) {
    final id = normalizedArticleId(result.lawName, result.articleNumber);
    if (!ids.contains(id)) ids.add(id);
  }
  return _QueryResult(
    item['datasetId'] as String,
    ids,
    (item['reviewedRelevantArticleIds'] as List).cast<String>().toSet(),
  );
}

Future<_NegativeResult> _evaluateNegative(
  String query,
  _Configuration configuration,
  _CachedEncoder encoder,
) async {
  final service = LocalSemanticRetrievalService(
    queryEncoder: encoder,
    queryPreprocessor: const _PassThroughPreprocessor(),
    experimentConfig: configuration.serviceConfig,
  );
  final response = await service.matchConcern(query);
  final ids = <String>[];
  for (final result in [...response.results, ...response.otherCandidates]) {
    final id = normalizedArticleId(result.lawName, result.articleNumber);
    if (!ids.contains(id)) ids.add(id);
  }
  return _NegativeResult(query, ids);
}

Future<_NegativeResult> _evaluateProductionDefaultNegative(
  String query,
  _CachedEncoder encoder,
) async {
  final service = LocalSemanticRetrievalService(
    queryEncoder: encoder,
    queryPreprocessor: const _PassThroughPreprocessor(),
  );
  final response = await service.matchConcern(query);
  final ids = <String>[];
  for (final result in [...response.results, ...response.otherCandidates]) {
    final id = normalizedArticleId(result.lawName, result.articleNumber);
    if (!ids.contains(id)) ids.add(id);
  }
  return _NegativeResult(query, ids);
}

Future<List<String>> _evaluateCoownershipRegression(
  _Configuration configuration,
  _FixtureEncoder encoder,
) async {
  final service = LocalSemanticRetrievalService(
    queryEncoder: encoder,
    queryPreprocessor: const _PassThroughPreprocessor(),
    experimentConfig: configuration.serviceConfig,
  );
  final response = await service.matchConcern(_coownershipQuery);
  return [
    for (final result in [...response.results, ...response.otherCandidates])
      normalizedArticleId(result.lawName, result.articleNumber),
  ];
}

bool _passesCoownershipRegression(List<String> ids) {
  final article493Rank = ids.indexOf('civilcode:493');
  final article1614Rank = ids.indexOf('civilcode:1614');
  return ids.take(3).contains('civilcode:493') &&
      ids.take(5).contains('civilcode:1623') &&
      ids.contains('civilcode:491') &&
      article1614Rank > article493Rank &&
      !ids.take(2).contains('civilcode:1607');
}

_ConfigurationResult _summarize({
  required _Configuration configuration,
  required List<Map<String, dynamic>> cases,
  required List<_QueryResult> queryResults,
  required List<_NegativeResult> negativeResults,
  required double runtimeMilliseconds,
  required double negativeRuntimeMilliseconds,
}) {
  var hitAt1 = 0;
  var hitAt3 = 0;
  var hitAt15 = 0;
  var relevantAt3 = 0;
  for (var index = 0; index < cases.length; index++) {
    final query = queryResults[index];
    if (query.firstRelevantRank == 1) hitAt1++;
    if (query.firstRelevantRank != null && query.firstRelevantRank! <= 3) {
      hitAt3++;
    }
    if (query.firstRelevantRank != null && query.firstRelevantRank! <= 15) {
      hitAt15++;
    }
    relevantAt3 += query.relevantAt3;
  }
  final falsePositiveQueries = negativeResults
      .where((result) => result.ids.isNotEmpty)
      .length;
  final negativeReturnedArticles = negativeResults.fold<int>(
    0,
    (sum, result) => sum + result.ids.length,
  );
  return _ConfigurationResult(
    configuration: configuration,
    hitAt1: hitAt1,
    hitAt3: hitAt3,
    precisionAt3: relevantAt3 / (cases.length * 3),
    hitAt15: hitAt15,
    queryResults: queryResults,
    falsePositiveQueries: falsePositiveQueries,
    negativeReturnedArticles: negativeReturnedArticles,
    negativeResults: negativeResults,
    runtimeMilliseconds: runtimeMilliseconds,
    negativeRuntimeMilliseconds: negativeRuntimeMilliseconds,
  );
}

int _compareResults(_ConfigurationResult left, _ConfigurationResult right) {
  var comparison = right.hitAt3.compareTo(left.hitAt3);
  if (comparison != 0) return comparison;
  comparison = right.hitAt1.compareTo(left.hitAt1);
  if (comparison != 0) return comparison;
  comparison = right.hitAt15.compareTo(left.hitAt15);
  if (comparison != 0) return comparison;
  comparison = right.precisionAt3.compareTo(left.precisionAt3);
  if (comparison != 0) return comparison;
  comparison = left.falsePositiveQueries.compareTo(right.falsePositiveQueries);
  if (comparison != 0) return comparison;
  comparison = left.negativeReturnedArticles.compareTo(
    right.negativeReturnedArticles,
  );
  if (comparison != 0) return comparison;
  comparison = _configurationChangeCost(left.configuration)
      .compareTo(_configurationChangeCost(right.configuration));
  return comparison != 0
      ? comparison
      : left.configuration.id.compareTo(right.configuration.id);
}

double _configurationChangeCost(_Configuration configuration) =>
    (configuration.domainIndependentTraining ? 1 : 0) +
    (configuration.bm25Weight - 0.15).abs() +
    (configuration.trainingWeight - 0.30).abs() +
    (configuration.rrfK - 20).abs() / 20 +
    (configuration.rankingMode == RetrievalRankingMode.calibratedScore ? 0 : 1);

String _csv(
  List<_ConfigurationResult> results,
  _ConfigurationResult baseline,
  Map<String, bool> coownershipCompatibility,
) {
  final lines = <String>[
    [
      'configuration_id',
      'domain_independent_training',
      'bm25_weight',
      'training_query_weight',
      'rrf_k',
      'ranking_mode',
      'hit_at_1',
      'hit_at_3',
      'precision_at_3',
      'hit_at_15',
      'false_positive_negative_queries',
      'negative_returned_articles',
      'coownership_regression_passed',
      'positive_runtime_ms',
      'negative_runtime_ms',
      'changed_query_count',
      'changed_query_rankings_json',
    ].join(','),
  ];
  for (final result in results) {
    final changes = _changedQueries(result, baseline);
    lines.add(
      [
        result.configuration.id,
        result.configuration.domainIndependentTraining,
        result.configuration.bm25Weight,
        result.configuration.trainingWeight,
        result.configuration.rrfK,
        result.configuration.rankingMode.name,
        result.hitAt1,
        result.hitAt3,
        result.precisionAt3.toStringAsFixed(6),
        result.hitAt15,
        result.falsePositiveQueries,
        result.negativeReturnedArticles,
        coownershipCompatibility[result.configuration.id],
        result.runtimeMilliseconds.toStringAsFixed(3),
        result.negativeRuntimeMilliseconds.toStringAsFixed(3),
        changes.length,
        jsonEncode(changes),
      ].map(_csvCell).join(','),
    );
  }
  return '${lines.join('\r\n')}\r\n';
}

List<Map<String, Object?>> _changedQueries(
  _ConfigurationResult result,
  _ConfigurationResult baseline,
) {
  final changes = <Map<String, Object?>>[];
  for (var index = 0; index < result.queryResults.length; index++) {
    final before = baseline.queryResults[index];
    final after = result.queryResults[index];
    if (listEquals(before.ids, after.ids)) continue;
    changes.add({
      'datasetId': after.datasetId,
      'before': before.ids,
      'after': after.ids,
      'beforeRelevantRank': before.firstRelevantRank,
      'afterRelevantRank': after.firstRelevantRank,
      'relevantArticleIds': before.relevantIds.toList()..sort(),
    });
  }
  return changes;
}

String _csvCell(Object? value) {
  final text = '$value';
  return '"${text.replaceAll('"', '""')}"';
}

Map<String, Object?> _bestConfiguration({
  required _ConfigurationResult? best,
  required _ConfigurationResult? developmentMetricBest,
  required _ConfigurationResult baseline,
  required _CachedEncoder encoder,
  required int configurationCount,
  required Map<String, Object?> productionDefaultParity,
  required Map<String, bool> coownershipCompatibility,
}) {
  if (best == null) {
    return {
      'selected': false,
      'reason':
          'No configuration improved Hit@3 without decreasing Hit@1 '
          'or Hit@15, or increasing false positives/returned articles on the '
          'six limited negative probes.',
      'configurationCount': configurationCount,
      'baseline': _resultJson(baseline),
      'productionDefaultParity': productionDefaultParity,
      'coownershipRegressionGate': _coownershipGateJson(
        developmentMetricBest,
        null,
        coownershipCompatibility,
      ),
      'cachedVectorCount': encoder.uniqueVectorCount,
      'heldoutDataUsed': false,
    };
  }
  return {
    'selected': true,
    'selectionRule':
        'Hit@3, then Hit@1, Hit@15, Precision@3; discard '
        'configurations below baseline Hit@1/Hit@15 or above baseline '
        'negative-query false positives/results, then require the existing '
        'co-ownership ranking regression to pass; break exact metric ties '
        'with the smallest change from the original settings.',
    'configurationCount': configurationCount,
    'configuration': best.configuration.toJson(),
    'metrics': _resultJson(best),
    'developmentMetricBest': developmentMetricBest == null
        ? null
        : {
            'configuration': developmentMetricBest.configuration.toJson(),
            'metrics': _resultJson(developmentMetricBest),
          },
    'coownershipRegressionGate': _coownershipGateJson(
      developmentMetricBest,
      best,
      coownershipCompatibility,
    ),
    'baseline': _resultJson(baseline),
    'delta': {
      'hitAt1': best.hitAt1 - baseline.hitAt1,
      'hitAt3': best.hitAt3 - baseline.hitAt3,
      'precisionAt3': best.precisionAt3 - baseline.precisionAt3,
      'hitAt15': best.hitAt15 - baseline.hitAt15,
      'falsePositiveNegativeQueries':
          best.falsePositiveQueries - baseline.falsePositiveQueries,
      'negativeReturnedArticles':
          best.negativeReturnedArticles - baseline.negativeReturnedArticles,
    },
    'changedQueries': _changedQueries(best, baseline),
    'negativeResults': [
      for (final result in best.negativeResults)
        {'query': result.query, 'returnedArticleIds': result.ids},
    ],
    'productionDefaultParity': productionDefaultParity,
    'runtime': {
      'positiveMilliseconds': best.runtimeMilliseconds,
      'negativeMilliseconds': best.negativeRuntimeMilliseconds,
      'cachedVectorCount': encoder.uniqueVectorCount,
      'embeddingCacheNote':
          'The cached Stage 1 ONNX vector fixture serves repeated tokenizer '
          'inputs; no ONNX inference was rerun during the batch.',
    },
    'heldoutDataUsed': false,
  };
}

Map<String, Object?> _coownershipGateJson(
  _ConfigurationResult? developmentMetricBest,
  _ConfigurationResult? selected,
  Map<String, bool> compatibility,
) => {
  'fixture': 'coownership_ranking_regression_test.dart',
  'expectedBehavior':
      'Civil Code 493 in Top 3, 1623 in Top 5, and 491 present; '
      '1614 below 493; 1607 not in Top 2.',
  'configurationsChecked': compatibility.length,
  'configurationsPassing': compatibility.values.where((value) => value).length,
  'developmentMetricBestPassed': developmentMetricBest == null
      ? null
      : compatibility[developmentMetricBest.configuration.id],
  'selectedConfigurationPassed': selected == null
      ? null
      : compatibility[selected.configuration.id],
};

Map<String, Object?> _resultJson(_ConfigurationResult result) => {
  'hitAt1': result.hitAt1,
  'hitAt3': result.hitAt3,
  'precisionAt3': result.precisionAt3,
  'hitAt15': result.hitAt15,
  'falsePositiveNegativeQueries': result.falsePositiveQueries,
  'negativeReturnedArticles': result.negativeReturnedArticles,
  'positiveRuntimeMilliseconds': result.runtimeMilliseconds,
  'negativeRuntimeMilliseconds': result.negativeRuntimeMilliseconds,
};

String _comparisonMarkdown({
  required _ConfigurationResult? best,
  required _ConfigurationResult? developmentMetricBest,
  required _ConfigurationResult baseline,
  required List<_ConfigurationResult> allResults,
  required _CachedEncoder encoder,
  required int warmupMilliseconds,
  required Map<String, Object?> productionDefaultParity,
  required Map<String, bool> coownershipCompatibility,
}) {
  final buffer = StringBuffer()
    ..writeln('# Retrieval ranking experiment: before and after')
    ..writeln()
    ..writeln('## Scope')
    ..writeln()
    ..writeln(
      'Ran ${allResults.length} configurations through '
      '`LocalSemanticRetrievalService` on the 46 Stage 1 development '
      'queries and six existing off-topic probes. No held-out evaluation '
      'data was read. The query encoder used the saved Stage 1 ONNX vectors '
      'cached by token IDs; it did not rerun ONNX.',
    )
    ..writeln()
    ..writeln('Warm-up request: $warmupMilliseconds ms. Runtime numbers are ')
    ..writeln('host test timings, not mobile-device latency measurements.')
    ..writeln()
    ..writeln('## Selected configuration')
    ..writeln();
  if (best == null) {
    buffer
      ..writeln('No configuration passed the selection criteria.')
      ..writeln()
      ..writeln('No production change was made.');
    return buffer.toString();
  }
  final changes = _changedQueries(best, baseline);
  buffer
    ..writeln('`${best.configuration.id}`')
    ..writeln()
    ..writeln('## Existing co-ownership regression gate')
    ..writeln()
    ..writeln(
      'Checked all ${coownershipCompatibility.length} configurations against '
      'the existing co-ownership ranking regression; '
      '${coownershipCompatibility.values.where((value) => value).length} '
      'passed. The selected configuration passes.',
    );
  if (developmentMetricBest != null &&
      coownershipCompatibility[developmentMetricBest.configuration.id] !=
          true) {
    buffer
      ..writeln()
      ..writeln(
        'The highest development-metric configuration '
        '`${developmentMetricBest.configuration.id}` was not selected because '
        'it failed this existing regression.',
      );
  }
  buffer
    ..writeln()
    ..writeln('## Development metrics')
    ..writeln()
    ..writeln('| Metric | Original production | Selected | Change |')
    ..writeln('|---|---:|---:|---:|')
    ..writeln(
      '| Hit@1 | ${baseline.hitAt1}/46 | ${best.hitAt1}/46 | '
      '${_signed(best.hitAt1 - baseline.hitAt1)} |',
    )
    ..writeln(
      '| Hit@3 | ${baseline.hitAt3}/46 | ${best.hitAt3}/46 | '
      '${_signed(best.hitAt3 - baseline.hitAt3)} |',
    )
    ..writeln(
      '| Precision@3 | ${_percent(baseline.precisionAt3)} | '
      '${_percent(best.precisionAt3)} | '
      '${_signedPercentage(best.precisionAt3 - baseline.precisionAt3)} |',
    )
    ..writeln(
      '| Hit@15 | ${baseline.hitAt15}/46 | ${best.hitAt15}/46 | '
      '${_signed(best.hitAt15 - baseline.hitAt15)} |',
    )
    ..writeln(
      '| Negative probes with results | '
      '${baseline.falsePositiveQueries}/6 | '
      '${best.falsePositiveQueries}/6 | '
      '${_signed(best.falsePositiveQueries - baseline.falsePositiveQueries)} |',
    )
    ..writeln(
      '| Negative results returned | ${baseline.negativeReturnedArticles} | '
      '${best.negativeReturnedArticles} | '
      '${_signed(best.negativeReturnedArticles - baseline.negativeReturnedArticles)} |',
    )
    ..writeln()
    ..writeln('## Query ranking changes')
    ..writeln()
    ..writeln('${changes.length} of 46 query Top-15 lists changed.')
    ..writeln()
    ..writeln('| Dataset case | Relevant rank before | Relevant rank after |')
    ..writeln('|---|---:|---:|');
  for (final change in changes) {
    buffer.writeln(
      '| ${change['datasetId']} | ${change['beforeRelevantRank'] ?? 'miss'} | '
      '${change['afterRelevantRank'] ?? 'miss'} |',
    );
  }
  buffer
    ..writeln()
    ..writeln('Exact before/after article lists are included in the CSV.')
    ..writeln()
    ..writeln('## Runtime')
    ..writeln()
    ..writeln(
      '- Positive batch: ${baseline.runtimeMilliseconds.toStringAsFixed(1)} ms '
      'original; ${best.runtimeMilliseconds.toStringAsFixed(1)} ms selected.',
    )
    ..writeln(
      '- Negative probes: '
      '${baseline.negativeRuntimeMilliseconds.toStringAsFixed(1)} ms original; '
      '${best.negativeRuntimeMilliseconds.toStringAsFixed(1)} ms selected.',
    )
    ..writeln(
      '- Unique cached query vectors used: ${encoder.uniqueVectorCount}.',
    )
    ..writeln(
      '- Production service defaults matched selected Top-15 lists for '
      '${productionDefaultParity['positiveTop15Matches']}/'
      '${productionDefaultParity['positiveQueryCount']} queries and matched '
      'all ${productionDefaultParity['negativeProbeCount']} negative probes.',
    )
    ..writeln()
    ..writeln('## Negative-probe limitation')
    ..writeln()
    ..writeln(
      'The six probes are a limited safety check, not a comprehensive '
      'false-positive evaluation. No conclusion about general abstention '
      'safety follows from these results.',
    )
    ..writeln()
    ..writeln('## Production decision')
    ..writeln()
    ..writeln(
      'The selected configuration is integrated as the production default. '
      'Rollback settings remain 0.15 BM25, 0.30 training-query weight, '
      'filtered training domain, RRF k=20, and calibrated-score ranking.',
    );
  return buffer.toString();
}

String _signed(int value) => value > 0 ? '+$value' : '$value';

String _percent(double value) => '${(value * 100).toStringAsFixed(2)}%';

String _signedPercentage(double value) =>
    '${value >= 0 ? '+' : ''}${(value * 100).toStringAsFixed(2)} pp';

class _PassThroughPreprocessor implements LegalQueryPreprocessor {
  const _PassThroughPreprocessor();

  @override
  Future<String> preprocess(String query) async => query;
}
