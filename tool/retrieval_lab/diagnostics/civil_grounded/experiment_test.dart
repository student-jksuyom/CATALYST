// Fixed ablations of the actual service, using cached production E5 vectors.
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter_test/flutter_test.dart';

const _root = 'tool/retrieval_lab/diagnostics';
const _coownership =
    'May kupa kami na minana naming magkakapatid. Ngayon nalaman ko na '
    'binenta na pala ng kuya ko yung buong lupa nang hindi namin alam o '
    'pinayagan. pwede ba niyang gawin yon?';

class _Encoder implements LocalQueryEncoder {
  const _Encoder(this.vectors);
  final Map<String, List<double>> vectors;
  @override
  Future<List<double>> encode(List<int> ids, List<int> mask) async =>
      vectors[ids.join(',')] ??
      (throw StateError('No cached E5 vector for query.'));
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();
  @override
  Future<String> preprocess(String query) async => query;
}

_Encoder _encoder(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return _Encoder(
    raw.map(
      (key, value) => MapEntry(key, [
        for (final item in value as List) (item as num).toDouble(),
      ]),
    ),
  );
}

Map<String, Object> _metrics(List<Map<String, dynamic>> rows) {
  var h1 = 0, h3 = 0, h15 = 0, p3 = 0, pre = 0, post = 0;
  var preLabels = 0, postLabels = 0;
  for (final row in rows) {
    final relevant = (row['expected'] as List).cast<String>().toSet();
    final ids = (row['ranked'] as List).cast<String>();
    bool hit(int n) => ids.take(n).any(relevant.contains);
    if (hit(1)) h1++;
    if (hit(3)) h3++;
    if (hit(15)) h15++;
    p3 += ids.take(3).where(relevant.contains).length;
    final preMatches = relevant.intersection(
      (row['combined'] as List).cast<String>().toSet(),
    );
    final postMatches = relevant.intersection(
      (row['eligible'] as List).cast<String>().toSet(),
    );
    if (preMatches.isNotEmpty) pre++;
    if (postMatches.isNotEmpty) post++;
    preLabels += preMatches.length;
    postLabels += postMatches.length;
  }
  return {
    'queries': rows.length,
    'hit1': h1,
    'hit3': h3,
    'hit15': h15,
    'precision3': p3 / (3 * rows.length),
    'preGateQueries': pre,
    'preGateLabels': preLabels,
    'postGateQueries': post,
    'postGateLabels': postLabels,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('compare fixed civil retrieval ablations', () async {
    final cases = (jsonDecode(
      File('$_root/stage1_baseline/cases.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final baseline = jsonDecode(
      File('$_root/high_accuracy/repaired_evaluation.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final previous = {
      for (final row in (baseline['rows'] as List).cast<Map<String, dynamic>>())
        row['datasetId'] as String: (row['after50'] as List)
            .cast<String>()
            .take(15)
            .toList(),
    };
    final fixture = jsonDecode(
      File('$_root/reranking/candidates.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final negatives = (fixture['negatives'] as List)
        .cast<Map<String, dynamic>>();
    final vectors = _encoder('$_root/stage1_baseline/vectors.json');
    final regressionVectors = _encoder(
      'test/fixtures/coownership_query_vectors.json',
    );
    const configs = <String, RetrievalExperimentConfig>{
      'baseline': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
      ),
      'dense_only': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: true,
        enableLexicalRetrieval: false,
        enableTrainingExampleRetrieval: false,
      ),
      'lexical_only': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: false,
        enableLexicalRetrieval: true,
        enableTrainingExampleRetrieval: false,
      ),
      'training_examples_only': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: false,
        enableLexicalRetrieval: false,
        enableTrainingExampleRetrieval: true,
      ),
      'dense_lexical': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: true,
        enableLexicalRetrieval: true,
        enableTrainingExampleRetrieval: false,
      ),
      'dense_training_examples': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: true,
        enableLexicalRetrieval: false,
        enableTrainingExampleRetrieval: true,
      ),
      'lexical_training_examples': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        bm25Weight: 0.15,
        trainingQueryWeight: 0.30,
        rrfK: 20,
        enableDenseRetrieval: false,
        enableLexicalRetrieval: true,
        enableTrainingExampleRetrieval: true,
      ),
      'no_training': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        disableTrainingSignal: true,
      ),
      'concepts': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalConceptExpansion: true,
      ),
      'chunk_top_two': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalChunkAggregation: true,
      ),
      'gate_recovery': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalGateRecovery: true,
      ),
      'overlap_reranking': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalOverlapReranking: true,
      ),
      'combined': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalConceptExpansion: true,
        experimentalChunkAggregation: true,
        experimentalGateRecovery: true,
        experimentalOverlapReranking: true,
      ),
      'combined_no_training': RetrievalExperimentConfig(
        domainIndependentTraining: true,
        experimentalConceptExpansion: true,
        experimentalChunkAggregation: true,
        experimentalGateRecovery: true,
        experimentalOverlapReranking: true,
        disableTrainingSignal: true,
      ),
    };

    Future<({List<String> ids, RetrievalDiagnosticTrace? trace, double ms})>
    run(
      String query,
      _Encoder encoder,
      RetrievalExperimentConfig config,
    ) async {
      RetrievalDiagnosticTrace? trace;
      final service = LocalSemanticRetrievalService(
        queryEncoder: encoder,
        queryPreprocessor: const _Passthrough(),
        experimentConfig: config,
        onDiagnosticTrace: (value) => trace = value,
      );
      final timer = Stopwatch()..start();
      final response = await service.matchConcern(query);
      timer.stop();
      return (
        ids: [
          for (final r in [...response.results, ...response.otherCandidates])
            normalizedArticleId(r.lawName, r.articleNumber),
        ],
        trace: trace,
        ms: timer.elapsedMicroseconds / 1000,
      );
    }

    await run(cases.first['query'] as String, vectors, configs['baseline']!);
    final output = <String, Object>{};
    for (final entry in configs.entries) {
      final rows = <Map<String, dynamic>>[];
      var milliseconds = 0.0;
      for (final item in cases) {
        final result = await run(item['query'] as String, vectors, entry.value);
        final trace = result.trace;
        if (trace == null) {
          throw StateError('No trace for ${item['datasetId']}');
        }
        final usesTrainingExamples =
            entry.value.enableTrainingExampleRetrieval &&
            !entry.value.disableTrainingSignal;
        if (!entry.value.enableDenseRetrieval) {
          expect(trace.semanticLists, isEmpty, reason: entry.key);
        }
        if (!entry.value.enableLexicalRetrieval) {
          expect(trace.lexicalIds, isEmpty, reason: entry.key);
        }
        if (!usesTrainingExamples) {
          expect(trace.trainingIds, isEmpty, reason: entry.key);
        }
        milliseconds += result.ms;
        final expected = (item['reviewedRelevantArticleIds'] as List)
            .cast<String>();
        rows.add({
          'datasetId': item['datasetId'],
          'domain': item['domain'],
          'language': item['language'],
          'expected': expected,
          'ranked': result.ids,
          'combined': trace.combinedIds,
          'eligible': trace.eligibleIds,
          'expectedDiagnostics': [
            for (final id in expected)
              {
                'id': id,
                'cosine': trace.cosines[id],
                'semanticRanks': [
                  for (final list in trace.semanticLists) list.indexOf(id) + 1,
                ],
                'bm25Rank': trace.lexicalIds.indexOf(id) + 1,
                'trainingRank': trace.trainingIds.indexOf(id) + 1,
                'preGate': trace.combinedIds.contains(id),
                'postGate': trace.eligibleIds.contains(id),
                'rank': result.ids.indexOf(id) + 1,
              },
          ],
        });
        if (entry.key == 'baseline') {
          expect(
            listEquals(result.ids, previous[item['datasetId']]),
            isTrue,
            reason: 'Baseline order mismatch for ${item['datasetId']}',
          );
        }
      }
      final negativeCounts = <int>[];
      for (final negative in negatives) {
        negativeCounts.add(
          (await run(
            negative['query'] as String,
            vectors,
            entry.value,
          )).ids.length,
        );
      }
      final co = (await run(_coownership, regressionVectors, entry.value)).ids;
      final coPass =
          co.take(3).contains('civilcode:493') &&
          co.take(5).contains('civilcode:1623') &&
          co.contains('civilcode:491') &&
          co.indexOf('civilcode:1614') > co.indexOf('civilcode:493') &&
          !co.take(2).contains('civilcode:1607');
      final byDomain = <String, Object>{};
      for (final domain in ['Civil', 'Family', 'Consumer']) {
        byDomain[domain] = _metrics(
          rows
              .where((r) => (r['domain'] as String).startsWith(domain))
              .toList(),
        );
      }
      output[entry.key] = {
        'metrics': _metrics(rows),
        'domains': byDomain,
        'negativeCounts': negativeCounts,
        'coownershipPass': coPass,
        'meanMilliseconds': milliseconds / cases.length,
        'rows': rows,
      };
    }
    final base = output['baseline'] as Map<String, Object>;
    expect((base['metrics'] as Map)['hit3'], 17);
    expect((base['metrics'] as Map)['hit1'], 13);
    expect((base['metrics'] as Map)['hit15'], 21);
    expect(
      (base['metrics'] as Map)['precision3'],
      closeTo(17 / (3 * cases.length), 1e-12),
    );
    expect(
      (base['negativeCounts'] as List).every((count) => count == 0),
      isTrue,
    );
    expect(base['coownershipPass'], isTrue);
    final report = {
      'configs': output,
      'currentRssBytes': ProcessInfo.currentRss,
      'maxRssBytes': ProcessInfo.maxRss,
    };
    File('$_root/civil_grounded/results.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
    debugPrint(
      const JsonEncoder.withIndent('  ').convert({
        for (final entry in output.entries)
          entry.key: {
            for (final field in (entry.value as Map<String, Object>).entries)
              if (field.key != 'rows') field.key: field.value,
          },
        'currentRssBytes': ProcessInfo.currentRss,
        'maxRssBytes': ProcessInfo.maxRss,
      }),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}
