import 'dart:convert';
import 'dart:io';

import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:catol/services/online_retrieval_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The binding stubs every HttpClient with a 400; these tests need the
  // loopback server.
  HttpOverrides.global = null;

  late HttpServer server;
  late int status;
  late String responseBody;
  late bool hang;
  String? requiredToken;
  final received = <Map<String, dynamic>>[];
  final headers = <String, String?>{};

  setUp(() async {
    status = 200;
    responseBody = '{}';
    hang = false;
    requiredToken = null;
    received.clear();
    headers.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      headers['token'] = request.headers.value('x-catalyst-token');
      received.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>,
      );
      if (hang) return;
      final unauthorized =
          requiredToken != null && headers['token'] != requiredToken;
      request.response
        ..statusCode = unauthorized ? 401 : status
        ..headers.contentType = ContentType.json
        ..write(unauthorized ? '{"error":"unauthorized"}' : responseBody);
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  OnlineRetrievalService service({
    Uri? endpoint,
    String token = 'secret',
    Duration timeout = const Duration(seconds: 5),
  }) => OnlineRetrievalService(
    endpoint: endpoint ?? Uri.parse('http://127.0.0.1:${server.port}/'),
    appToken: token,
    timeout: timeout,
    local: LocalSemanticRetrievalService(
      queryEncoder: _BasisEncoder(),
      queryPreprocessor: const _Passthrough(),
      minimumCosine: -1,
      resultLimit: 40,
    ),
  );

  const narrative =
      'Binenta ng kuya ko ang lupang minana namin nang walang pahintulot.';

  List<String> ids(CatalystMatchResponse r) => [
    for (final x in [...r.results, ...r.otherCandidates])
      normalizedArticleId(x.lawName, x.articleNumber),
  ];

  test('uses the online ranking, verified against the corpus', () async {
    responseBody = jsonEncode({
      'ranked': [
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'Co-owner consent.',
        },
        {
          'law': 'CivilCode',
          'article': 'Art. 493',
          'relevance': 'related',
          'reason': 'Own share only.',
        },
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'duplicate',
        },
        {
          'law': 'CivilCode',
          'article': '99999',
          'relevance': 'direct',
          'reason': 'not in corpus',
        },
        {
          'law': 'FamilyCode',
          'article': 69,
          'relevance': 'related',
          'reason': 'Domicile.',
        },
      ],
      'sources': [
        {'title': 'Example source'},
      ],
    });

    final response = await service().matchConcern(narrative);

    expect(ids(response), ['civilcode:491', 'civilcode:493', 'familycode:69']);
    expect(response.results, hasLength(3));
    expect(response.warning, onlineRetrievalWarning);
    final first = response.results.first;
    expect(first.articleText, startsWith('Article 491.'));
    expect(
      first.caseExplanationPoints!.first,
      contains('Online review (direct)'),
    );
    expect(first.caseExplanationPoints!.first, contains('Example source'));
    final scores = response.results.map((r) => r.matchScore).toList();
    expect(scores, orderedEquals([...scores]..sort((a, b) => b.compareTo(a))));
    expect(scores.toSet(), hasLength(scores.length));
    expect(response.originalQuery, narrative);

    expect(headers['token'], 'secret');
    expect(received.single['query'], narrative);
    final candidates = received.single['candidates'] as List;
    expect(candidates.length, lessThanOrEqualTo(40));
  });

  test(
    'falls back to on-device results when the proxy returns an error',
    () async {
      status = 502;
      responseBody = '{"error":"upstream"}';
      final response = await service().matchConcern(narrative);
      expect(received, hasLength(1));
      expect(response.warning, retrievalWarning);
      expect(response.results, isNotEmpty);
      expect(ids(response).length, lessThanOrEqualTo(15));
    },
  );

  test('asks for the user\'s language and keeps plain explanations apart from reminders', () async {
    responseBody = jsonEncode({
      'ranked': [
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'Co-owner consent.',
          'explain': {
            'tl': [
              'Hindi puwedeng baguhin ng isang co-owner ang lupa nang walang pahintulot.',
            ],
            'en': ['One co-owner cannot change the shared land alone.'],
            'junk': ['ignored'],
          },
        },
      ],
      'sources': [],
    });

    final response = await service().matchConcern(narrative);

    expect(received.single['languages'], ['tl', 'en']);
    final first = response.results.first;
    expect(first.defaultExplanationLanguage, 'tl');
    final tl = first.explanationVariants!['tl']!;
    expect(tl.points.single, startsWith('Hindi puwedeng baguhin'));
    expect(tl.reminders.join(' '), contains('hindi legal na payo'));
    expect(
      first.explanationVariants!['en']!.points.single,
      startsWith('One co-owner'),
    );
    expect(first.explanationVariants!.keys, isNot(contains('junk')));
    // Variants never show the offline "connect to the internet" hint.
    expect(
      first.explanationVariants!['taglish']!.points.join(' '),
      isNot(contains('Mag-connect sa internet')),
    );
  });

  test('falls back on malformed or empty online answers', () async {
    responseBody = 'not json';
    expect((await service().matchConcern(narrative)).warning, retrievalWarning);

    responseBody = '{"ranked":[]}';
    expect((await service().matchConcern(narrative)).warning, retrievalWarning);

    responseBody = '{"ranked":[{"law":"CivilCode","article":"99999"}]}';
    expect((await service().matchConcern(narrative)).warning, retrievalWarning);
  });

  test('falls back when there is no connection', () async {
    final dead = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close(force: true);
    final response = await service(
      endpoint: Uri.parse('http://127.0.0.1:$port/'),
    ).matchConcern(narrative);
    expect(response.warning, retrievalWarning);
    expect(response.results, isNotEmpty);
  });

  test('unauthorized: a wrong or missing token falls back on-device', () async {
    requiredToken = 'secret';
    responseBody = jsonEncode({
      'ranked': [
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'x',
        },
      ],
    });

    final accepted = await service().matchConcern(narrative);
    expect(accepted.warning, onlineRetrievalWarning);
    expect(headers['token'], 'secret');

    final wrong = await service(token: 'wrong').matchConcern(narrative);
    expect(headers['token'], 'wrong');
    expect(wrong.warning, retrievalWarning);
    expect(wrong.results, isNotEmpty);

    final missing = await service(token: '').matchConcern(narrative);
    expect(headers['token'], isNull);
    expect(missing.warning, retrievalWarning);
    expect(missing.results, isNotEmpty);
  });

  test(
    'timeout: a Worker that never answers falls back without hanging',
    () async {
      hang = true;
      final watch = Stopwatch()..start();
      final response = await service(timeout: const Duration(milliseconds: 500))
          .matchConcern(narrative);
      watch.stop();

      expect(received, hasLength(1));
      expect(response.warning, retrievalWarning);
      expect(response.results, isNotEmpty);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    },
  );

  test('invalid responses of every shape fall back', () async {
    final bodies = <String>[
      '[]',
      '{"ranked":"x"}',
      '{"ranked":[1,2,null]}',
      '{"ranked":[{"law":"CivilCode"}]}',
      '{"ranked":[{"law":"CivilCode","article":"abc"}]}',
      '{"ranked":[{"law":"UnknownLaw","article":"1"}]}',
      '',
    ];
    for (final body in bodies) {
      responseBody = body;
      final response = await service().matchConcern(narrative);
      expect(response.warning, retrievalWarning, reason: 'body: "$body"');
      expect(response.results, isNotEmpty);
    }
  });

  test('an oversized response is rejected before parsing', () async {
    final entries = [
      for (var i = 0; i < 4000; i++)
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'padding padding padding padding',
        },
    ];
    responseBody = jsonEncode({'ranked': entries});
    expect(responseBody.length, greaterThan(maxResponseBytes));

    final response = await service().matchConcern(narrative);
    expect(response.warning, retrievalWarning);
  });

  test('a response just under the limit is still parsed', () async {
    responseBody = jsonEncode({
      'ranked': [
        {
          'law': 'CivilCode',
          'article': '491',
          'relevance': 'direct',
          'reason': 'ok',
        },
      ],
      'sources': [
        for (var i = 0; i < 50; i++) {'title': 'Source $i'},
      ],
    });
    expect(responseBody.length, lessThan(maxResponseBytes));
    expect(
      (await service().matchConcern(narrative)).warning,
      onlineRetrievalWarning,
    );
  });

  test('without CATALYST_API_URL the default service is on-device only', () {
    expect(
      createDefaultRetrievalService(),
      isA<LocalSemanticRetrievalService>(),
    );
  });

  test('still rejects empty input', () async {
    expect(
      service().matchConcern('   '),
      throwsA(isA<CatalystRetrievalException>()),
    );
    expect(received, isEmpty);
  });
}

class _BasisEncoder implements LocalQueryEncoder {
  @override
  Future<List<double>> encode(
    List<int> inputIds,
    List<int> attentionMask,
  ) async {
    final vector = List<double>.filled(384, 0);
    vector[0] = 1;
    return vector;
  }
}

class _Passthrough implements LegalQueryPreprocessor {
  const _Passthrough();

  @override
  Future<String> preprocess(String query) async => query;
}
