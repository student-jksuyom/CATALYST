// Export candidates from the production service using cached Stage 1 vectors.
// Run: flutter test tool/retrieval_lab/diagnostics/reranking/export_candidates_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';

const _root = 'tool/retrieval_lab/diagnostics';
const _negativeQueries = [
  'What is the best recipe for chicken adobo?',
  'Who won the basketball game last night?',
  'asdf qwer zxcv uiop',
  'How do I install a graphics driver on my laptop?',
  'Ano ang magandang lugar para mag-bakasyon sa Palawan?',
  'Anong oras magbubukas ang mall bukas?',
];
const _coownership =
    'May kupa kami na minana naming magkakapatid. Ngayon nalaman ko na '
    'binenta na pala ng kuya ko yung buong lupa nang hindi namin alam o '
    'pinayagan. pwede ba niyang gawin yon?';

Map<String, List<double>> _vectors(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>).map(
      (key, value) => MapEntry(
        key,
        (value as List).cast<num>().map((v) => v.toDouble()).toList(),
      ),
    );

class _Encoder implements LocalQueryEncoder {
  const _Encoder(this.vectors);
  final Map<String, List<double>> vectors;
  @override
  Future<List<double>> encode(List<int> ids, List<int> mask) async =>
      vectors[ids.join(',')] ??
      (throw StateError('Missing cached query vector for input IDs.'));
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();
  @override
  Future<String> preprocess(String query) async => query;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('export production candidates and preserve sprint 1 baseline', () async {
    final cases = (jsonDecode(
      File('$_root/stage1_baseline/cases.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final vectors = _Encoder(_vectors('$_root/stage1_baseline/vectors.json'));
    final coownershipEncoder = _Encoder(
      _vectors('test/fixtures/coownership_query_vectors.json'),
    );
    final savedBaseline = (jsonDecode(
      File('$_root/root_cause/best_configuration.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    final changed = {
      for (final item in (savedBaseline['changedQueries'] as List))
        (item as Map<String, dynamic>)['datasetId'] as String: item['after'],
    };
    final original = {
      for (final row in (jsonDecode(
        File('$_root/stage1_baseline/report.json').readAsStringSync(),
      ) as List).cast<Map<String, dynamic>>())
        if (row['strategy'] == 'hybrid' && row['mode'] == 'baseline')
          row['datasetId'] as String: row['all'],
    };
    Future<Map<String, Object?>> retrieve(
      String query,
      LocalQueryEncoder encoder,
      int pool,
      int limit,
    ) async {
      final service = LocalSemanticRetrievalService(
        queryEncoder: encoder,
        queryPreprocessor: const _Passthrough(),
        resultLimit: limit,
        experimentConfig: RetrievalExperimentConfig(
          domainIndependentTraining: true,
          candidatePoolSize: pool,
        ),
      );
      final watch = Stopwatch()..start();
      final response = await service.matchConcern(query);
      watch.stop();
      return {
        'milliseconds': watch.elapsedMicroseconds / 1000,
        'candidates': [
          for (final result in [
            ...response.results,
            ...response.otherCandidates,
          ])
            {
              'id': normalizedArticleId(result.lawName, result.articleNumber),
              'text': result.articleText,
              'hybridScore': result.matchScore / 100,
            },
        ],
      };
    }

    final records = <Map<String, Object?>>[];
    var hit1 = 0;
    var hit3 = 0;
    var hit15 = 0;
    for (final item in cases) {
      final query = item['query'] as String;
      final base = await retrieve(query, vectors, 50, 15);
      final normal = await retrieve(query, vectors, 50, 200);
      final wide = await retrieve(query, vectors, 500, 200);
      final baselineCandidates = (base['candidates'] as List).cast<Map>();
      final ids = baselineCandidates.map((entry) => entry['id']).toList();
      final expected =
          changed[item['datasetId']] ?? original[item['datasetId']];
      expect(
        listEquals(ids, (expected as List)),
        isTrue,
        reason: 'Production baseline mismatch for ${item['datasetId']}',
      );
      final extendedIds = (normal['candidates'] as List)
          .cast<Map>()
          .take(15)
          .map((entry) => entry['id'])
          .toList();
      expect(
        listEquals(ids, extendedIds),
        isTrue,
        reason: 'Extending the result limit must preserve the baseline order.',
      );
      final labels = (item['reviewedRelevantArticleIds'] as List)
          .cast<String>();
      bool hit(int n) => ids.take(n).any(labels.contains);
      if (hit(1)) hit1++;
      if (hit(3)) hit3++;
      if (hit(15)) hit15++;
      records.add({
        'datasetId': item['datasetId'],
        'query': query,
        'relevant': labels,
        'baseline': base,
        'pool50': normal,
        'pool500': wide,
      });
    }
    expect([hit1, hit3, hit15], [13, 17, 21]);
    final negatives = <Map<String, Object?>>[];
    for (final query in _negativeQueries) {
      final base = await retrieve(query, vectors, 50, 15);
      final normal = await retrieve(query, vectors, 50, 200);
      final wide = await retrieve(query, vectors, 500, 200);
      expect(base['candidates'], isEmpty);
      expect(normal['candidates'], isEmpty);
      expect(wide['candidates'], isEmpty);
      negatives.add({
        'query': query,
        'baseline': base,
        'pool50': normal,
        'pool500': wide,
      });
    }
    final regression = {
      'query': _coownership,
      'baseline': await retrieve(_coownership, coownershipEncoder, 50, 15),
      'pool50': await retrieve(_coownership, coownershipEncoder, 50, 200),
      'pool500': await retrieve(_coownership, coownershipEncoder, 500, 200),
    };
    if (const bool.fromEnvironment(
      'WRITE_RERANKING_CANDIDATES',
      defaultValue: true,
    )) {
      File('$_root/reranking/candidates.json').writeAsStringSync(
        jsonEncode({
          'cases': records,
          'negatives': negatives,
          'coownership': regression,
        }),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
