import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/law_match_result.dart';
import 'lexical_index.dart';

const String jurisprudenceAsset = 'assets/data/jurisprudence.json';

/// One Supreme Court decision from the bundled jurisprudence dataset.
class JurisprudenceCase {
  const JurisprudenceCase({
    required this.id,
    required this.law,
    required this.lawName,
    required this.topic,
    required this.title,
    required this.grNo,
    required this.date,
    required this.holding,
    required this.dispositive,
    required this.articles,
    required this.passages,
  });

  factory JurisprudenceCase.fromJson(Map<String, dynamic> json) {
    List<String> strings(Object? value) => [
      for (final item in (value as List? ?? const [])) item.toString(),
    ];
    return JurisprudenceCase(
      id: json['id'] as String,
      law: json['law'] as String? ?? '',
      lawName: json['lawName'] as String? ?? '',
      topic: json['topic'] as String? ?? '',
      title: json['title'] as String? ?? '',
      grNo: json['grNo'] as String? ?? '',
      date: json['date'] as String? ?? '',
      holding: json['holding'] as String? ?? '',
      dispositive: json['dispositive'] as String? ?? '',
      articles: strings(json['articles']),
      passages: strings(json['passages']),
    );
  }

  final String id;

  /// `CivilCode`, `FamilyCode` or `ConsumerAct`.
  final String law;
  final String lawName;
  final String topic;
  final String title;
  final String grNo;
  final String date;
  final String holding;
  final String dispositive;

  /// Articles of [law] the decision relies on, most cited first.
  final List<String> articles;
  final List<String> passages;

  String get citation =>
      [title, if (grNo.isNotEmpty) grNo, if (date.isNotEmpty) date].join(', ');

  String get searchText =>
      '$title $topic $lawName $holding $dispositive '
      '${passages.join(' ')}';
}

class CaseHit {
  const CaseHit({
    required this.jurisprudence,
    required this.score,
    required this.citedArticles,
  });

  final JurisprudenceCase jurisprudence;

  /// Combined rank signal in 0..1. A retrieval order, not a probability.
  final double score;

  /// Retrieved articles this decision also relies on (for example `493`).
  final List<String> citedArticles;
}

String? lawKeyOf(String lawName) {
  final name = lawName.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (name.contains('civil')) return 'CivilCode';
  if (name.contains('family')) return 'FamilyCode';
  if (name.contains('consumer')) return 'ConsumerAct';
  return null;
}

String? articleDigits(String articleNumber) =>
    RegExp(r'\d+').firstMatch(articleNumber)?.group(0);

/// Hybrid ranking of decisions: BM25 over the decision text plus an overlap
/// signal with the statute articles already retrieved from the corpus.
class JurisprudenceIndex {
  JurisprudenceIndex(List<JurisprudenceCase> cases)
    : cases = List.unmodifiable(cases),
      _bm25 = Bm25Index.build([for (final c in cases) c.searchText]);

  JurisprudenceIndex.empty() : this(const []);

  static Future<JurisprudenceIndex> load([AssetBundle? bundle]) async {
    final raw = await (bundle ?? rootBundle).loadString(jurisprudenceAsset);
    final decoded = jsonDecode(raw) as List;
    return JurisprudenceIndex([
      for (final item in decoded)
        JurisprudenceCase.fromJson(item as Map<String, dynamic>),
    ]);
  }

  static Future<JurisprudenceIndex>? _shared;

  /// Loaded once; a failed load yields an empty index and is retried later.
  static Future<JurisprudenceIndex> shared() =>
      _shared ??= load().catchError((Object _) {
        _shared = null;
        return JurisprudenceIndex.empty();
      });

  final List<JurisprudenceCase> cases;
  final Bm25Index _bm25;

  static const double _minimumScore = 0.18;

  List<CaseHit> search(
    String query, {
    List<LawMatchResult> articles = const [],
    int limit = 3,
  }) {
    if (cases.isEmpty) return const [];
    final text = [
      query,
      // English statute text bridges Tagalog or Taglish questions.
      for (final a in articles.take(3))
        (a.articleText ?? a.description).split(RegExp(r'(?<=[.;])\s')).first,
    ].join(' ');
    final lexical = {
      for (final hit in _bm25.search(text, limit: cases.length))
        hit.index: hit.score,
    };
    final top = lexical.values.fold<double>(0, (a, b) => b > a ? b : a);

    final weights = <String, double>{};
    for (final (rank, a) in articles.take(10).indexed) {
      final law = lawKeyOf(a.lawName);
      final number = articleDigits(a.articleNumber);
      if (law != null && number != null) {
        weights['$law|$number'] = rank < 3 ? 1.0 : 0.5;
      }
    }

    final hits = <CaseHit>[];
    for (var i = 0; i < cases.length; i++) {
      final c = cases[i];
      final lexicalScore = top > 0 ? (lexical[i] ?? 0) / top : 0.0;
      final cited = [
        for (final number in c.articles)
          if (weights.containsKey('${c.law}|$number')) number,
      ];
      final citeScore = cited.isEmpty
          ? 0.0
          : (cited.map((n) => weights['${c.law}|$n']!).reduce((a, b) => a + b))
                .clamp(0.0, 1.0);
      final score = 0.65 * lexicalScore + 0.35 * citeScore;
      if (score >= _minimumScore) {
        hits.add(CaseHit(jurisprudence: c, score: score, citedArticles: cited));
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList();
  }
}
