import 'dart:convert';
import 'dart:io';

import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/lexical_index.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('export production preprocessing and BM25 inputs', () {
    final articles = (jsonDecode(
      File('assets/data/legal_articles.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final cases = (jsonDecode(
      File('tool/retrieval_lab/diagnostics/stage1_baseline/cases.json')
          .readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final probes =
        ((jsonDecode(
                  File(
                    'tool/retrieval_lab/diagnostics/reranking/candidates.json',
                  ).readAsStringSync(),
                ) as Map<String, dynamic>)['negatives']
                as List)
            .cast<Map<String, dynamic>>();
    final ids = [
      for (final article in articles)
        normalizedArticleId(
          article['Law'] as String,
          article['Article'] as String,
        ),
    ];
    expect(ids.toSet().length, articles.length);
    final lexical = Bm25Index.build([
      for (final article in articles) article['Article Text'] as String,
    ]);
    Map<String, Object?> prepare(
      Map<String, dynamic> row,
      int index,
      bool negative,
    ) {
      final query = (row['query'] as String).trim();
      final analysis = analyzeQuery(query);
      final variants = <String>{
        analysis.normalized,
        ?analysis.glossaryQuery,
      }.toList();
      final lexicalQuery = [
        query,
        query,
        ...analysis.glossaryTerms,
        ...expandLegalWording(query),
      ].join(' ');
      final matches = lexical.search(lexicalQuery, limit: 50);
      return {
        'datasetId': negative ? 'negative-$index' : row['datasetId'],
        'query': query,
        'domain': row['domain'],
        'negative': negative,
        'expected': negative ? <String>[] : row['reviewedRelevantArticleIds'],
        'variants': variants,
        'preemptiveAbstention':
            analysis.needsClarification || isClearlyOutsideCatalystScope(query),
        'lexical': [
          for (final hit in matches) {'index': hit.index, 'score': hit.score},
        ],
      };
    }

    final output = {
      'articleIds': ids,
      'articleTexts': [
        for (final article in articles) article['Article Text'] as String,
      ],
      'cases': [
        for (var i = 0; i < cases.length; i++) prepare(cases[i], i, false),
        for (var i = 0; i < probes.length; i++) prepare(probes[i], i, true),
      ],
    };
    expect(cases.length, 46);
    expect(probes.length, 6);
    File('tool/retrieval_lab/diagnostics/embedding_upgrade/inputs.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(output));
  });
}
