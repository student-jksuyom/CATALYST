// Offline paired evaluation. Run from the project root:
//   flutter test tool/offline_eval/offline_eval_test.dart --dart-define=MODE=dump
//   .venv\Scripts\python tool\offline_eval\embed_ids.py
//   flutter test tool/offline_eval/offline_eval_test.dart --dart-define=MODE=eval
//
// Translation outputs are RECORDED ML Kit results from a device run
// (cases.json); ML Kit itself cannot run on the host. Embeddings come from the
// production ONNX encoder executed through onnxruntime in Python.
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

const _mode = String.fromEnvironment('MODE', defaultValue: 'eval');
const _evaluationKind = String.fromEnvironment(
  'EVALUATION_KIND',
  defaultValue: 'paired',
);
const _isHeldout = _evaluationKind == 'heldout';
const _dir = String.fromEnvironment(
  'OUTPUT_DIR',
  defaultValue: 'tool/offline_eval/out',
);
const _casesPath = String.fromEnvironment(
  'CASES_FILE',
  defaultValue: 'tool/offline_eval/cases.json',
);
const _defaultCases = _casesPath == 'tool/offline_eval/cases.json';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('offline paired evaluation ($_mode)', () async {
    final cases = (jsonDecode(File(_casesPath).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final vectors = _mode == 'eval'
        ? (jsonDecode(
            File('$_dir/vectors.json').readAsStringSync(),
          ) as Map<String, dynamic>).map(
            (key, value) => MapEntry(
              key,
              (value as List).map((e) => (e as num).toDouble()).toList(),
            ),
          )
        : <String, List<double>>{};
    final seen = <String, List<int>>{};
    final encoder = _Encoder(_mode == 'dump', vectors, seen);

    final report = <Map<String, dynamic>>[];
    final strategies = _isHeldout
        ? [CatalystRetrievalStrategy.hybrid]
        : CatalystRetrievalStrategy.values;
    for (final strategy in strategies) {
      for (final c in cases) {
        final query = c['query'] as String;
        final relevant = (c['reviewedRelevantArticleIds'] as List)
            .cast<String>()
            .toSet();
        final confirmedIrrelevant =
            (c['confirmedIrrelevantArticleIds'] as List? ?? const [])
                .cast<String>()
                .toSet();
        final translatedModes = _isHeldout ? [false] : [false, true];
        for (final translated in translatedModes) {
          final service = LocalSemanticRetrievalService(
            queryEncoder: encoder,
            queryPreprocessor: translated
                ? _Fixed(c['recordedProcessedQuery'] as String)
                : const _Pass(),
            strategy: strategy,
          );
          final response = await service.matchConcern(query);
          final ids = <String>[];
          for (final r in [...response.results, ...response.otherCandidates]) {
            final id = normalizedArticleId(r.lawName, r.articleNumber);
            if (!ids.contains(id)) ids.add(id);
          }
          final top3 = ids.take(3).toList();
          final firstRelevantRank = ids.indexWhere(relevant.contains);
          final noCatalogueMatch =
              c['catalogueCoverage'] == 'NO_MATCH' && relevant.isEmpty;
          report.add({
            'strategy': strategy.name,
            'mode': translated ? 'translation' : 'baseline',
            'datasetId': c['datasetId'],
            'language': c['language'],
            'domain': c['domain'],
            if (_isHeldout) ...{
              'intendedCorpusScope': c['intendedCorpusScope'],
              'catalogueCoverage': c['catalogueCoverage'],
              'applicabilityJudgment': c['applicabilityJudgment'],
              'reviewStatus': c['reviewStatus'],
              'datasetHash': c['datasetHash'],
              'noCatalogueMatch': noCatalogueMatch,
              'falsePositiveNoMatch': noCatalogueMatch && ids.isNotEmpty,
              'confirmedIrrelevantArticleIds':
                  confirmedIrrelevant.toList()..sort(),
              'confirmedNegativeHits': ids
                  .where(confirmedIrrelevant.contains)
                  .toList(growable: false),
              'rank': firstRelevantRank < 0 ? null : firstRelevantRank + 1,
              'reciprocalRank': firstRelevantRank < 0
                  ? null
                  : 1 / (firstRelevantRank + 1),
              'hit1': firstRelevantRank == 0,
              'hit15': firstRelevantRank >= 0 && firstRelevantRank < 15,
            },
            'query': query,
            'processedQuery': response.processedQuery,
            'top3': top3,
            'all': ids,
            'relevant': relevant.toList()..sort(),
            'top1': top3.isNotEmpty && relevant.contains(top3.first),
            'hit3': top3.any(relevant.contains),
            'hitAll': ids.any(relevant.contains),
            'hits': top3.where(relevant.contains).length,
            'recall3': relevant.isEmpty
                ? null
                : top3.where(relevant.contains).length / relevant.length,
          });
        }
      }
    }

    // Off-topic queries: with the default similarity floor they should return
    // few or no provisions.
    final offTopic = <Map<String, dynamic>>[];
    for (final q in const [
      'What is the best recipe for chicken adobo?',
      'Who won the basketball game last night?',
      'asdf qwer zxcv uiop',
      'How do I install a graphics driver on my laptop?',
      'Ano ang magandang lugar para mag-bakasyon sa Palawan?',
      'Anong oras magbubukas ang mall bukas?',
    ]) {
      final response = await LocalSemanticRetrievalService(
        queryEncoder: encoder,
        queryPreprocessor: const _Pass(),
      ).matchConcern(q);
      offTopic.add({
        'query': q,
        'returned': response.results.length + response.otherCandidates.length,
        'clarifying': response.clarifyingQuestion != null,
      });
    }
    if (_mode == 'eval' && _defaultCases) {
      expect(offTopic.map((result) => result['returned']), everyElement(0));
      final custodyCase = report.firstWhere(
        (entry) =>
            entry['strategy'] == 'hybrid' &&
            entry['mode'] == 'baseline' &&
            entry['datasetId'].toString() == '38',
      );
      expect(custodyCase['hit3'], isTrue);
      final leaseCase = report.firstWhere(
        (entry) =>
            entry['strategy'] == 'hybrid' &&
            entry['mode'] == 'baseline' &&
            entry['datasetId'].toString() == '1',
      );
      expect(leaseCase['hitAll'], isTrue);
    }

    // Unlabelled demonstration queries: inspected by hand, not scored.
    final demo = <Map<String, dynamic>>[];
    for (final q in const [
      'Ayaw kilalanin ng dati kong partner ang mga anak nya kahit sya naman ang tunay na ama nito. Maari ko ba syang pilitin para magbigay ng support sa mga anak nya?',
      'My former partner refuses to acknowledge his children even though he is their real father. Can I force him to give support to his children?',
      'Binili ko yung phone pero sira agad kahit kakabili ko lang.',
      'Ayaw ibalik ng seller yung pera ko kahit defective yung item.',
      'Hindi ko pinirmahan yung kontrata.',
    ]) {
      final response = await LocalSemanticRetrievalService(
        queryEncoder: encoder,
        queryPreprocessor: const _Pass(),
      ).matchConcern(q);
      demo.add({
        'query': q,
        'results': [
          for (final r in [...response.results, ...response.otherCandidates])
            '${normalizedArticleId(r.lawName, r.articleNumber)} '
                '${r.matchScore.toStringAsFixed(1)}% '
                '${r.articleText!.replaceAll(RegExp(r'\s+'), ' ').padRight(70).substring(0, 70).trim()}',
        ],
      });
    }

    if (_mode == 'dump') {
      Directory(_dir).createSync(recursive: true);
      File('$_dir/ids.json').writeAsStringSync(jsonEncode(seen));
      return;
    }
    File('$_dir/report.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(report));
    File('$_dir/offtopic.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(offTopic));
    File('$_dir/demo.json')
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(demo));
  }, timeout: const Timeout(Duration(minutes: 20)));
}

class _Encoder implements LocalQueryEncoder {
  _Encoder(this.dump, this.vectors, this.seen);

  final bool dump;
  final Map<String, List<double>> vectors;
  final Map<String, List<int>> seen;

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    final key = inputIds.join(',');
    if (dump) {
      seen[key] = inputIds;
      return [1, ...List<double>.filled(383, 0)];
    }
    final vector = vectors[key];
    if (vector == null) {
      throw StateError('No precomputed embedding for $key');
    }
    return vector;
  }
}

class _Pass implements LegalQueryPreprocessor {
  const _Pass();

  @override
  Future<String> preprocess(String query) async => query;
}

class _Fixed implements LegalQueryPreprocessor {
  const _Fixed(this.text);

  final String text;

  @override
  Future<String> preprocess(String query) async => text;
}
