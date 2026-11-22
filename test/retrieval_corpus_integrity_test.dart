import 'dart:convert';
import 'dart:io';

import 'package:catol/services/explanation_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('corpus citations are unique and repaired provisions stay intact', () {
    final articles = (jsonDecode(
      File('assets/data/legal_articles.json').readAsStringSync(),
    ) as List).cast<Map<String, dynamic>>();
    final byId = <String, Map<String, dynamic>>{};
    for (final article in articles) {
      final id = normalizedArticleId(
        article['Law'] as String,
        article['Article'] as String,
      );
      expect(byId.containsKey(id), isFalse, reason: 'Duplicate citation $id');
      byId[id] = article;
    }

    final civil1595 = byId['civilcode:1595']!['Article Text'] as String;
    final civil1596 = byId['civilcode:1596']!['Article Text'] as String;
    expect(
      civil1595,
      contains('the provisions of article 1596, fourth paragraph'),
    );
    expect(civil1596, startsWith('Article 1596. Where the buyer'));
    final family150 = byId['familycode:150']!['Article Text'] as String;
    expect(family150, startsWith('Art. 150.'));
    expect(family150, contains('(3) Among other ascendants and descendants'));
    expect(family150, contains('(4) Among brothers and sisters'));
    final family219 = byId['familycode:219']!['Article Text'] as String;
    expect(family219, startsWith('Art. 219.'));
    expect(family219, isNot(contains('Chapter 3.')));
  });

  test(
    'chunk ownership covers each complete article and training indexes align',
    () {
      final articles = (jsonDecode(
        File('assets/data/legal_articles.json').readAsStringSync(),
      ) as List).cast<Map<String, dynamic>>();
      final owners = (jsonDecode(
        File('assets/data/chunk_owners_e5.json').readAsStringSync(),
      ) as List).cast<int>();
      final expectedOwners = <int>[];
      for (var index = 0; index < articles.length; index++) {
        final words = (articles[index]['Article Text'] as String).trim().split(
          RegExp(r'\s+'),
        );
        if (words.length <= 75) {
          expectedOwners.add(index);
        } else {
          for (var start = 0; start < words.length; start += 40) {
            expectedOwners.add(index);
            if (start + 60 >= words.length) break;
          }
        }
      }
      expect(owners, orderedEquals(expectedOwners));
      expect(
        File('assets/data/chunk_embeddings_e5.f32').lengthSync(),
        owners.length * 384 * 4,
      );
      final labels = jsonDecode(
        File('assets/data/training_query_labels_e5.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(labels['articleCount'], articles.length);
      final examples = (labels['examples'] as List)
          .cast<Map<String, dynamic>>();
      final correctedIndex = (examples[18]['positiveArticleIndexes'] as List)
          .cast<int>()
          .single;
      final correctedArticle = articles[correctedIndex];
      expect(
        normalizedArticleId(
          correctedArticle['Law'] as String,
          correctedArticle['Article'] as String,
        ),
        'civilcode:1596',
      );
      for (final row in examples) {
        for (final key in [
          'positiveArticleIndexes',
          'negativeArticleIndexes',
        ]) {
          for (final index in (row[key] as List).cast<int>()) {
            expect(index, inInclusiveRange(0, articles.length - 1));
          }
        }
      }
    },
  );
}
