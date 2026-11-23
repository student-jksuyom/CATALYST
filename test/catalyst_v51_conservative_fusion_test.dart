// Evidence-based, capped corpus-concept reranking for 46 development + 45 earlier
// separate cases. Frozen ONNX embeddings are genuine outputs from the model.
// Reference keys are read ONLY to score the outputs, never passed to retrieval.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/corpus_wide_concepts.dart';
import 'package:catol/services/tagalog_morphology.dart';

class _ArchivedEncoder implements LocalQueryEncoder {
  const _ArchivedEncoder(this.embeddings);
  final Map<String, List<double>> embeddings;
  @override
  Future<List<double>> encode(List<int> tokenIds, List<int> mask) async {
    final v = embeddings[tokenIds.join(',')];
    if (v == null || v.length != 384) {
      throw StateError('No archived ONNX E5 vector for token sequence; abort.');
    }
    return v;
  }
}

Object? _json(String path) => jsonDecode(File(path).readAsStringSync());

Map<String, List<double>> _vectors(String path) {
  final raw = _json(path) as Map<String, dynamic>;
  return {
    for (final pair in raw.entries)
      pair.key: [for (final number in (pair.value as List)) (number as num).toDouble()],
  };
}

class _Narrative {
  const _Narrative(this.id, this.dataset, this.language, this.text, this.references);
  final String id;
  final String dataset;
  final String language;
  final String text;
  final Set<String> references;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('all-article concept extraction is deterministic, unrelated to statute IDs', () {
    final first = conceptTagsFromStatute(
      'If a person obliged to do something fails to do it, '
      'the same shall be executed at his cost.');
    final query = conceptTagsFromNarrative(
      'Nagpagawa kami ng gate. Hindi natapos ang trabaho at '
      'gusto naming ipagawa sa iba.');
    expect(first, contains('cxsubstitute'));
    expect(first, contains('cxworkperformance'));
    expect(query, contains('cxworkperformance'));
    expect(conceptTagsFromNarrative('I like watching clouds.'), isEmpty);
    final index = CorpusWideConceptIndex.build([
      'The lessor is obliged to make necessary repairs during the lease.',
      'If a person is obliged to do something and fails, it is executed at his cost.',
    ]);
    expect(index.indexedArticles, 2);
    expect(index.searchTags({'cxlease', 'cxrepairs'}).first.index, 0);
    expect(index.searchTags({'cxworkperformance', 'cxsubstitute'}).first.index, 1);
  });

  test('v4 specificity prefers focused statutes and rejects one-tag matches', () {
    final index = CorpusWideConceptIndex.build([
      'The lessor shall make necessary repairs during the lease.',
      'The lessor shall make necessary repairs during the lease. '
          'The buyer shall pay the price of goods in the sale. '
          'The parents shall provide support for their child.',
      'The buyer shall pay the price in the sale.',
    ]);
    final tags = <String>{'cxlease', 'cxrepairs'};
    final focused = index.discriminativeConceptEvidence(0, tags);
    final broad = index.discriminativeConceptEvidence(1, tags);
    expect(focused, inInclusiveRange(0.0, 1.0));
    expect(broad, inInclusiveRange(0.0, 1.0));
    expect(focused, greaterThan(broad),
        reason: 'unrelated article concepts must reduce specificity');
    expect(index.discriminativeConceptEvidence(2, tags), 0.0);
  });

  test('v5 clause evidence requires a specific issue in the SAME clause', () {
    final index = CorpusWideConceptIndex.build([
      'During the lease the lessor shall make necessary repairs.',
      'The lessor shall grant the lease. The buyer shall make repairs.',
      'The buyer must pay the price.',
    ]);
    final query = <String>{'cxlease', 'cxrepairs'};
    expect(index.clauseLocalEvidence(0, query), greaterThan(0.0));
    expect(index.clauseLocalEvidence(1, query), 0.0);
    expect(index.clauseLocalEvidence(2, query), 0.0);
    expect(index.clauseLocalEvidence(0, {'cxlease'}), 0.0);
  });

  test('v5 Filipino word forms expand terms, never select law articles', () {
    final expanded = normalizeTagalogForms(
      'Nagpaayos kami at pinapaayos pa rin, pero hindi binabayaran.',
    );
    expect(expanded, contains('repairs'));
    expect(expanded, contains('payment'));
    expect(normalizeTagalogForms('I like watching clouds.'), isEmpty);
    final index = CorpusWideConceptIndex.build([
      'The lessor shall make necessary repairs to the premises.',
    ]);
    final terms = index.queryTags('Pinapaayos ang inuupahan.',
        tagalogWordForms: true);
    expect(terms, contains('cxrepairs'));
    expect(terms, contains('cxlease'));
  });

  test('V5.1 conservative fusion is bounded and does not use article keys', () {
    final top = <int>[10, 20, 30, 40, 50, 60];
    final rescued = conservativeV51RankFusion(
      v5Ranking: top,
      baselineTopIndex: 40,
      baselineTopScore: 0.41,
      baselineTopBm25Ratio: 1.0,
      v5ThirdScore: 0.44,
      v5CandidateEligible: true,
    );
    expect(rescued.rescued, isTrue);
    expect(rescued.ranking, [10, 20, 40, 30, 50, 60]);
    expect(conservativeV51RankFusion(
      v5Ranking: top, baselineTopIndex: 40, baselineTopScore: 0.34,
      baselineTopBm25Ratio: 1.0, v5ThirdScore: 0.44,
      v5CandidateEligible: true,
    ).rescued, isFalse);
    expect(conservativeV51RankFusion(
      v5Ranking: top, baselineTopIndex: 40, baselineTopScore: 0.43,
      baselineTopBm25Ratio: 0.95, v5ThirdScore: 0.44,
      v5CandidateEligible: true,
    ).rescued, isFalse);
    expect(conservativeV51RankFusion(
      v5Ranking: top, baselineTopIndex: 40, baselineTopScore: 0.43,
      baselineTopBm25Ratio: 1.0, v5ThirdScore: 0.44,
      v5CandidateEligible: false,
    ).rescued, isFalse);
    expect(conservativeV51RankFusion(
      v5Ranking: top, baselineTopIndex: 20, baselineTopScore: 0.43,
      baselineTopBm25Ratio: 1.0, v5ThirdScore: 0.44,
      v5CandidateEligible: true,
    ).rescued, isFalse);
  });

  test('91 known cases: installed vs statute-clause evidence and Tagalog v5', () async {
    final expected = (_json('test/fixtures/expected_installed_top15.json')
        as Map<String, dynamic>);
    final dev = (_json('test/fixtures/development46_cases.json') as List)
        .cast<Map<String, dynamic>>();
    final fresh = (_json('test/fixtures/fresh45_blind_cases.json') as List)
        .cast<Map<String, dynamic>>();
    final key = (_json('test/fixtures/fresh45_provisional_scoring_key.json') as List)
        .cast<Map<String, dynamic>>();
    final labels = {
      for (final entry in key)
        entry['id'] as String: entry['primaryProvisionalId'] as String,
    };
    final cases = <_Narrative>[
      for (final row in dev)
        _Narrative(
          row['datasetId'] as String, 'dev46', row['language'] as String,
          row['query'] as String,
          (row['reviewedRelevantArticleIds'] as List).cast<String>().toSet(),
        ),
      for (final row in fresh)
        _Narrative(
          row['id'] as String, 'earlier45', row['language'] as String,
          row['narrative'] as String,
          {labels[row['id'] as String]!},
        ),
    ];
    expect(dev, hasLength(46));
    expect(fresh, hasLength(45));
    expect(cases, hasLength(91));
    expect(expected, hasLength(91));
    final vectors = {
      ..._vectors('test/fixtures/development46_vectors.json'),
      ..._vectors('test/fixtures/fresh45_query_vectors.json'),
    };
    final encoder = _ArchivedEncoder(vectors);
    const variants = [
      'installed',
      'v4_specific_018',
      'clause_018',
      'clause_030',
      'clause_030_v51_conservative',
      'clause_030_tagalog',
      'clause_030_tagalog_no_training',
    ];

    for (final variant in variants) {
      final tallies = <String, Map<String, int>>{};
      final perLanguage = <String, Map<String, List<int>>>{};
      final perCorpus = <String, Map<String, List<int>>>{};
      for (final item in cases) {
        final corpusEnabled = variant != 'installed';
        const manualProfiles = true;
        final broadGate = variant != 'installed';
        final noVotes = variant == 'clause_030_tagalog_no_training';
        final discriminative = variant == 'v4_specific_018';
        final useClause = variant.startsWith('clause_');
        final useTagalog = variant.contains('_tagalog');
        final rerankWeight = variant == 'installed' ? 0.0 :
            variant.endsWith('_018') ? 0.18 : 0.30;
        Map<String, dynamic>? diag;
        final retrieval = LocalSemanticRetrievalService(
          queryEncoder: encoder,
          enableBilingualLegalLexicalExpansion: true,
          enableLegalIssueLexicalExpansion: manualProfiles,
          enableArticleIssueProfiles: manualProfiles,
          enableIssueAwareLexicalWeight: manualProfiles,
          enableCorroboratedGate: manualProfiles,
          enableTopBm25BorderlineGate: true,
          enableCorpusWideConceptIndex: corpusEnabled,
          enableCorpusConceptGate: broadGate,
          disableTrainingExampleVotes: noVotes,
          corpusConceptRerankWeight: rerankWeight,
          useDiscriminativeConceptEvidence: discriminative,
          useClauseLocalEvidence: useClause,
          useTagalogWordForms: useTagalog,
          enableV51ConservativeFusion: variant == 'clause_030_v51_conservative',
          minimumCosine: 0.80,
          diagnosticArticleIds: item.references,
          onDiagnostics: (record) => diag = record,
        );
        final response = await retrieval.matchConcern(item.text);
        for (final record in [...response.results, ...response.otherCandidates]) {
          expect(record.matchScore, inInclusiveRange(0.0, 100.0),
              reason: '${item.id} $variant returned an out-of-range display score');
        }
        expect(diag, isNotNull, reason: '${item.id} missing retrieval diagnostics');
        final top15 = [
          for (final record in [...response.results, ...response.otherCandidates])
            normalizedArticleId(record.lawName, record.articleNumber),
        ];
        if (variant == 'installed') {
          final expectedTop15 = (expected[item.id] as List).cast<String>();
          expect(top15, expectedTop15,
              reason: 'Installed app baseline mismatch ${item.id}. Stop test.');
        }
        final matchedTop1 = top15.take(1).where(item.references.contains).length;
        final matchedTop3 = top15.take(3).where(item.references.contains).length;
        final matchedTop15 = top15.take(15).where(item.references.contains).length;
        final pool = ((diag!['fusedIds'] as List?) ?? []).map((x) => x.toString()).toSet();
        final eligible = ((diag!['eligibleIds'] as List?) ?? []).map((x) => x.toString()).toSet();
        final hit1 = matchedTop1 > 0;
        final hit3 = matchedTop3 > 0;
        final hit15 = matchedTop15 > 0;
        final hasCandidate = item.references.any(pool.contains);
        final hasEligible = item.references.any(eligible.contains);
        final tally = tallies.putIfAbsent(item.dataset, () => {
              'cases': 0, 'references': 0, 'h1': 0, 'h3': 0, 'h15': 0,
              'matched3': 0, 'candidate': 0, 'eligible': 0,
            });
        tally['cases'] = tally['cases']! + 1;
        tally['references'] = tally['references']! + item.references.length;
        tally['h1'] = tally['h1']! + (hit1 ? 1 : 0);
        tally['h3'] = tally['h3']! + (hit3 ? 1 : 0);
        tally['h15'] = tally['h15']! + (hit15 ? 1 : 0);
        tally['matched3'] = tally['matched3']! + matchedTop3;
        tally['candidate'] = tally['candidate']! + (hasCandidate ? 1 : 0);
        tally['eligible'] = tally['eligible']! + (hasEligible ? 1 : 0);
        final byLang = perLanguage.putIfAbsent(item.dataset, () => {});
        final lb = byLang.putIfAbsent(item.language, () => [0, 0, 0, 0]);
        lb[0]++; lb[1] += hit1 ? 1 : 0; lb[2] += hit3 ? 1 : 0;
        lb[3] += hasCandidate ? 1 : 0;
        final corpus = item.references.first.split(':').first;
        final byCode = perCorpus.putIfAbsent(item.dataset, () => {});
        final cb = byCode.putIfAbsent(corpus, () => [0, 0, 0, 0]);
        cb[0]++; cb[1] += hit1 ? 1 : 0; cb[2] += hit3 ? 1 : 0;
        cb[3] += hasCandidate ? 1 : 0;
        print('CATALYST_CONCEPT_CASE:${jsonEncode({
          'variant': variant, 'dataset': item.dataset, 'id': item.id,
          'language': item.language, 'references': item.references.toList(),
          'hit1': hit1, 'hit3': hit3, 'hit15': hit15,
          'matched3': matchedTop3, 'candidate': hasCandidate,
          'eligible': hasEligible, 'top15': top15,
          'conceptTags': diag!['conceptQueryTags'],
          'top3Evidence': ((diag!['top15Evidence'] as List?) ?? []).take(3).toList(),
          'corpusRerankWeight': diag!['corpusConceptRerankWeight'],
          'discriminative': diag!['useDiscriminativeConceptEvidence'],
          'clauseEvidence': diag!['useClauseLocalEvidence'],
          'tagalogForms': diag!['useTagalogWordForms'],
          'tagalogFormTerms': diag!['tagalogMorphologyTerms'],
          'v51Rescued': diag!['v51RescuedBaselineTop1'],
          'v51BaselineTop1Id': diag!['v51BaselineTop1Id'],
          'conceptRank': {
            for (final ref in item.references)
              ref: (diag!['targets'] as Map?)?[ref] == null
                  ? null : ((diag!['targets'] as Map)[ref] as Map)['conceptRank'],
          },
        })}');
      }
      if (variant == 'installed') {
        expect([tallies['dev46']!['h1'], tallies['dev46']!['h3'],
                tallies['dev46']!['h15']], [27, 36, 39]);
        expect([tallies['earlier45']!['h1'], tallies['earlier45']!['h3'],
                tallies['earlier45']!['h15']], [9, 15, 24]);
      }
      if (variant == 'clause_030') {
        expect(tallies['dev46']!['h3'], 34);
        expect(tallies['earlier45']!['h3'], 21);
      }
      if (variant == 'clause_030_v51_conservative') {
        expect(tallies['dev46']!['h3'], 35);
        expect(tallies['earlier45']!['h3'], 21);
      }
      if (variant == 'v4_specific_018') {
        // Reproduce the real v4 Flutter experiment before judging v5.
        expect(tallies['dev46']!['h3'], 35);
        expect(tallies['earlier45']!['h3'], 19);
      }
      for (final dataset in ['dev46', 'earlier45']) {
        print('CATALYST_CONCEPT_SUMMARY:${jsonEncode({
          'variant': variant, 'dataset': dataset,
          ...tallies[dataset]!,
          'byLanguage': perLanguage[dataset]!,
          'byCorpus': perCorpus[dataset]!,
          'precisionAt3Provisional': tallies[dataset]!['matched3']! /
              (tallies[dataset]!['cases']! * 3),
          'recallAt3Provisional': tallies[dataset]!['matched3']! /
              tallies[dataset]!['references']!,
        })}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}
