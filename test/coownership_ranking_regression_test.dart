import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:flutter_test/flutter_test.dart';

// Co-ownership narrative: a sibling sold inherited land without the other
// co-owners' knowledge or consent. The fixture holds real multilingual-e5
// query vectors for the two dense variants of this narrative, so the test
// runs the production blend against the real corpus and chunk embeddings.
const _narrative =
    'May kupa kami na minana naming magkakapatid. Ngayon nalaman ko na '
    'binenta na pala ng kuya ko yung buong lupa nang hindi namin alam o '
    'pinayagan. pwede ba niyang gawin yon?';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Map<String, List<double>> vectors;
  setUpAll(() {
    final raw = jsonDecode(
      File('test/fixtures/coownership_query_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    vectors = raw.map(
      (key, value) =>
          MapEntry(key, [for (final v in value as List) (v as num).toDouble()]),
    );
  });

  Future<List<String>> rankedIds() async {
    final service = LocalSemanticRetrievalService(
      queryEncoder: _FixtureEncoder(vectors),
      queryPreprocessor: const _Passthrough(),
    );
    final response = await service.matchConcern(_narrative);
    expect(response.results, hasLength(3));
    final scores = [
      ...response.results,
      ...response.otherCandidates,
    ].map((r) => r.matchScore).toList();
    expect(scores, orderedEquals([...scores]..sort((a, b) => b.compareTo(a))));
    return [
      for (final r in [...response.results, ...response.otherCandidates])
        normalizedArticleId(r.lawName, r.articleNumber),
    ];
  }

  test('co-ownership provisions rank above generic sale provisions', () async {
    final ids = await rankedIds();

    // Before the blend change the order began 1614, 1607, 498 with Art. 493
    // 14th; the provisions on a co-owner's alienation and on redemption by
    // co-owners now lead.
    expect(ids.take(3), contains('civilcode:493'));
    expect(ids.take(5), contains('civilcode:1623'));
    expect(ids, contains('civilcode:491'));
    expect(
      ids.indexOf('civilcode:1614'),
      greaterThan(ids.indexOf('civilcode:493')),
    );
    expect(ids.take(2), isNot(contains('civilcode:1607')));
  });
}

class _FixtureEncoder implements LocalQueryEncoder {
  _FixtureEncoder(this.vectors);

  final Map<String, List<double>> vectors;

  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    final vector = vectors[inputIds.join(',')];
    if (vector == null) {
      throw StateError('No fixture vector for the query.');
    }
    return vector;
  }
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();

  @override
  Future<String> preprocess(String query) async => query;
}
