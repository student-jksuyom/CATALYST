/// Explanation text in one language: [points] explain why the provision may
/// relate to the user's facts; [reminders] are cautions and disclaimers that
/// the screen shows separately.
class ExplanationVariant {
  const ExplanationVariant({required this.points, this.reminders = const []});

  factory ExplanationVariant.fromJson(Map<String, dynamic> json) =>
      ExplanationVariant(
        points: (json['points'] as List).cast<String>(),
        reminders: (json['reminders'] as List).cast<String>(),
      );

  final List<String> points;
  final List<String> reminders;

  Map<String, Object?> toJson() => {'points': points, 'reminders': reminders};
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
    this.contextualExplanation,
    this.hasAiExplanation = false,
    this.caseExplanationPoints,
    this.explanationVariants,
    this.defaultExplanationLanguage,
  }) : assert(matchScore >= 0 && matchScore <= 100);

  factory LawMatchResult.fromJson(Map<String, dynamic> json) => LawMatchResult(
    lawName: json['lawName'] as String,
    articleNumber: json['articleNumber'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    matchScore: (json['matchScore'] as num).toDouble(),
    detailsReference: json['detailsReference'],
    chapterTitle: json['chapterTitle'] as String?,
    articleText: json['articleText'] as String?,
    contextualExplanation: json['contextualExplanation'] as String?,
    hasAiExplanation: json['hasAiExplanation'] as bool,
    caseExplanationPoints: (json['caseExplanationPoints'] as List?)
        ?.cast<String>(),
    explanationVariants: (json['explanationVariants'] as Map<String, dynamic>?)
        ?.map(
          (key, value) => MapEntry(
            key,
            ExplanationVariant.fromJson(value as Map<String, dynamic>),
          ),
        ),
    defaultExplanationLanguage: json['defaultExplanationLanguage'] as String?,
  );

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

  /// Language-model explanation connecting this provision to the user's facts.
  final String? contextualExplanation;

  /// Whether an online model supplied a query-specific relevance explanation.
  final bool hasAiExplanation;

  /// Evidence-grounded case-specific explanation points, when available.
  final List<String>? caseExplanationPoints;

  /// Plain-language explanations keyed by language code (`en`, `taglish`,
  /// `tl`), when available.
  final Map<String, ExplanationVariant>? explanationVariants;

  /// The variant matching the language of the user's query.
  final String? defaultExplanationLanguage;

  Map<String, Object?> toJson() => {
    'lawName': lawName,
    'articleNumber': articleNumber,
    'title': title,
    'description': description,
    'matchScore': matchScore,
    'detailsReference': detailsReference,
    'chapterTitle': chapterTitle,
    'articleText': articleText,
    'contextualExplanation': contextualExplanation,
    'hasAiExplanation': hasAiExplanation,
    'caseExplanationPoints': caseExplanationPoints,
    'explanationVariants': explanationVariants?.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'defaultExplanationLanguage': defaultExplanationLanguage,
  };
}
