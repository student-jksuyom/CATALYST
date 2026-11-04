import 'dart:math' as math;

import 'query_analysis.dart';

const _stopwords = <String>{
  'a',
  'an',
  'the',
  'and',
  'or',
  'of',
  'to',
  'in',
  'on',
  'at',
  'by',
  'for',
  'with',
  'from',
  'as',
  'is',
  'are',
  'was',
  'were',
  'be',
  'been',
  'being',
  'it',
  'its',
  'this',
  'that',
  'these',
  'those',
  'which',
  'who',
  'whom',
  'shall',
  'may',
  'can',
  'could',
  'would',
  'should',
  'will',
  'has',
  'have',
  'had',
  'do',
  'does',
  'did',
  'if',
  'but',
  'than',
  'then',
  'so',
  'such',
  'any',
  'all',
  'his',
  'her',
  'their',
  'our',
  'my',
  'your',
  'he',
  'she',
  'they',
  'we',
  'you',
  'i',
  'me',
  'us',
  'them',
  'him',
  'not',
  'no',
  'nor',
  'upon',
  'into',
  'under',
  'over',
  'between',
  'other',
  'only',
  'also',
  'article',
  'art',
  'ang',
  'ng',
  'sa',
  'na',
  'mga',
  'ko',
  'mo',
  'yung',
  'ay',
  'pa',
  'po',
  'ba',
  'lang',
  'naman',
  'kasi',
  'pero',
  'kahit',
  'si',
  'ni',
  'kay',
  'din',
  'rin',
  'daw',
  'raw',
  'mayroon',
};

String stemToken(String word) {
  if (word.length > 4 && word.endsWith('ies')) {
    return '${word.substring(0, word.length - 3)}y';
  }
  if (word.length > 5 && word.endsWith('ing')) {
    return word.substring(0, word.length - 3);
  }
  if (word.length > 4 && word.endsWith('ed')) {
    return word.substring(0, word.length - 2);
  }
  if (word.length > 4 && word.endsWith('es')) {
    return word.substring(0, word.length - 2);
  }
  if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// Stemmed content terms; stable across indexing and querying.
List<String> contentTerms(String text) => [
  for (final token in wordTokens(text))
    if (token.length > 1 && !_stopwords.contains(token)) stemToken(token),
];

class Bm25Index {
  Bm25Index._(
    this._postings,
    this._documentLengths,
    this._averageLength,
    this._inverseDocumentFrequency,
  );

  factory Bm25Index.build(List<String> documents) {
    final postings = <String, List<int>>{};
    final lengths = List<int>.filled(documents.length, 0);
    var totalLength = 0;
    for (var index = 0; index < documents.length; index++) {
      final counts = <String, int>{};
      final terms = contentTerms(documents[index]);
      for (final term in terms) {
        counts[term] = (counts[term] ?? 0) + 1;
      }
      lengths[index] = terms.length;
      totalLength += terms.length;
      for (final entry in counts.entries) {
        // Flattened [documentIndex, termFrequency] pairs.
        (postings[entry.key] ??= <int>[])
          ..add(index)
          ..add(entry.value);
      }
    }

    final count = documents.length;
    final idf = <String, double>{
      for (final entry in postings.entries)
        entry.key: math.log(
          1 +
              (count - entry.value.length / 2 + 0.5) /
                  (entry.value.length / 2 + 0.5),
        ),
    };
    return Bm25Index._(
      postings,
      lengths,
      count == 0 ? 0 : totalLength / count,
      idf,
    );
  }

  static const double _k1 = 1.2;
  static const double _b = 0.75;

  final Map<String, List<int>> _postings;
  final List<int> _documentLengths;
  final double _averageLength;
  final Map<String, double> _inverseDocumentFrequency;

  int get documentCount => _documentLengths.length;

  /// Terms of [query] that occur anywhere in the index.
  List<String> knownTerms(String query) => {
    for (final term in contentTerms(query))
      if (_postings.containsKey(term)) term,
  }.toList(growable: false);

  /// Documents ranked by BM25, best first. Ties keep corpus order.
  List<({int index, double score})> search(String query, {int limit = 50}) {
    final scores = <int, double>{};
    for (final term in knownTerms(query)) {
      final postings = _postings[term]!;
      final idf = _inverseDocumentFrequency[term]!;
      for (var i = 0; i < postings.length; i += 2) {
        final document = postings[i];
        final frequency = postings[i + 1];
        final normalization =
            1 - _b + _b * _documentLengths[document] / _averageLength;
        scores[document] =
            (scores[document] ?? 0) +
            idf * frequency * (_k1 + 1) / (frequency + _k1 * normalization);
      }
    }
    final ranked =
        [for (final e in scores.entries) (index: e.key, score: e.value)]
          ..sort((left, right) {
            final order = right.score.compareTo(left.score);
            return order != 0 ? order : left.index.compareTo(right.index);
          });
    return ranked.take(limit).toList(growable: false);
  }
}

/// Reciprocal Rank Fusion over best-first index lists.
List<({int index, double score})> fuseRankings(
  List<List<int>> rankedLists, {
  int k = 60,
}) {
  final fused = <int, double>{};
  for (final list in rankedLists) {
    for (var rank = 0; rank < list.length; rank++) {
      fused[list[rank]] = (fused[list[rank]] ?? 0) + 1 / (k + rank + 1);
    }
  }
  return [for (final e in fused.entries) (index: e.key, score: e.value)]
    ..sort((left, right) {
      final order = right.score.compareTo(left.score);
      return order != 0 ? order : left.index.compareTo(right.index);
    });
}
