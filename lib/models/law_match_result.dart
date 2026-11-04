/// Explanation text in one language: [points] explain why the provision may
/// relate to the user's facts; [reminders] are cautions and disclaimers that
/// the screen shows separately.
class ExplanationVariant {
  const ExplanationVariant({required this.points, this.reminders = const []});

  final List<String> points;
  final List<String> reminders;
}

class LawMatchResult {
  const LawMatchResult({
    required this.lawName,
    required this.articleNumber,
    required this.title,
    required this.description,
    required this.matchScore,
    this.detailsReference,
    this.chapterTitle,
    this.articleText,
    this.caseExplanationPoints,
    this.explanationVariants,
    this.defaultExplanationLanguage,
  }) : assert(matchScore >= 0 && matchScore <= 100);

  final String lawName;
  final String articleNumber;
  final String title;
  final String description;

  /// A similarity score from 0 to 100, not a probability of legal correctness.
  final double matchScore;

  /// Optional identifier or payload understood by a future Law Details screen.
  final Object? detailsReference;

  /// Chapter metadata supplied by the retrieved corpus, when available.
  final String? chapterTitle;

  /// Retrieved legal provision text, when available.
  final String? articleText;

  /// Evidence-grounded case-specific explanation points, when available.
  final List<String>? caseExplanationPoints;

  /// Plain-language explanations keyed by language code (`en`, `taglish`,
  /// `tl`), when available.
  final Map<String, ExplanationVariant>? explanationVariants;

  /// The variant matching the language of the user's query.
  final String? defaultExplanationLanguage;
}
