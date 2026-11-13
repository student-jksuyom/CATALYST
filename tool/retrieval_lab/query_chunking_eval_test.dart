// Development-only paired experiment. The production retrieval service and
// packaged assets are read unchanged; output is isolated under offline_eval.
//
// Run from the repository root:
//   .venv\Scripts\python tool\offline_eval\export_evaluation_cases.py --dataset DATA\Datasets\Evaluationdataset.xlsx --output tool\offline_eval\out\query_chunking\cases.json
//   flutter test tool\retrieval_lab\query_chunking_eval_test.dart --dart-define=MODE=dump
//   .venv\Scripts\python tool\offline_eval\embed_ids.py --output-dir tool\offline_eval\out\query_chunking
//   flutter test tool\retrieval_lab\query_chunking_eval_test.dart --dart-define=MODE=eval
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _mode = String.fromEnvironment('MODE', defaultValue: 'eval');
const _directory = 'tool/offline_eval/out/query_chunking';

class _Segmentation {
  const _Segmentation(this.sentences, this.focusIndex, this.hasQuestion);

  final List<String> sentences;
  final int focusIndex;
  final bool hasQuestion;

  String get focus => sentences[focusIndex];

  String get withPrevious {
    return sentences
        .sublist(focusIndex > 0 ? focusIndex - 1 : focusIndex, focusIndex + 1)
        .join(' ');
  }
}

_Segmentation _segment(String text) {
  final sentences = <String>[];
  final boundary = RegExp(r'[.!?]+(?=\s|$)');
  var start = 0;
  for (final match in boundary.allMatches(text)) {
    final sentence = text.substring(start, match.end).trim();
    if (sentence.isNotEmpty) sentences.add(sentence);
    start = match.end;
  }
  final remaining = text.substring(start).trim();
  if (remaining.isNotEmpty) sentences.add(remaining);
  if (sentences.isEmpty) throw ArgumentError('The narrative is empty.');

  final index = sentences.lastIndexWhere((sentence) => sentence.endsWith('?'));
  return _Segmentation(
    sentences,
    index < 0 ? sentences.length - 1 : index,
    index >= 0,
  );
}

List<String> _ids(CatalystMatchResponse response) {
  final seen = <String>{};
  return [
    for (final result in [...response.results, ...response.otherCandidates])
      if (seen.add(normalizedArticleId(result.lawName, result.articleNumber)))
        normalizedArticleId(result.lawName, result.articleNumber),
  ];
}

List<String> _fuse(List<String> full, List<String> focused) {
  if (full.isEmpty) return [];
  final scores = <String, double>{};
  for (final ranking in [full, focused]) {
    for (var index = 0; index < ranking.length; index++) {
      final id = ranking[index];
      scores[id] = (scores[id] ?? 0) + 1 / (20 + index + 1);
    }
  }
  final order = scores.keys.toList()
    ..sort((left, right) {
      final comparison = scores[right]!.compareTo(scores[left]!);
      if (comparison != 0) return comparison;
      return left.compareTo(right);
    });
  return order.take(15).toList(growable: false);
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
      throw StateError('Missing precomputed query embedding.');
    }
    return vector;
  }
}

class _PassThrough implements LegalQueryPreprocessor {
  const _PassThrough();

  @override
  Future<String> preprocess(String query) async => query;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('segments questions and retains the preceding statement', () {
    final segmented = _segment(
      'I bought a phone. It broke. Can I get a refund?',
    );
    expect(segmented.sentences, hasLength(3));
    expect(segmented.focus, 'Can I get a refund?');
    expect(segmented.withPrevious, 'It broke. Can I get a refund?');
    expect(_segment('My seller refuses a refund.').hasQuestion, isFalse);
    expect(_segment('Why? What next?').focus, 'What next?');
    expect(_segment('I bought it. It broke.').focus, 'It broke.');
  });

  test('fusion requires a result from the full narrative', () {
    expect(_fuse([], ['civilcode:1']), isEmpty);
    expect(_fuse(['a', 'b'], ['b', 'c']).first, 'b');
  });

  test('paired development retrieval evaluation ($_mode)', () async {
    final cases = (jsonDecode(
      File('$_directory/cases.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final pilot = (jsonDecode(
      File('tool/offline_eval/cases.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final previous = (jsonDecode(
      File('tool/offline_eval/out/current_app_eval/report.json')
          .readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final expected = <String, List<String>>{
      for (final row in previous)
        if (row['strategy'] == 'hybrid' && row['mode'] == 'baseline')
          row['query'] as String: (row['all'] as List).cast<String>(),
    };
    final vectors = _mode == 'eval'
        ? (jsonDecode(
            File('$_directory/vectors.json').readAsStringSync(),
          ) as Map<String, dynamic>).map(
            (key, value) => MapEntry(
              key,
              (value as List).map((e) => (e as num).toDouble()).toList(),
            ),
          )
        : <String, List<double>>{};
    final seen = <String, List<int>>{};
    final service = LocalSemanticRetrievalService(
      queryEncoder: _Encoder(_mode == 'dump', vectors, seen),
      queryPreprocessor: const _PassThrough(),
    );
    const probes = [
      'What is the best recipe for chicken adobo?',
      'Who won the basketball game last night?',
      'asdf qwer zxcv uiop',
      'How do I install a graphics driver on my laptop?',
      'Ano ang magandang lugar para mag-bakasyon sa Palawan?',
      'Anong oras magbubukas ang mall bukas?',
    ];
    final records = <Map<String, dynamic>>[];
    final allCases = [
      for (final entry in cases) {...entry, 'set': 'development'},
      for (final entry in pilot) {...entry, 'set': 'pilot'},
      for (final probe in probes)
        {
          'datasetId': 'off-topic',
          'set': 'off-topic',
          'language': 'unknown',
          'query': probe,
          'reviewedRelevantArticleIds': <String>[],
        },
    ];
    for (final entry in allCases) {
      final query = entry['query'] as String;
      final segment = _segment(query);
      final full = _ids(await service.matchConcern(query));
      final focused = segment.focus == query
          ? full
          : _ids(await service.matchConcern(segment.focus));
      final contextual = segment.withPrevious == query
          ? full
          : _ids(await service.matchConcern(segment.withPrevious));
      records.add({
        'datasetId': entry['datasetId'],
        'set': entry['set'],
        'language': entry['language'],
        'query': query,
        'segments': segment.sentences,
        'focusIndex': segment.focusIndex,
        'focusRule': segment.hasQuestion ? 'last_question' : 'last_sentence',
        'focusInput': segment.focus,
        'focusWithPreviousInput': segment.withPrevious,
        'relevant': entry['reviewedRelevantArticleIds'],
        'rankings': {
          'full': full,
          'focus_only': focused,
          'focus_plus_previous': contextual,
          'full_plus_focus_rrf': _fuse(full, focused),
        },
        'matchesPreviousProductionBaseline': expected.containsKey(query)
            ? listEquals(full, expected[query])
            : null,
      });
    }

    Directory(_directory).createSync(recursive: true);
    if (_mode == 'dump') {
      File('$_directory/ids.json').writeAsStringSync(jsonEncode(seen));
    } else {
      File('$_directory/report.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'description':
              'Exploratory last-question, otherwise last-sentence focus; '
              'no manual focus labels. No translation; full plus focus uses '
              'article-level RRF and may add candidates from the focus search; '
              'an empty full search suppresses the fused list.',
          'summary': _summary(records),
          'records': records,
        }),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Map<String, dynamic> _summary(List<Map<String, dynamic>> records) {
  const strategies = [
    'full',
    'focus_only',
    'focus_plus_previous',
    'full_plus_focus_rrf',
  ];
  final summary = <String, dynamic>{};
  for (final set in ['development', 'pilot', 'off-topic']) {
    final subset = records.where((record) => record['set'] == set).toList();
    final metrics = <String, dynamic>{};
    for (final strategy in strategies) {
      var hit1 = 0;
      var hit3 = 0;
      var hit15 = 0;
      var reciprocalRank = 0.0;
      var returned = 0;
      for (final record in subset) {
        final rankings = record['rankings'] as Map<String, List<String>>;
        final ranked = rankings[strategy]!;
        if (ranked.isNotEmpty) returned++;
        final relevant = (record['relevant'] as List).cast<String>().toSet();
        final first = ranked.indexWhere(relevant.contains);
        if (first < 0) continue;
        if (first == 0) hit1++;
        if (first < 3) hit3++;
        if (first < 15) hit15++;
        reciprocalRank += 1 / (first + 1);
      }
      metrics[strategy] = set == 'off-topic'
          ? {'returnedAny': returned}
          : {
              'hit1': hit1,
              'hit3': hit3,
              'hit15': hit15,
              'mrr15': subset.isEmpty ? null : reciprocalRank / subset.length,
            };
    }
    summary[set] = {
      'queryCount': subset.length,
      'focusDiffersFromFull': subset
          .where((r) => r['focusInput'] != r['query'])
          .length,
      'focusWithPreviousDiffersFromFull': subset
          .where((r) => r['focusWithPreviousInput'] != r['query'])
          .length,
      'metrics': metrics,
    };
  }
  final checked = records
      .where((record) => record['matchesPreviousProductionBaseline'] != null)
      .toList();
  summary['baselineParity'] = {
    'checked': checked.length,
    'matched': checked
        .where((record) => record['matchesPreviousProductionBaseline'] == true)
        .length,
  };
  return summary;
}
