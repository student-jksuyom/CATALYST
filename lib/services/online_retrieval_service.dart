import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../models/law_match_result.dart';
import 'catalyst_local_retrieval_service.dart';
import 'explanation_builder.dart';
import 'explanation_language.dart';

const String onlineRetrievalWarning =
    'Provisions were retrieved from the local corpus by embedding similarity '
    'and keyword matching, then reordered by an AI reviewer. Scores show rank '
    'order, not a probability or a legal conclusion.';

const String _apiUrl = String.fromEnvironment('CATALYST_API_URL');
const String _apiToken = String.fromEnvironment('CATALYST_API_TOKEN');

const int _candidateCount = 40;
const int _candidateTextLimit = 400;
const int _maxResults = 15;
const Duration _defaultTimeout = Duration(seconds: 45);

/// A real answer is at most 15 short entries (a few KB); anything larger is
/// rejected before JSON parsing.
const int maxResponseBytes = 256 * 1024;

/// Online retrieval is on when a proxy URL was supplied at build time
/// (`--dart-define=CATALYST_API_URL=...`); otherwise the app stays on-device.
CatalystRetrievalService createDefaultRetrievalService() {
  if (_apiUrl.isEmpty) return const LocalSemanticRetrievalService();
  return OnlineRetrievalService(
    endpoint: Uri.parse(_apiUrl),
    appToken: _apiToken,
  );
}

/// Sends the narrative plus on-device candidate provisions to a proxy that
/// asks a language model to select and reorder the applicable provisions. Every returned provision is verified against the local corpus
/// and displayed with the corpus text. Any online failure falls back to the
/// on-device ranking.
class OnlineRetrievalService implements CatalystRetrievalService {
  OnlineRetrievalService({
    required this.endpoint,
    this.appToken = '',
    this.timeout = _defaultTimeout,
    LocalSemanticRetrievalService? local,
  }) : _local =
           local ??
           const LocalSemanticRetrievalService(resultLimit: _candidateCount);

  final Uri endpoint;
  final String appToken;
  final Duration timeout;
  final LocalSemanticRetrievalService _local;

  @override
  Future<CatalystMatchResponse> matchConcern(String concern) async {
    CatalystMatchResponse? localResponse;
    CatalystRetrievalException? localError;
    try {
      localResponse = await _local.matchConcern(concern);
    } on CatalystRetrievalException catch (error) {
      if (error.failure == CatalystRetrievalFailure.invalidInput) rethrow;
      localError = error;
    }
    if (localResponse?.clarifyingQuestion != null) return localResponse!;

    final candidates = [
      ...?localResponse?.results,
      ...?localResponse?.otherCandidates,
    ];
    try {
      final online = await _askProxy(concern.trim(), candidates);
      final response = await _buildResponse(
        concern.trim(),
        online,
        candidates,
        localResponse,
      );
      if (response != null) return response;
    } catch (error, stackTrace) {
      developer.log(
        'Online retrieval failed (${error.runtimeType}); using on-device results',
        name: 'catol.retrieval',
        error: error,
        stackTrace: stackTrace,
      );
    }

    if (localResponse == null) throw localError!;
    return _trimmed(localResponse);
  }

  CatalystMatchResponse _trimmed(CatalystMatchResponse response) {
    final all = [
      ...response.results,
      ...response.otherCandidates,
    ].take(_maxResults).toList();
    return CatalystMatchResponse(
      results: List.unmodifiable(all.take(3)),
      otherCandidates: List.unmodifiable(all.skip(3)),
      originalQuery: response.originalQuery,
      processedQuery: response.processedQuery,
      analysis: response.analysis,
      warning: response.warning,
      mode: RetrievalMode.onDeviceFallback,
    );
  }

  Future<_OnlineAnswer> _askProxy(
    String query,
    List<LawMatchResult> candidates,
  ) async {
    final body = jsonEncode({
      'query': query,
      'languages': _explanationLanguages(query),
      'candidates': [
        for (final c in candidates.take(_candidateCount))
          {
            'law': c.lawName,
            'article': c.articleNumber,
            'text': _clip(c.articleText ?? c.description),
          },
      ],
    });

    final client = HttpClient()..connectionTimeout = timeout;
    try {
      // One deadline covers connect, upload, response headers and body.
      return await _post(client, body).timeout(timeout);
    } finally {
      client.close(force: true);
    }
  }

  /// The user's own language first, plus one alternative for the toggle.
  static List<String> _explanationLanguages(String query) =>
      switch (detectQueryLanguage(query)) {
        ExplanationLanguage.tagalog => ['tl', 'en'],
        ExplanationLanguage.taglish => ['taglish', 'en'],
        ExplanationLanguage.english => ['en', 'tl'],
      };

  Future<_OnlineAnswer> _post(HttpClient client, String body) async {
    final request = await client.postUrl(endpoint);
    request.headers.contentType = ContentType.json;
    if (appToken.isNotEmpty) request.headers.set('x-catalyst-token', appToken);
    request.add(utf8.encode(body));
    final response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpException('Proxy returned ${response.statusCode}');
    }
    if (response.contentLength > maxResponseBytes) {
      throw const FormatException('The proxy response is too large.');
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > maxResponseBytes) {
        throw const FormatException('The proxy response is too large.');
      }
    }
    return _OnlineAnswer.parse(jsonDecode(utf8.decode(bytes)));
  }

  Future<CatalystMatchResponse?> _buildResponse(
    String query,
    _OnlineAnswer answer,
    List<LawMatchResult> candidates,
    CatalystMatchResponse? localResponse,
  ) async {
    final byId = {
      for (final c in candidates)
        normalizedArticleId(c.lawName, c.articleNumber): c,
    };
    final sourceNote = answer.sources.isEmpty
        ? ''
        : ' Sources: ${answer.sources.take(3).join('; ')}.';

    final seen = <String>{};
    final results = <LawMatchResult>[];
    for (final item in answer.ranked) {
      if (results.length == _maxResults) break;
      final id = normalizedArticleId(item.law, item.article);
      if (!seen.add(id)) continue;
      // Rank-derived score, strictly descending, so the existing screens keep
      // the model's order when they sort by score.
      final score = (96 - results.length * 5).clamp(10, 96).toDouble();
      final reason = item.reason.isEmpty
          ? ''
          : 'Online review (${item.relevance}): ${item.reason}$sourceNote';
      final local = byId[id];
      final points = [
        if (reason.isNotEmpty) reason,
        ...?local?.caseExplanationPoints,
      ];
      final articleId = normalizedArticleId(item.law, item.article);
      // The offline variants end with an "connect to the internet" hint,
      // which makes no sense in an online answer.
      final variants = <String, ExplanationVariant>{
        for (final e in (local?.explanationVariants ?? const {}).entries)
          e.key: ExplanationVariant(
            points: e.value.points.isEmpty
                ? const []
                : e.value.points.sublist(0, e.value.points.length - 1),
            reminders: e.value.reminders,
          ),
      };
      for (final entry in item.explain.entries) {
        variants[entry.key] = ExplanationVariant(
          points: entry.value,
          reminders:
              variants[entry.key]?.reminders ??
              buildReminders(entry.key, articleId: articleId),
        );
      }
      final result = await _local.lookupArticle(
        item.law,
        item.article,
        matchScore: score,
        explanationPoints: points,
        explanationVariants: variants.isEmpty ? null : variants,
        defaultExplanationLanguage: detectQueryLanguage(query).code,
      );
      if (result != null) results.add(result);
    }
    if (results.isEmpty) return null;

    return CatalystMatchResponse(
      results: List.unmodifiable(results.take(3)),
      otherCandidates: List.unmodifiable(results.skip(3)),
      originalQuery: query,
      processedQuery: localResponse?.processedQuery ?? query,
      analysis: localResponse?.analysis,
      warning: onlineRetrievalWarning,
      mode: RetrievalMode.online,
    );
  }

  static String _clip(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= _candidateTextLimit
        ? flat
        : '${flat.substring(0, _candidateTextLimit)}...';
  }
}

class _RankedProvision {
  const _RankedProvision(
    this.law,
    this.article,
    this.relevance,
    this.reason,
    this.explain,
  );

  final String law;
  final String article;
  final String relevance;
  final String reason;
  final Map<String, List<String>> explain;
}

class _OnlineAnswer {
  const _OnlineAnswer(this.ranked, this.sources);

  final List<_RankedProvision> ranked;
  final List<String> sources;

  factory _OnlineAnswer.parse(Object? json) {
    if (json is! Map<String, dynamic> || json['ranked'] is! List) {
      throw const FormatException('The proxy response has no "ranked" list.');
    }
    String text(Object? value) => value is String ? value.trim() : '';
    final ranked = <_RankedProvision>[];
    for (final entry in json['ranked'] as List) {
      if (entry is! Map<String, dynamic>) continue;
      final law = text(entry['law']);
      final article = _articleNumber(entry['article']);
      if (law.isEmpty || article.isEmpty) continue;
      final relevance = text(entry['relevance']) == 'direct'
          ? 'direct'
          : 'related';
      final explain = <String, List<String>>{};
      final rawExplain = entry['explain'];
      if (rawExplain is Map<String, dynamic>) {
        for (final code in const ['en', 'taglish', 'tl']) {
          final bullets = rawExplain[code];
          if (bullets is! List) continue;
          final clean =
              [
                    for (final b in bullets)
                      if (b is String && b.trim().isNotEmpty) b.trim(),
                  ]
                  .take(4)
                  .map((b) => b.length > 320 ? b.substring(0, 320) : b)
                  .toList();
          if (clean.isNotEmpty) explain[code] = clean;
        }
      }
      ranked.add(
        _RankedProvision(
          law,
          article,
          relevance,
          text(entry['reason']),
          explain,
        ),
      );
    }
    final sources = <String>[];
    final rawSources = json['sources'];
    if (rawSources is List) {
      for (final source in rawSources) {
        if (source is Map<String, dynamic>) {
          final title = text(source['title']);
          if (title.isNotEmpty) sources.add(title);
        }
      }
    }
    return _OnlineAnswer(ranked, sources);
  }

  // Accepts "493", 493 and "Art. 493".
  static String _articleNumber(Object? value) {
    final raw = value is num
        ? value.toString()
        : (value is String ? value : '');
    final match = RegExp(r'\d+(?:-[A-Za-z])?|\d+[A-Za-z]?').firstMatch(raw);
    return match?.group(0) ?? '';
  }
}
