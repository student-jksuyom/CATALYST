import '../models/law_match_result.dart';

/// Placeholder examples for screen development; these are not legal matches.
const List<LawMatchResult> mockLawMatchResults = [
  LawMatchResult(
    lawName: 'Family Code of the Philippines',
    articleNumber: 'Article 55',
    title: 'Grounds for Annulment of Marriage',
    description: 'Demo description about a spouse leaving the family for an extended period.',
    matchScore: 97,
    detailsReference: 'demo-family-code-article-55',
  ),
  LawMatchResult(
    lawName: 'Family Code of the Philippines',
    articleNumber: 'Article 56',
    title: 'Legal Separation',
    description:
        'Demo description about circumstances related to legal separation.',
    matchScore: 78,
    detailsReference: 'demo-family-code-article-56',
  ),
  LawMatchResult(
    lawName: 'Civil Code of the Philippines',
    articleNumber: 'Article 1308',
    title: 'Termination of Lease',
    description:
        'Demo description about lease or rental agreement circumstances.',
    matchScore: 64,
    detailsReference: 'demo-civil-code-article-1308',
  ),
];
