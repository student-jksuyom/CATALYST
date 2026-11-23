import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../models/law_match_result.dart';
import 'explanation_builder.dart';

const String _gemmaBaseUrl = String.fromEnvironment('CATALYST_GEMMA_BASE_URL');
const int _candidateLimit = 50;
const int _maximumResponseBytes = 128 * 1024;
const Duration _defaultTimeout = Duration(minutes: 30);

typedef GemmaCompletionRequester = Future<Object?> Function(
  Uri endpoint,
  Map<String, Object?> request,
  Duration timeout,
);

const Map<String, Object?> _selectionSchema = {
  'type': 'object',
  'properties': {
    'decision': {
      'type': 'string',
      'enum': ['select', 'abstain', 'clarify'],
    },
    'selected': {
      'type': 'array',
      'maxItems': 3,
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'string', 'maxLength': 40},
          'source_quote': {'type': 'string', 'maxLength': 80},
          'reason': {'type': 'string', 'maxLength': 100},
        },
        'required': ['id', 'source_quote', 'reason'],
        'additionalProperties': false,
      },
    },
    'explanation': {'type': 'string', 'maxLength': 160},
  },
  'required': ['decision', 'selected', 'explanation'],
  'additionalProperties': false,
};

abstract interface class GemmaArticleAssessor {
  Future<GemmaArticleAssessment> assess({
    required String concern,
    required List<LawMatchResult> candidates,
  });
}

enum GemmaArticleDecision { select, abstain, clarify }

class GemmaArticleAssessment {
  const GemmaArticleAssessment({
    required this.decision,
    required this.results,
    required this.explanation,
    required this.elapsed,
    this.rejectedIds = 0,
    this.rejectedQuotes = 0,
  });

  final GemmaArticleDecision decision;
  final List<LawMatchResult> results;
  final String explanation;
  final Duration elapsed;
  final int rejectedIds;
  final int rejectedQuotes;
}

class GemmaArticleAssessmentException implements Exception {
  const GemmaArticleAssessmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalGemmaArticleAssessor implements GemmaArticleAssessor {
  LocalGemmaArticleAssessor({
    required this.endpoint,
    this.timeout = _defaultTimeout,
    HttpClient Function()? clientFactory,
    this.completionRequester,
  }) : _clientFactory = clientFactory ?? HttpClient.new {
    if (endpoint.scheme != 'http' ||
        !{'localhost', '127.0.0.1'}.contains(endpoint.host)) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'Gemma must use a local HTTP endpoint.',
      );
    }
  }

  factory LocalGemmaArticleAssessor.fromEnvironment() {
    final value = _gemmaBaseUrl.trim();
    if (value.isEmpty) {
      throw StateError('CATALYST_GEMMA_BASE_URL is not configured.');
    }
    final base = Uri.parse(value);
    return LocalGemmaArticleAssessor(
      endpoint: base.replace(
        // Force IPv4: adb reverse forwards the device TCP port to the PC.
        host: base.host == 'localhost' ? '127.0.0.1' : base.host,
        path:
            '${base.path.replaceFirst(RegExp(r'/$'), '')}/v1/chat/completions',
        query: null,
        fragment: null,
      ),
    );
  }

  final Uri endpoint;
  final Duration timeout;
  final GemmaCompletionRequester? completionRequester;
  final HttpClient Function() _clientFactory;

  @override
  Future<GemmaArticleAssessment> assess({
    required String concern,
    required List<LawMatchResult> candidates,
  }) async {
    final pool = candidates.take(_candidateLimit).toList(growable: false);
    if (concern.trim().isEmpty || pool.isEmpty) {
      throw const GemmaArticleAssessmentException(
        'A concern and retrieved candidate articles are required.',
      );
    }
    final byId = <String, LawMatchResult>{
      for (final candidate in pool)
        normalizedArticleId(candidate.lawName, candidate.articleNumber):
            candidate,
    };
    final prompt = _buildPrompt(concern, pool);
    final requestBody = <String, Object?>{
      'model': 'gemma4-e4b',
      'messages': [
        {
          'role': 'system',
          'content': 'You are a cautious legal provision retrieval assistant.',
        },
        {'role': 'user', 'content': prompt},
      ],
      'temperature': 0,
      'max_tokens': 2048,
      'stream': false,
      'response_format': {
        'type': 'json_schema',
        'json_schema': {
          'name': 'article_selection',
          'strict': true,
          'schema': _selectionSchema,
        },
      },
    };

    final stopwatch = Stopwatch()..start();
    try {
      final payload = completionRequester == null
          ? await _requestCompletion(requestBody)
          : await completionRequester!(endpoint, requestBody, timeout);
      final output = _readStructuredOutput(payload);
      final accepted = <LawMatchResult>[];
      var rejectedIds = 0;
      var rejectedQuotes = 0;
      final seen = <String>{};
      for (final item in output.selected) {
        final id = item.id;
        if (!byId.containsKey(id)) {
          rejectedIds++;
          continue;
        }
        if (!seen.add(id)) continue;
        final candidate = byId[id]!;
        if (item.quote.isEmpty ||
            item.quote.length > 80 ||
            !(candidate.articleText ?? candidate.description).contains(
              item.quote,
            )) {
          rejectedQuotes++;
          continue;
        }
        accepted.add(
          LawMatchResult(
            lawName: candidate.lawName,
            articleNumber: candidate.articleNumber,
            title: candidate.title,
            description: candidate.description,
            matchScore: candidate.matchScore,
            rawCosineScore: candidate.rawCosineScore,
            detailsReference: candidate.detailsReference,
            chapterTitle: candidate.chapterTitle,
            articleText: candidate.articleText,
            contextualExplanation: item.reason,
            supportingQuote: item.quote,
            hasAiExplanation: true,
            caseExplanationPoints: candidate.caseExplanationPoints,
            explanationVariants: candidate.explanationVariants,
            defaultExplanationLanguage: candidate.defaultExplanationLanguage,
          ),
        );
      }
      stopwatch.stop();
      if (rejectedIds > 0 || rejectedQuotes > 0) {
        developer.log(
          'Rejected Gemma selections: invalidIds=$rejectedIds '
          'invalidQuotes=$rejectedQuotes',
          name: 'catol.gemma',
        );
      }
      return GemmaArticleAssessment(
        decision: output.decision,
        results: List.unmodifiable(
          output.decision == GemmaArticleDecision.select
              ? accepted
              : const <LawMatchResult>[],
        ),
        explanation: output.explanation,
        elapsed: stopwatch.elapsed,
        rejectedIds: rejectedIds,
        rejectedQuotes: rejectedQuotes,
      );
    } on GemmaArticleAssessmentException {
      rethrow;
    } on TimeoutException {
      throw const GemmaArticleAssessmentException(
        'Gemma did not respond before the local inference timeout. '
        'Check the local model server and try again.',
      );
    } on SocketException catch (error, stackTrace) {
      developer.log(
        'Gemma connection failed at $endpoint',
        name: 'catol.gemma',
        error: error,
        stackTrace: stackTrace,
      );
      throw GemmaArticleAssessmentException(
        'Gemma connection failed at $endpoint: ${error.message} '
        '(OS error: ${error.osError?.message ?? 'unknown'}, '
        'code: ${error.osError?.errorCode ?? 'unknown'}). '
        'Baseline results are unchanged.',
      );
    } on HttpException catch (error) {
      throw GemmaArticleAssessmentException(
        'The local Gemma request failed: ${error.message}',
      );
    } on FormatException catch (error, stackTrace) {
      developer.log(
        'The local Gemma response was invalid.',
        name: 'catol.gemma',
        error: error,
        stackTrace: stackTrace,
      );
      throw GemmaArticleAssessmentException(
        'Gemma response could not be processed: ${error.message}. '
        'Baseline results are unchanged.',
      );
    }
  }

  Future<Object?> _requestCompletion(Map<String, Object?> requestBody) async {
    final client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(requestBody)));
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw GemmaArticleAssessmentException(
          'The local Gemma server returned HTTP ${response.statusCode}.',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maximumResponseBytes) {
          throw const GemmaArticleAssessmentException(
            'The local Gemma response exceeded the size limit.',
          );
        }
      }
      return jsonDecode(utf8.decode(bytes));
    } finally {
      client.close(force: true);
    }
  }

  String _buildPrompt(String concern, List<LawMatchResult> candidates) {
    return 'Assess which supplied Philippine legal article provisions '
        'directly address the user’s stated facts. Related provisions are not '
        'necessarily directly responsive. Use only supplied article text; do '
        'not invent law or assume missing facts. Select zero to three '
        'candidate IDs in relevance order. For each, provide an exact quote '
        'of at most 80 characters copied verbatim from that candidate and a '
        'reason of at most 15 words. Keep the overall explanation to one '
        'short sentence. If no candidate directly fits, abstain. If a '
        'material fact prevents assessment, clarify and select no articles. '
        'Never output an ID outside the candidate list.\n\n'
        'USER CONCERN:\n$concern\n\n'
        'CANDIDATES (IDs and official article text):\n'
        '${jsonEncode([
          for (final candidate in candidates) {'id': normalizedArticleId(candidate.lawName, candidate.articleNumber), 'text': candidate.articleText ?? candidate.description},
        ])}';
  }

  _GemmaOutput _readStructuredOutput(Object? payload) {
    if (payload is! Map ||
        payload['choices'] is! List ||
        (payload['choices'] as List).isEmpty) {
      throw const FormatException('Gemma response has no choices.');
    }
    final choice = (payload['choices'] as List).first;
    if (choice is! Map ||
        choice['message'] is! Map ||
        (choice['message'] as Map)['content'] is! String) {
      throw const FormatException('Gemma response has no message content.');
    }
    final message = choice['message'] as Map;
    final content = (message['content'] as String).trim();
    final finishReason = choice['finish_reason'];
    if (content.isEmpty) {
      throw FormatException(
        'empty message content (finish_reason: $finishReason)',
      );
    }
    if (finishReason == 'length') {
      throw const FormatException(
        'generation stopped at the token limit; increase max_tokens or reduce candidate text',
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      // Do not accept partial JSON or remove source-quote validation.
      throw FormatException(
        'message content is not valid JSON (finish_reason: $finishReason; '
        'content length: ${content.length})',
      );
    }
    if (decoded is! Map ||
        decoded['decision'] is! String ||
        decoded['selected'] is! List ||
        decoded['explanation'] is! String) {
      throw const FormatException('Gemma response has an invalid shape.');
    }
    final decision = switch (decoded['decision']) {
      'select' => GemmaArticleDecision.select,
      'abstain' => GemmaArticleDecision.abstain,
      'clarify' => GemmaArticleDecision.clarify,
      _ => throw const FormatException('Gemma returned an invalid decision.'),
    };
    final rawSelections = decoded['selected'] as List;
    if (rawSelections.length > 3) {
      throw const FormatException('Gemma selected more than three articles.');
    }
    final selected = <_GemmaSelection>[];
    for (final value in rawSelections) {
      if (value is! Map ||
          value['id'] is! String ||
          value['source_quote'] is! String ||
          value['reason'] is! String) {
        throw const FormatException(
          'Gemma returned an invalid article selection.',
        );
      }
      selected.add(
        _GemmaSelection(
          id: value['id'] as String,
          quote: (value['source_quote'] as String).trim(),
          reason: (value['reason'] as String).trim(),
        ),
      );
    }
    if (decision != GemmaArticleDecision.select && selected.isNotEmpty) {
      throw const FormatException(
        'Gemma selected articles despite abstaining or requesting clarification.',
      );
    }
    final explanation = (decoded['explanation'] as String).trim();
    if (explanation.isEmpty || explanation.length > 160) {
      throw const FormatException('Gemma returned an invalid explanation.');
    }
    return _GemmaOutput(
      decision: decision,
      selected: selected,
      explanation: explanation,
    );
  }
}

class _GemmaOutput {
  const _GemmaOutput({
    required this.decision,
    required this.selected,
    required this.explanation,
  });

  final GemmaArticleDecision decision;
  final List<_GemmaSelection> selected;
  final String explanation;
}

class _GemmaSelection {
  const _GemmaSelection({
    required this.id,
    required this.quote,
    required this.reason,
  });

  final String id;
  final String quote;
  final String reason;
}
