// Tokenizes the corpus ("passage: ") and lab queries ("query: ") with the e5
// tokenizer so Python can embed them. Run from the project root:
//   flutter test tool/retrieval_lab/dump_ids_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:catol/services/query_analysis.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

const _dir = 'tool/retrieval_lab';
const _model = String.fromEnvironment('MODEL', defaultValue: 'e5');
const _passagePrefix = _model == 'e5' ? 'passage: ' : '';
const _queryPrefix = _model == 'e5' ? 'query: ' : '';

void main() {
  test('dump e5 token ids', () {
    final tokenizer = HuggingFaceTokenizerLoader.fromJsonString(
      File(_model == 'e5' ? '$_dir/e5/tokenizer.json' : 'assets/models/tokenizer.json').readAsStringSync(),
    )..enableTruncation(maxLength: 256);

    final articles = jsonDecode(
      File('assets/data/legal_articles.json').readAsStringSync(),
    ) as List;
    final passages = <List<int>>[
      for (final a in articles)
        tokenizer.encode('$_passagePrefix${(a as Map)['Article Text']}').ids,
    ];

    final chunkOwner = <int>[];
    final chunks = <List<int>>[];
    for (var i = 0; i < articles.length; i++) {
      final words = ((articles[i] as Map)['Article Text'] as String)
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();
      if (words.length <= 75) {
        chunkOwner.add(i);
        chunks.add(tokenizer.encode('$_passagePrefix${words.join(' ')}').ids);
        continue;
      }
      for (var s = 0; s < words.length && s < 40 * 12; s += 40) {
        final end = s + 60 < words.length ? s + 60 : words.length;
        chunkOwner.add(i);
        chunks.add(tokenizer.encode('$_passagePrefix${words.sublist(s, end).join(' ')}').ids);
        if (end == words.length) break;
      }
    }

    final texts = <String>{};
    for (final c in (jsonDecode(
      File('tool/offline_eval/cases.json').readAsStringSync(),
    ) as List)) {
      texts
        ..add(c['query'] as String)
        ..add(c['recordedProcessedQuery'] as String);
    }
    for (final q in (jsonDecode(
      File('$_dir/extra_queries.json').readAsStringSync(),
    ) as List)) {
      texts.add(q as String);
    }
    final analyses = <String, Map<String, Object?>>{};
    for (final t in texts.toList()) {
      final a = analyzeQuery(t);
      analyses[t] = {'normalized': a.normalized, 'glossary': a.glossaryTerms};
      texts.add(a.normalized);
      if (a.glossaryQuery != null) texts.add(a.glossaryQuery!);
    }
    File('$_dir/out/analyses.json').writeAsStringSync(jsonEncode(analyses));
    final queries = {
      for (final t in texts) t: tokenizer.encode('$_queryPrefix$t').ids,
    };
    File('$_dir/out/ids_$_model.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({'passages': passages, 'queries': queries, 'chunks': chunks, 'chunkOwner': chunkOwner}));
  });
}
