import 'law_match_result.dart';

class HistoryEntry {
  HistoryEntry({
    required this.concernTitle,
    required this.concernExcerpt,
    required this.matchedLawLabel,
    required this.createdAt,
    required this.isFavorite,
    required this.result,
  });

  final String concernTitle;
  final String concernExcerpt;
  final String matchedLawLabel;
  final DateTime createdAt;
  bool isFavorite;
  final LawMatchResult result;
}
