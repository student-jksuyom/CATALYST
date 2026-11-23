import 'dart:convert';

import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/gemma_article_selector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const candidate = LawMatchResult(
    lawName: 'Civil Code',
    articleNumber: '1308',
    title: 'Binding effect of contracts',
    description:
        'Article 1308. The contract must bind both contracting parties.',
    articleText:
        'Article 1308. The contract must bind both contracting parties.',
    matchScore: 82,
  );
  const validQuote = 'must bind both contracting parties';

  Map<String, Object?> response({
    String decision = 'select',
    List<Map<String, Object?>>? selected,
  }) => {
    'choices': [
      {
        'message': {
          'content': jsonEncode({
            'decision': decision,
            'selected':
                selected ??
                [
                  {
                    'id': 'civilcode:1308',
                    'source_quote': validQuote,
                    'reason': 'It says the contract binds both parties.',
                  },
                ],
            'explanation':
                'Article 1308 addresses the contract’s binding effect.',
          }),
        },
      },
    ],
  };

  test('accepts only candidate IDs and exact supporting quotes', () async {
    Map<String, Object?>? requestBody;
    final assessor = LocalGemmaArticleAssessor(
      endpoint: Uri.parse('http://localhost:8081'),
      completionRequester: (endpoint, request, timeout) async {
        requestBody = request;
        return response(
          selected: [
            {
              'id': 'civilcode:1308',
              'source_quote': validQuote,
              'reason': 'It says the contract binds both parties.',
            },
            {
              'id': 'civilcode:9999',
              'source_quote': 'Invented quote',
              'reason': 'Not a candidate.',
            },
          ],
        );
      },
    );

    final result = await assessor.assess(
      concern: 'We agreed on a contract.',
      candidates: const [candidate],
    );

    expect(result.results, hasLength(1));
    expect(result.results.single.supportingQuote, validQuote);
    expect(
      result.results.single.contextualExplanation,
      'It says the contract binds both parties.',
    );
    expect(result.results.single.hasAiExplanation, isTrue);
    expect(result.rejectedIds, 1);
    expect(result.rejectedQuotes, 0);
    expect((requestBody!['response_format'] as Map)['type'], 'json_schema');
    final prompt = (requestBody!['messages'] as List)[1] as Map;
    expect(prompt['content'], contains('The contract must bind both'));
  });

  test('rejects a selected article with an unsupported quote', () async {
    final assessor = LocalGemmaArticleAssessor(
      endpoint: Uri.parse('http://localhost:8081'),
      completionRequester: (endpoint, request, timeout) async => response(
        selected: [
          {
            'id': 'civilcode:1308',
            'source_quote': 'The contract is always enforceable.',
            'reason': 'This quote is not in the supplied text.',
          },
        ],
      ),
    );

    final result = await assessor.assess(
      concern: 'We agreed on a contract.',
      candidates: const [candidate],
    );

    expect(result.results, isEmpty);
    expect(result.rejectedQuotes, 1);
  });

  test('sends at most fifty candidates to Gemma', () async {
    Map<String, Object?>? requestBody;
    final candidates = List.generate(
      51,
      (index) => LawMatchResult(
        lawName: 'Civil Code',
        articleNumber: '$index',
        title: 'Article $index',
        description: 'Text for article $index.',
        articleText: 'Text for article $index.',
        matchScore: 50,
      ),
    );
    final assessor = LocalGemmaArticleAssessor(
      endpoint: Uri.parse('http://localhost:8081'),
      completionRequester: (endpoint, request, timeout) async {
        requestBody = request;
        return response(decision: 'abstain', selected: const []);
      },
    );

    await assessor.assess(concern: 'A legal concern', candidates: candidates);

    final prompt = (requestBody!['messages'] as List)[1] as Map;
    final encodedCandidates = (prompt['content'] as String).split(
      'CANDIDATES (IDs and official article text):\n',
    )[1];
    expect(jsonDecode(encodedCandidates), hasLength(50));
  });

  test('abstention produces no selected results', () async {
    final assessor = LocalGemmaArticleAssessor(
      endpoint: Uri.parse('http://localhost:8081'),
      completionRequester: (endpoint, request, timeout) async =>
          response(decision: 'abstain', selected: const []),
    );

    final result = await assessor.assess(
      concern: 'A legal concern',
      candidates: const [candidate],
    );

    expect(result.decision, GemmaArticleDecision.abstain);
    expect(result.results, isEmpty);
  });

  test('rejects non-local inference endpoints', () {
    expect(
      () =>
          LocalGemmaArticleAssessor(endpoint: Uri.parse('https://example.com')),
      throwsArgumentError,
    );
  });

  test('uses the same normalized identifier as retrieval', () {
    expect(normalizedArticleId('Civil Code', '1308'), 'civilcode:1308');
  });
}
