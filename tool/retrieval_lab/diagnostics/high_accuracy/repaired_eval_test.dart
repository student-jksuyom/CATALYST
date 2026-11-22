// Evaluates staged assets through the actual Flutter retrieval service.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _root = 'tool/retrieval_lab/diagnostics';
const _staged = '$_root/high_accuracy/repaired_assets';
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
      (throw StateError('Missing cached query vector.'));
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();

  @override
  Future<String> preprocess(String query) async => query;
}

_Encoder _loadEncoder(String path) {
  final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  return _Encoder(
    raw.map(
      (key, value) => MapEntry(key, [
        for (final value in value as List) (value as num).toDouble(),
      ]),
    ),
  );
}

Map<String, Object> _metrics(List<Map<String, dynamic>> rows, String key) {
  var hit1 = 0, hit3 = 0, hit15 = 0, labels3 = 0;
  var candidateQueries = 0, candidateLabels = 0;
  for (final row in rows) {
    final relevant = (row['relevant'] as List).cast<String>().toSet();
    final ids = (row[key] as List).cast<String>();
    bool hit(int n) => ids.take(n).any(relevant.contains);
    if (hit(1)) hit1++;
    if (hit(3)) hit3++;
    if (hit(15)) hit15++;
    labels3 += ids.take(3).where(relevant.contains).length;
    final matched = relevant.intersection(ids.toSet());
    if (matched.isNotEmpty) candidateQueries++;
    candidateLabels += matched.length;
  }
  return {
    'hitAt1': hit1,
    'hitAt3': hit3,
    'hitAt15': hit15,
    'precisionAt3': labels3 / (3 * rows.length),
    'gatedTop200QueriesCovered': candidateQueries,
    'gatedTop200LabelsCovered': candidateLabels,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'evaluate repaired corpus with cached production query vectors',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const stagedNames = {
        'legal_articles.json',
        'chunk_owners_e5.json',
        'chunk_embeddings_e5.f32',
        'training_query_labels_e5.json',
      };
      if (!const bool.fromEnvironment('TEST_PACKAGED_REPAIR')) {
        messenger.setMockMessageHandler('flutter/assets', (message) async {
          if (message == null) throw StateError('Missing asset message.');
          final path = utf8.decode(
            message.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          final name = path.split('/').last;
          final file = File(
            stagedNames.contains(name) ? '$_staged/$name' : path,
          );
          if (!file.existsSync()) throw StateError('Missing test asset: $path');
          return ByteData.sublistView(await file.readAsBytes());
        });
        addTearDown(
          () => messenger.setMockMessageHandler('flutter/assets', null),
        );
      }

      final fixture = jsonDecode(
        File('$_root/reranking/candidates.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
      final negatives = (fixture['negatives'] as List)
          .cast<Map<String, dynamic>>();
      final encoder = _loadEncoder('$_root/stage1_baseline/vectors.json');
      final coEncoder = _loadEncoder(
        'test/fixtures/coownership_query_vectors.json',
      );

      Future<Map<String, Object>> retrieve(
        String query,
        _Encoder enc,
        int pool,
      ) async {
        final service = LocalSemanticRetrievalService(
          queryEncoder: enc,
          queryPreprocessor: const _Passthrough(),
          resultLimit: 200,
          experimentConfig: RetrievalExperimentConfig(
            domainIndependentTraining: true,
            candidatePoolSize: pool,
          ),
        );
        final watch = Stopwatch()..start();
        final result = await service.matchConcern(query);
        watch.stop();
        return {
          'milliseconds': watch.elapsedMicroseconds / 1000,
          'ids': [
            for (final item in [...result.results, ...result.otherCandidates])
              normalizedArticleId(item.lawName, item.articleNumber),
          ],
        };
      }

      await retrieve(cases.first['query'] as String, encoder, 50);
      final rows = <Map<String, dynamic>>[];
      var ms50 = 0.0, ms500 = 0.0, oldMs50 = 0.0, oldMs500 = 0.0;
      for (final row in cases) {
        final after50 = await retrieve(row['query'] as String, encoder, 50);
        final after500 = await retrieve(row['query'] as String, encoder, 500);
        final before50 = row['pool50'] as Map<String, dynamic>;
        final before500 = row['pool500'] as Map<String, dynamic>;
        ms50 += after50['milliseconds'] as double;
        ms500 += after500['milliseconds'] as double;
        oldMs50 += (before50['milliseconds'] as num).toDouble();
        oldMs500 += (before500['milliseconds'] as num).toDouble();
        List<String> oldIds(Map<String, dynamic> data) => [
          for (final item in data['candidates'] as List)
            (item as Map<String, dynamic>)['id'] as String,
        ];
        rows.add({
          'datasetId': row['datasetId'],
          'relevant': row['relevant'],
          'before50': oldIds(before50),
          'before500': oldIds(before500),
          'after50': after50['ids'],
          'after500': after500['ids'],
        });
      }

      final negativeResults = <Map<String, Object>>[];
      for (final row in negatives) {
        final result50 = await retrieve(row['query'] as String, encoder, 50);
        final result500 = await retrieve(row['query'] as String, encoder, 500);
        negativeResults.add({
          'query': row['query'] as String,
          'pool50': (result50['ids'] as List).length,
          'pool500': (result500['ids'] as List).length,
        });
      }
      final regression50 =
          (await retrieve(_coownership, coEncoder, 50))['ids'] as List;
      final regression500 =
          (await retrieve(_coownership, coEncoder, 500))['ids'] as List;
      bool coownershipPass(List ids) =>
          ids.take(3).contains('civilcode:493') &&
          ids.take(5).contains('civilcode:1623') &&
          ids.take(15).contains('civilcode:491') &&
          ids.indexOf('civilcode:1614') > ids.indexOf('civilcode:493') &&
          !ids.take(2).contains('civilcode:1607');
      final output = {
        'before50': _metrics(rows, 'before50'),
        'after50': _metrics(rows, 'after50'),
        'before500': _metrics(rows, 'before500'),
        'after500': _metrics(rows, 'after500'),
        'meanMilliseconds': {
          'before50Historical': oldMs50 / cases.length,
          'after50': ms50 / cases.length,
          'before500Historical': oldMs500 / cases.length,
          'after500': ms500 / cases.length,
        },
        'processCurrentRssBytes': ProcessInfo.currentRss,
        'processMaxRssBytes': ProcessInfo.maxRss,
        'negativeResults': negativeResults,
        'coownershipPass50': coownershipPass(regression50),
        'coownershipPass500': coownershipPass(regression500),
        'rows': rows,
      };
      File(
        '$_root/high_accuracy/repaired_evaluation.json',
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
      debugPrint(
        const JsonEncoder.withIndent('  ').convert({
          for (final entry in output.entries)
            if (entry.key != 'rows') entry.key: entry.value,
        }),
      );
      expect(_metrics(rows, 'before50')['hitAt3'], 17);
      expect(negativeResults.every((row) => row['pool50'] == 0), isTrue);
      expect(coownershipPass(regression50), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
