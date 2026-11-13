import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../models/law_match_result.dart';
import 'jurisprudence_service.dart';

const String _apiUrl = String.fromEnvironment('CATALYST_API_URL');
const String _apiToken = String.fromEnvironment('CATALYST_API_TOKEN');

const int maxResponseBytes = 256 * 1024;
const Duration _followUpTimeout = Duration(seconds: 40);

class FollowUpAnswer {
  const FollowUpAnswer({
    required this.text,
    this.citedCases = const [],
    this.webSources = const [],
    this.searchedWeb = false,
  });

  final String text;

  /// Decisions from the bundled dataset that the answer relies on.
  final List<JurisprudenceCase> citedCases;

  /// Titles of web pages the reviewer consulted (not verified by the app).
  final List<String> webSources;
  final bool searchedWeb;
}

abstract class FollowUpAnswerer {
  /// Returns null when the online answer is unavailable, so the caller can
  /// fall back to on-device answers.
  Future<FollowUpAnswer?> answer({
    required String question,
    required String narrative,
    required String language,
    required List<LawMatchResult> articles,
    required List<JurisprudenceCase> cases,
  });
}

/// Online follow-up answers are on when the build supplied a proxy URL.
FollowUpAnswerer? createDefaultFollowUpAnswerer() {
  if (_apiUrl.isEmpty) return null;
  return OnlineFollowUpAnswerer(
    endpoint: Uri.parse(_apiUrl),
    appToken: _apiToken,
  );
}

/// Sends the question, the retrieved articles and the on-device ranked
/// decisions to the proxy. The reply may only cite decisions that were sent.
class OnlineFollowUpAnswerer implements FollowUpAnswerer {
  OnlineFollowUpAnswerer({
    required this.endpoint,
    this.appToken = '',
    this.timeout = _followUpTimeout,
  });

  final Uri endpoint;
  final String appToken;
  final Duration timeout;

  @override
  Future<FollowUpAnswer?> answer({
    required String question,
    required String narrative,
    required String language,
    required List<LawMatchResult> articles,
    required List<JurisprudenceCase> cases,
  }) async {
    final body = jsonEncode({
      'mode': 'followup',
      'query': question,
      'narrative': narrative,
      'languages': [language],
      'articles': [
        for (final a in articles.take(8))
          {
            'law': a.lawName,
            'article': a.articleNumber,
            'text': _clip(a.articleText ?? a.description, 420),
          },
      ],
      'cases': [
        for (final c in cases.take(5))
          {
            'id': c.id,
            'citation': c.citation,
            'holding': _clip(c.holding, 450),
            'dispositive': _clip(c.dispositive, 300),
            'passages': [for (final p in c.passages.take(2)) _clip(p, 420)],
          },
      ],
    });
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final json = await _post(client, body).timeout(timeout);
      return _parse(json, cases);
    } catch (error) {
      developer.log(
        'Online follow-up failed (${error.runtimeType}); using on-device answer',
        name: 'catol.followup',
      );
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> _post(HttpClient client, String body) async {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    if (appToken.isNotEmpty) request.headers.set('x-catalyst-token', appToken);
    request.add(utf8.encode(body));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('Proxy returned ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        throw const FormatException('The proxy response is too large.');
      }
    }
    return jsonDecode(utf8.decode(bytes));
  }

  FollowUpAnswer _parse(Object? json, List<JurisprudenceCase> sent) {
    if (json is! Map) throw const FormatException('Unexpected response.');
    final text = json['answer'];
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('Missing answer.');
    }
    final byId = {for (final c in sent) c.id: c};
    final cited = <JurisprudenceCase>[];
    for (final id in (json['citedCaseIds'] as List? ?? const [])) {
      final match = byId[id];
      if (match != null && !cited.contains(match)) cited.add(match);
    }
    final web = [
      for (final s in (json['sources'] as List? ?? const []))
        if (s is Map && s['title'] is String) (s['title'] as String).trim(),
    ].where((t) => t.isNotEmpty).take(4).toList();
    return FollowUpAnswer(
      text: text.trim(),
      citedCases: cited,
      webSources: web,
      searchedWeb: json['searched'] == true && web.isNotEmpty,
    );
  }

  static String _clip(String text, int max) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= max ? flat : '${flat.substring(0, max)}...';
  }
}
