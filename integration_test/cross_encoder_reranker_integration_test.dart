import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/local_cross_encoder_reranker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _benchmarkStart = int.fromEnvironment(
  'RERANKER_BENCHMARK_START',
  defaultValue: 0,
);
const _benchmarkCount = int.fromEnvironment(
  'RERANKER_BENCHMARK_COUNT',
  defaultValue: 46,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'selected production reranker evaluates all development queries on device',
    (tester) async {
      final fixture = (jsonDecode(
        await rootBundle.loadString(
          'integration_test/fixtures/reranker_dev46.json',
        ),
      ) as List).cast<Map<String, dynamic>>();
      expect(fixture, hasLength(46));
      expect(_benchmarkStart, inInclusiveRange(0, fixture.length - 1));
      final selectedExamples = fixture
          .skip(_benchmarkStart)
          .take(_benchmarkCount)
          .toList(growable: false);
      expect(selectedExamples, isNotEmpty);

      final reranker = _CountingCrossEncoderReranker();
      final service = LocalSemanticRetrievalService(
        crossEncoderReranker: reranker,
      );
      expect(service.experimentConfig.enableCrossEncoderReranking, isTrue);
      expect(service.experimentConfig.crossEncoderCandidateLimit, 100);
      expect(service.experimentConfig.crossEncoderWeight, 0.5);

      final rssBefore = ProcessInfo.currentRss;
      var sampledPeakRss = rssBefore;
      final memorySampler = Timer.periodic(const Duration(milliseconds: 100), (
        _,
      ) {
        final currentRss = ProcessInfo.currentRss;
        if (currentRss > sampledPeakRss) sampledPeakRss = currentRss;
      });
      final totalStopwatch = Stopwatch()..start();
      var hitAt1 = 0;
      var hitAt3 = 0;
      var hitAt15 = 0;
      var relevantAt3 = 0;
      final lawTotals = <String, int>{};
      final lawHitsAt3 = <String, int>{};
      final invalidCitations = <String>[];

      for (final example in selectedExamples) {
        final datasetId = example['datasetId'] as String;
        final query = example['query'] as String;
        final relevant = (example['relevant'] as List).cast<String>().toSet();
        final law = _lawForDatasetId(datasetId);
        final queryStopwatch = Stopwatch()..start();
        final response = await service.matchConcern(query);
        queryStopwatch.stop();

        final top15 = [
          ...response.results,
          ...response.otherCandidates,
        ].take(15).toList(growable: false);
        final ids = [
          for (final result in top15)
            normalizedArticleId(result.lawName, result.articleNumber),
        ];
        final top3 = ids.take(3).toSet();
        final hit1 = ids.isNotEmpty && relevant.contains(ids.first);
        final hit3 = top3.intersection(relevant);
        final hit15 = ids.toSet().intersection(relevant).isNotEmpty;
        if (hit1) hitAt1++;
        if (hit3.isNotEmpty) hitAt3++;
        if (hit15) hitAt15++;
        relevantAt3 += hit3.length;

        final relevantForLaw = relevant
            .where((id) => id.startsWith('$law:'))
            .toSet();
        lawTotals.update(law, (count) => count + 1, ifAbsent: () => 1);
        if (top3.intersection(relevantForLaw).isNotEmpty) {
          lawHitsAt3.update(law, (count) => count + 1, ifAbsent: () => 1);
        }

        for (final result in response.results) {
          final article = await service.lookupArticle(
            result.lawName,
            result.articleNumber,
          );
          if (article == null) {
            invalidCitations.add(
              '$datasetId:${result.lawName}:${result.articleNumber}',
            );
          }
        }

        debugPrint(
          'DEV46_QUERY ${jsonEncode({'datasetId': datasetId, 'hitAt1': hit1, 'hitAt3': hit3.length, 'hitAt15': hit15, 'latencyMs': queryStopwatch.elapsedMilliseconds})}',
        );
        debugPrint(
          'Dev46 $datasetId: ${queryStopwatch.elapsedMilliseconds}ms; '
          'reranker calls=${reranker.calls}, '
          'successes=${reranker.successes}, failures=${reranker.failures}.',
        );
      }

      totalStopwatch.stop();
      memorySampler.cancel();
      expect(invalidCitations, isEmpty);

      final denominator = selectedExamples.length;
      final metrics = <String, Object>{
        'queries': denominator,
        'queryRange': [_benchmarkStart, _benchmarkStart + denominator],
        'hitAt1': _rate(hitAt1, denominator),
        'hitAt3': _rate(hitAt3, denominator),
        'hitAt15': _rate(hitAt15, denominator),
        'precisionAt3': _rate(relevantAt3, denominator * 3),
        'perLawHitAt3': {
          for (final law in lawTotals.keys)
            law: _rate(lawHitsAt3[law] ?? 0, lawTotals[law]!),
        },
        'reranker': {
          'invocations': reranker.calls,
          'successfulQueries': reranker.successes,
          'fallbackQueries': denominator - reranker.successes,
          'failedInferences': reranker.failures,
          'totalCandidates': reranker.candidateCounts.fold<int>(
            0,
            (total, count) => total + count,
          ),
          'totalLatencyMs': reranker.latenciesMilliseconds.fold<int>(
            0,
            (total, latency) => total + latency,
          ),
          'averageLatencyMs': reranker.averageLatencyMilliseconds,
          'maximumLatencyMs': reranker.maximumLatencyMilliseconds,
        },
        'totalRuntimeMs': totalStopwatch.elapsedMilliseconds,
        'averageQueryRuntimeMs':
            totalStopwatch.elapsedMilliseconds / denominator,
        'memoryBytes': {
          'before': rssBefore,
          'sampledPeak': sampledPeakRss,
          'after': ProcessInfo.currentRss,
        },
        'invalidTop3Citations': invalidCitations.length,
      };
      final report = jsonEncode(metrics);
      debugPrint('FLUTTER_DEVICE_DEV46_METRICS $report');
      developer.log(
        'FLUTTER_DEVICE_DEV46_METRICS $report',
        name: 'catol.retrieval.benchmark',
      );

      expect(reranker.successes + reranker.failures, reranker.calls);
      expect(reranker.successes, greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

Map<String, Object> _rate(int numerator, int denominator) => {
  'hits': numerator,
  'total': denominator,
  'percent': denominator == 0 ? 0.0 : numerator * 100 / denominator,
};

String _lawForDatasetId(String datasetId) =>
    switch (datasetId.split('-').first) {
      'CC' => 'civilcode',
      'FC' => 'familycode',
      'CA' => 'consumeract',
      _ => throw FormatException('Unknown development dataset ID: $datasetId'),
    };

class _CountingCrossEncoderReranker implements ArticleCrossEncoderReranker {
  final LocalCrossEncoderReranker _delegate = LocalCrossEncoderReranker();
  final List<int> candidateCounts = [];
  final List<int> latenciesMilliseconds = [];
  int calls = 0;
  int successes = 0;
  int failures = 0;

  double get averageLatencyMilliseconds => latenciesMilliseconds.isEmpty
      ? 0
      : latenciesMilliseconds.reduce((a, b) => a + b) /
            latenciesMilliseconds.length;

  int get maximumLatencyMilliseconds => latenciesMilliseconds.isEmpty
      ? 0
      : latenciesMilliseconds.reduce((a, b) => a > b ? a : b);

  @override
  Future<List<double>> score(
    String query,
    List<CrossEncoderCandidate> candidates,
  ) async {
    calls++;
    candidateCounts.add(candidates.length);
    final stopwatch = Stopwatch()..start();
    try {
      final scores = await _delegate.score(query, candidates);
      successes++;
      return scores;
    } catch (_) {
      failures++;
      rethrow;
    } finally {
      stopwatch.stop();
      latenciesMilliseconds.add(stopwatch.elapsedMilliseconds);
    }
  }
}
