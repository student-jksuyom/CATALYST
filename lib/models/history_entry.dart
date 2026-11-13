import 'law_match_result.dart';

class HistoryEntry {
  HistoryEntry({
    required this.concernTitle,
    required this.concernExcerpt,
    required this.matchedLawLabel,
    required this.createdAt,
    required this.isFavorite,
    LawMatchResult? result,
    List<LawMatchResult>? results,
    this.id = '',
    this.concern = '',
    this.processedQuery = '',
    this.warning = '',
    this.emptyMessage,
    this.topResultCount = 0,
  }) : results = results ?? (result == null ? [] : [result]);

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
    id: json['id'] as String,
    concern: json['concern'] as String,
    concernTitle: json['concernTitle'] as String,
    concernExcerpt: json['concernExcerpt'] as String,
    matchedLawLabel: json['matchedLawLabel'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    isFavorite: json['isFavorite'] as bool,
    results: (json['results'] as List)
        .map((value) => LawMatchResult.fromJson(value as Map<String, dynamic>))
        .toList(),
    processedQuery: json['processedQuery'] as String,
    warning: json['warning'] as String,
    emptyMessage: json['emptyMessage'] as String?,
    topResultCount: json['topResultCount'] as int,
  );

  final String id;
  final String concern;
  final String concernTitle;
  final String concernExcerpt;
  final String matchedLawLabel;
  final DateTime createdAt;
  bool isFavorite;
  final List<LawMatchResult> results;
  final String processedQuery;
  final String warning;
  final String? emptyMessage;
  final int topResultCount;

  LawMatchResult get result => results.first;

  Map<String, Object?> toJson() => {
    'id': id,
    'concern': concern,
    'concernTitle': concernTitle,
    'concernExcerpt': concernExcerpt,
    'matchedLawLabel': matchedLawLabel,
    'createdAt': createdAt.toIso8601String(),
    'isFavorite': isFavorite,
    'results': results.map((result) => result.toJson()).toList(),
    'processedQuery': processedQuery,
    'warning': warning,
    'emptyMessage': emptyMessage,
    'topResultCount': topResultCount,
  };
}
