import 'dart:convert';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('paired retrieval evaluation with real ML Kit preprocessing', (
    tester,
  ) async {
    await tester.runAsync(_runEvaluation);
  }, timeout: const Timeout(Duration(minutes: 20)));
}

Future<void> _runEvaluation() async {
  final pairedRecords = <_PairedRecord>[];

  for (final evaluationCase in _evaluationCases) {
    final baseline = await _runRetrieval(
      evaluationCase,
      const _PassThroughPreprocessor(),
    );
    final recordingPreprocessor = _RecordingPreprocessor(
      defaultLegalQueryPreprocessor,
    );
    final assisted = await _runRetrieval(evaluationCase, recordingPreprocessor);
    pairedRecords.add(
      _PairedRecord(
        evaluationCase: evaluationCase,
        baseline: baseline,
        assisted: assisted.copyWith(
          translationOutcome: recordingPreprocessor.outcome,
        ),
      ),
    );
  }

  final report = <String, Object?>{
    'evaluation': 'CATALYST paired retrieval preprocessing evaluation',
    'labelPolicy':
        'Labels are provisional (dataset annotations plus reviewer additions '
        'checked against the corpus text), not legally verified. Metrics '
        'include only cases with a non-empty reviewedRelevantArticleIds set.',
    'queryCount': pairedRecords.length,
    'records': pairedRecords.map((record) => record.toJson()).toList(),
    'metrics': _buildMetricReport(pairedRecords),
  };
  // The JSON is test output only; no production logging or files are added.
  // ignore: avoid_print
  print('CATALYST_RETRIEVAL_EVAL_JSON ${jsonEncode(report)}');
}

Future<_RunResult> _runRetrieval(
  _EvaluationCase evaluationCase,
  LegalQueryPreprocessor preprocessor,
) async {
  final response = await LocalSemanticRetrievalService(
    queryPreprocessor: preprocessor,
  ).matchConcern(evaluationCase.query);
  return _RunResult(
    processedQuery: response.processedQuery,
    translationOutcome: 'not_applicable',
    results: response.results
        .map(
          (result) => _RetrievedArticle(
            law: result.lawName,
            article: result.articleNumber,
            text: result.articleText ?? result.description,
            similarityScore: result.matchScore,
          ),
        )
        .toList(growable: false),
  );
}

class _EvaluationCase {
  const _EvaluationCase({
    required this.datasetId,
    required this.language,
    required this.domain,
    required this.query,
    required this.candidateArticleIds,
    this.reviewedRelevantArticleIds,
  });

  final int datasetId;
  final String language;
  final String domain;
  final String query;
  final Set<String> candidateArticleIds;

  // Populate only after a reviewer confirms this query-to-label mapping.
  final Set<String>? reviewedRelevantArticleIds;

  Map<String, Object?> toJson() => {
    'datasetId': datasetId,
    'language': language,
    'domain': domain,
    'originalQuery': query,
    'candidateArticleIds': candidateArticleIds.toList()..sort(),
    'labelReviewStatus': reviewedRelevantArticleIds == null
        ? 'provisional_dataset_annotation_requires_manual_review'
        : 'provisional_labels_approved_for_descriptive_evaluation_not_legally_verified',
    'reviewedRelevantArticleIds': _sortedOrNull(reviewedRelevantArticleIds),
  };
}

class _RetrievedArticle {
  const _RetrievedArticle({
    required this.law,
    required this.article,
    required this.text,
    required this.similarityScore,
  });

  final String law;
  final String article;
  final String text;
  final double similarityScore;

  String get normalizedId => _articleId(law, article);

  Map<String, Object?> toJson() => {
    'law': law,
    'article': article,
    'normalizedId': normalizedId,
    'text': text,
    'similarityScore': similarityScore,
  };
}

class _RunResult {
  const _RunResult({
    required this.processedQuery,
    required this.translationOutcome,
    required this.results,
  });

  final String processedQuery;
  final String translationOutcome;
  final List<_RetrievedArticle> results;

  _RunResult copyWith({String? translationOutcome}) => _RunResult(
    processedQuery: processedQuery,
    translationOutcome: translationOutcome ?? this.translationOutcome,
    results: results,
  );

  Map<String, Object?> toJson() => {
    'processedQuery': processedQuery,
    'translationOutcome': translationOutcome,
    'top3': results.map((result) => result.toJson()).toList(),
  };
}

class _PairedRecord {
  const _PairedRecord({
    required this.evaluationCase,
    required this.baseline,
    required this.assisted,
  });

  final _EvaluationCase evaluationCase;
  final _RunResult baseline;
  final _RunResult assisted;

  Map<String, Object?> toJson() => {
    ...evaluationCase.toJson(),
    'baseline': baseline.toJson(),
    'translationAssisted': assisted.toJson(),
  };
}

class _RecordingPreprocessor implements LegalQueryPreprocessor {
  _RecordingPreprocessor(this.delegate);

  final LegalQueryPreprocessor delegate;
  String outcome = 'not_invoked';

  @override
  Future<String> preprocess(String query) async {
    try {
      final processedQuery = await delegate.preprocess(query);
      outcome = processedQuery.trim() == query.trim()
          ? 'unchanged'
          : 'translated';
      return processedQuery;
    } catch (error) {
      outcome = 'failed:${error.runtimeType}';
      rethrow;
    }
  }
}

class _PassThroughPreprocessor implements LegalQueryPreprocessor {
  const _PassThroughPreprocessor();

  @override
  Future<String> preprocess(String query) async => query;
}

class _MetricSummary {
  const _MetricSummary({
    required this.evaluatedQueryCount,
    required this.unreviewedQueryCount,
    required this.top1Accuracy,
    required this.hitAt3,
    required this.precisionAt3,
    required this.recallAt3,
  });

  final int evaluatedQueryCount;
  final int unreviewedQueryCount;
  final double? top1Accuracy;
  final double? hitAt3;
  final double? precisionAt3;
  final double? recallAt3;

  Map<String, Object?> toJson() => {
    'evaluatedQueryCount': evaluatedQueryCount,
    'unreviewedQueryCount': unreviewedQueryCount,
    'top1Accuracy': top1Accuracy,
    'hitAt3': hitAt3,
    'precisionAt3': precisionAt3,
    'recallAt3': recallAt3,
  };
}

Map<String, Object?> _buildMetricReport(List<_PairedRecord> records) {
  final groups = <String, List<_PairedRecord>>{
    'overall': records,
    for (final language in {'English', 'Tagalog', 'Taglish'})
      'language:$language': records
          .where((record) => record.evaluationCase.language == language)
          .toList(),
    for (final domain in {'Civil', 'Family', 'Consumer'})
      'domain:$domain': records
          .where((record) => record.evaluationCase.domain == domain)
          .toList(),
  };
  return {
    for (final entry in groups.entries)
      entry.key: _pairedMetricSummary(entry.value),
  };
}

Map<String, Object?> _pairedMetricSummary(List<_PairedRecord> records) {
  final baseline = _calculateMetrics(records, assisted: false);
  final assisted = _calculateMetrics(records, assisted: true);
  return {
    'baseline': baseline.toJson(),
    'translationAssisted': assisted.toJson(),
    'delta': {
      'top1Accuracy': _difference(assisted.top1Accuracy, baseline.top1Accuracy),
      'hitAt3': _difference(assisted.hitAt3, baseline.hitAt3),
      'precisionAt3': _difference(assisted.precisionAt3, baseline.precisionAt3),
      'recallAt3': _difference(assisted.recallAt3, baseline.recallAt3),
    },
  };
}

_MetricSummary _calculateMetrics(
  List<_PairedRecord> records, {
  required bool assisted,
}) {
  final reviewedRecords = records
      .where(
        (record) =>
            record.evaluationCase.reviewedRelevantArticleIds?.isNotEmpty ??
            false,
      )
      .toList(growable: false);
  final unreviewedCount = records.length - reviewedRecords.length;
  if (reviewedRecords.isEmpty) {
    return _MetricSummary(
      evaluatedQueryCount: 0,
      unreviewedQueryCount: unreviewedCount,
      top1Accuracy: null,
      hitAt3: null,
      precisionAt3: null,
      recallAt3: null,
    );
  }

  var top1Hits = 0;
  var hitAt3Count = 0;
  var precisionAt3Total = 0.0;
  var recallAt3Total = 0.0;
  for (final record in reviewedRecords) {
    final relevantIds = record.evaluationCase.reviewedRelevantArticleIds!;
    final result = assisted ? record.assisted : record.baseline;
    final top3Ids = result.results
        .take(3)
        .map((article) => article.normalizedId)
        .toSet();
    final top1Id = result.results.isEmpty
        ? null
        : result.results.first.normalizedId;
    if (top1Id != null && relevantIds.contains(top1Id)) {
      top1Hits++;
    }
    final relevantReturned = top3Ids.intersection(relevantIds).length;
    if (relevantReturned > 0) {
      hitAt3Count++;
    }
    precisionAt3Total += relevantReturned / 3;
    recallAt3Total += relevantReturned / relevantIds.length;
  }
  final count = reviewedRecords.length;
  return _MetricSummary(
    evaluatedQueryCount: count,
    unreviewedQueryCount: unreviewedCount,
    top1Accuracy: top1Hits / count,
    hitAt3: hitAt3Count / count,
    precisionAt3: precisionAt3Total / count,
    recallAt3: recallAt3Total / count,
  );
}

double? _difference(double? after, double? before) {
  if (after == null || before == null) {
    return null;
  }
  return after - before;
}

String _articleId(String law, String article) =>
    '${_normalize(law)}:${_normalize(article)}';

String _normalize(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

const _evaluationCases = <_EvaluationCase>[
  _EvaluationCase(
    datasetId: 1,
    language: 'English',
    domain: 'Civil',
    query: 'The landlord evicted us before our lease had ended.',
    candidateArticleIds: {
      'Civil Code:1306',
      'Civil Code:1315',
      'Civil Code:1654',
    },
    // 1654 is a dataset label; 1673 is a reviewer addition.
    reviewedRelevantArticleIds: {'civilcode:1654', 'civilcode:1673'},
  ),
  _EvaluationCase(
    datasetId: 2,
    language: 'Tagalog',
    domain: 'Civil',
    query: 'Ayaw magbayad ng utang ilang buwan na nakakalipas.',
    candidateArticleIds: {'Civil Code:1159', 'Civil Code:1169'},
    // 1159 and 1169 are dataset labels; 1953 is a reviewer addition.
    reviewedRelevantArticleIds: {
      'civilcode:1159',
      'civilcode:1169',
      'civilcode:1953',
    },
  ),
  _EvaluationCase(
    datasetId: 9,
    language: 'Taglish',
    domain: 'Civil',
    query: 'Kapatid ko sold yung lupa naming limang magkakapatid without telling us.',
    candidateArticleIds: {'Civil Code:493'},
    reviewedRelevantArticleIds: {'civilcode:493'},
  ),
  _EvaluationCase(
    datasetId: 25,
    language: 'Tagalog',
    domain: 'Consumer',
    query: 'Bumili ako ng air fryer online. Pagdating sa bahay, pagbukas ko ng box rice cooker ang laman. Nang magreklamo ako, pareho lang naman daw ng gamit sa kusina sabi ng seller.',
    candidateArticleIds: {'Consumer Act:50'},
    reviewedRelevantArticleIds: {'consumeract:50'},
  ),
  _EvaluationCase(
    datasetId: 29,
    language: 'Taglish',
    domain: 'Consumer',
    query: 'May sira yung TV na inorder ko pero ayaw na tanggapin at palitan ng seller kahit may video ng pag-unbox.',
    candidateArticleIds: {'Consumer Act:97'},
    // Dataset label used provisionally; fit of CA 97 (manufacturer liability)
    // versus CA 100 is unresolved.
    reviewedRelevantArticleIds: {'consumeract:97'},
  ),
  _EvaluationCase(
    datasetId: 35,
    language: 'Taglish',
    domain: 'Consumer',
    query: 'Bumili ako ng portable e-fan tapos ilang gamit lang ay humihina na. Ayaw tanggapin ng seller nung nirere-return ko kahit may receipt ako.',
    candidateArticleIds: {'Consumer Act:68'},
    // Dataset label used provisionally; narrative mentions no warranty.
    reviewedRelevantArticleIds: {'consumeract:68'},
  ),
  _EvaluationCase(
    datasetId: 36,
    language: 'English',
    domain: 'Consumer',
    query: 'The app says my parcel was delivered, but I never received it. The seller refuses to refund what I paid.',
    candidateArticleIds: {'Consumer Act:68'},
    // Dataset label used provisionally; CA 68 concerns warranties, not
    // non-delivery, so this case is weakly labeled.
    reviewedRelevantArticleIds: {'consumeract:68'},
  ),
  _EvaluationCase(
    datasetId: 38,
    language: 'Tagalog',
    domain: 'Family',
    query: 'Naghiwalay kami ng asawa ko pero gusto ko na sa akin lang ang anak ko.',
    candidateArticleIds: {'Family Code:209', 'Family Code:213'},
    // 213 is a dataset label; 209 is a reviewer addition.
    reviewedRelevantArticleIds: {'familycode:209', 'familycode:213'},
  ),
  _EvaluationCase(
    datasetId: 48,
    language: 'Tagalog',
    domain: 'Family',
    query: 'Kabit yung pinsan ko at may anak sila nung lalaki. May karapatan ba magmana ng ari-arian anak nila?',
    candidateArticleIds: {'Family Code:176'},
    // 176 is the dataset label; 175 is a reviewer addition.
    reviewedRelevantArticleIds: {'familycode:175', 'familycode:176'},
  ),
  _EvaluationCase(
    datasetId: 48,
    language: 'English',
    domain: 'Family',
    query: 'My cousin was the mistress, and she and the man have a child. Does their child have the right to inherit property?',
    candidateArticleIds: {'Family Code:176'},
    // English paraphrase of dataset ID 48, not workbook text.
    reviewedRelevantArticleIds: {'familycode:175', 'familycode:176'},
  ),
  _EvaluationCase(
    datasetId: 50,
    language: 'Tagalog',
    domain: 'Family',
    query: 'Pwede ba akong humingi ng child support kahit hindi kami kasal?',
    candidateArticleIds: {
      'Family Code:176',
      'Family Code:195',
      'Family Code:203',
    },
    // 176 and 195 reviewed as core; 203 (timing of demand) left out.
    reviewedRelevantArticleIds: {'familycode:176', 'familycode:195'},
  ),
];

List<String>? _sortedOrNull(Set<String>? values) =>
    values == null ? null : (values.toList()..sort());
