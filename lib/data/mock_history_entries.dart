import '../models/history_entry.dart';
import '../models/law_match_result.dart';

/// Preview-only history examples; these are not real user searches or advice.
final List<HistoryEntry> mockHistoryEntries = [
  HistoryEntry(
    concernTitle: 'Hiwalayan ang asawa',
    concernExcerpt: '“Gusto ko nang hiwalayan ang asawa ko...”',
    matchedLawLabel: 'Family Code Art. 55., Art. 56.,',
    createdAt: DateTime(2025, 9, 15),
    isFavorite: true,
    result: const LawMatchResult(
      lawName: 'Family Code of the Philippines',
      articleNumber: 'Article 55',
      title: 'Grounds for Annulment of Marriage',
      description: 'Preview-only history example; not a legal recommendation.',
      matchScore: 0,
      detailsReference: 'preview-family-code-article-55',
    ),
  ),
  HistoryEntry(
    concernTitle: 'Defective na phone',
    concernExcerpt: '“Bumili ako ng phone pero mabilis niyang nasira...”',
    matchedLawLabel: 'Consumer Act Art. 68',
    createdAt: DateTime(2025, 8, 15),
    isFavorite: false,
    result: const LawMatchResult(
      lawName: 'Consumer Act of the Philippines',
      articleNumber: 'Article 68',
      title: 'Defective na phone',
      description: 'Preview-only history example; not a legal recommendation.',
      matchScore: 0,
      detailsReference: 'preview-consumer-act-article-68',
    ),
  ),
  HistoryEntry(
    concernTitle: 'Tumataas na renta',
    concernExcerpt: '“Biglang tinaasan ng nagpapaupa rent ko...”',
    matchedLawLabel: 'Civil Code Art. 1308',
    createdAt: DateTime(2025, 5, 15),
    isFavorite: true,
    result: const LawMatchResult(
      lawName: 'Civil Code of the Philippines',
      articleNumber: 'Article 1308',
      title: 'Termination of Lease',
      description: 'Preview-only history example; not a legal recommendation.',
      matchScore: 0,
      detailsReference: 'preview-civil-code-article-1308',
    ),
  ),
  HistoryEntry(
    concernTitle: 'False Advertisement',
    concernExcerpt: '“May maling impormasyon sa ads...”',
    matchedLawLabel: 'Consumer Act Art. 57',
    createdAt: DateTime(2025, 4, 15),
    isFavorite: false,
    result: const LawMatchResult(
      lawName: 'Consumer Act of the Philippines',
      articleNumber: 'Article 57',
      title: 'False Advertisement',
      description: 'Preview-only history example; not a legal recommendation.',
      matchScore: 0,
      detailsReference: 'preview-consumer-act-article-57',
    ),
  ),
];
