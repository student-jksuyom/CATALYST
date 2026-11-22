// Named parameters cannot be private, so the lint does not apply.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';

import '../models/law_match_result.dart';
import 'catalyst_local_retrieval_service.dart';
import 'explanation_builder.dart';
import 'explanation_language.dart';
import 'followup_service.dart';
import 'jurisprudence_service.dart';
import 'query_analysis.dart';

enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.isError = false,
    this.mode,
    this.sourceNote,
  });

  final ChatRole role;
  final String text;
  final bool isError;

  /// Whether an assistant answer used the internet; null for other messages.
  final RetrievalMode? mode;

  /// Short caption shown under an answer, such as the sources consulted.
  final String? sourceNote;
}

enum FollowUpIntent {
  why,
  simpler,
  otherLaws,
  missingFacts,
  procedure,
  newFact,
  jurisprudence,
  unclear,
}

bool _hasAny(String text, List<String> needles) =>
    needles.any((needle) => text.contains(needle));

FollowUpIntent classifyFollowUp(String message) {
  final text = ' ${message.toLowerCase().replaceAll(RegExp(r'\s+'), ' ')} ';
  if (_hasAny(text, [
    'jurisprudence',
    'case law',
    'supreme court',
    'precedent',
    'ruling',
    'desisyon',
    'hatol',
    'korte suprema',
    'similar case',
    'related case',
    'g.r.',
    'are there already similar',
    'similar cases of mine',
    'existing cases',
    'past cases',
    'previous cases',
    'related jurisprudence',
    'case like mine',
  ])) {
    return FollowUpIntent.jurisprudence;
  }
  if (_hasAny(text, [' what if', ' paano kung', ' pano kung', ' suppose '])) {
    return FollowUpIntent.newFact;
  }
  if (_hasAny(text, [
    'what facts',
    'facts do i need',
    'facts should',
    'clarify',
    'missing',
    'kulang',
    'anong detalye',
    'ano pang',
    'what details',
  ])) {
    return FollowUpIntent.missingFacts;
  }
  if (_hasAny(text, [
    'other law',
    'another law',
    'related law',
    'what else',
    'ibang batas',
    'iba pang batas',
    'relevant na batas',
    'iba pa bang',
  ])) {
    return FollowUpIntent.otherLaws;
  }
  if (_hasAny(text, [
    'process',
    'proseso',
    'how do i file',
    'where do i file',
    'paano mag-file',
    'magkano',
    'how long',
    'gaano katagal',
    'steps',
    'hakbang',
  ])) {
    return FollowUpIntent.procedure;
  }
  if (_hasAny(text, [
    'simple',
    'simpler',
    'easier',
    'madali',
    'plain',
    'ipaliwanag',
    'paliwanag',
  ])) {
    return FollowUpIntent.simpler;
  }
  if (_hasAny(text, [
    ' why ',
    'bakit',
    'relevant',
    'applicable',
    'apply',
    ' best ',
  ])) {
    return FollowUpIntent.why;
  }
  return FollowUpIntent.unclear;
}

/// Context for one legal case. A new case gets a new instance, so facts and
/// results from an earlier case can never leak into it.
class CaseConversation extends ChangeNotifier {
  CaseConversation.empty({
    required CatalystRetrievalService service,
    FollowUpAnswerer? followUp,
    Future<JurisprudenceIndex> Function()? loadCases,
  }) : _service = service,
       _followUp = followUp,
       _loadCases = loadCases ?? JurisprudenceIndex.shared;

  CaseConversation.forResponse({
    required CatalystRetrievalService service,
    required String narrative,
    required CatalystMatchResponse response,
    FollowUpAnswerer? followUp,
    Future<JurisprudenceIndex> Function()? loadCases,
  }) : _service = service,
       _followUp = followUp,
       _loadCases = loadCases ?? JurisprudenceIndex.shared,
       _narrative = narrative,
       _processed = response.processedQuery,
       _results = response.results,
       _others = response.otherCandidates,
       _analysis = response.analysis;

  /// Chat about a single stored article, with no stated facts.
  CaseConversation.forArticle({
    required CatalystRetrievalService service,
    required LawMatchResult result,
    FollowUpAnswerer? followUp,
    Future<JurisprudenceIndex> Function()? loadCases,
  }) : _service = service,
       _followUp = followUp,
       _loadCases = loadCases ?? JurisprudenceIndex.shared,
       _results = [result];

  final CatalystRetrievalService _service;
  final FollowUpAnswerer? _followUp;
  final Future<JurisprudenceIndex> Function() _loadCases;
  final List<ChatMessage> _messages = [];
  final List<String> _newFacts = [];
  String? _narrative;
  String _processed = '';
  RetrievalMode? _answerMode;
  String? _answerNote;
  List<LawMatchResult> _results = const [];
  List<LawMatchResult> _others = const [];
  QueryAnalysis? _analysis;
  LawMatchResult? _focus;
  bool _isBusy = false;

  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<LawMatchResult> get results => _results;
  List<String> get newFacts => List.unmodifiable(_newFacts);
  String? get narrative => _narrative;
  bool get isBusy => _isBusy;
  bool get usesOnlineFollowUp => _followUp != null;

  /// The provision the user is currently asking about.
  void focusOn(LawMatchResult? result) => _focus = result;

  LawMatchResult? get _target =>
      _focus ?? (_results.isEmpty ? null : _results.first);

  Future<void> send(String rawMessage) async {
    final message = rawMessage.trim();
    if (message.isEmpty || _isBusy) return;
    _messages.add(ChatMessage(role: ChatRole.user, text: message));
    _isBusy = true;
    notifyListeners();
    try {
      _answerMode = null;
      _answerNote = null;
      final text = await _reply(message);
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          text: text,
          mode: _answerMode,
          sourceNote: _answerNote,
        ),
      );
    } on CatalystRetrievalException catch (error) {
      _messages.add(
        ChatMessage(
          role: ChatRole.assistant,
          text: 'I could not complete that: ${error.message}',
          isError: true,
        ),
      );
    } catch (_) {
      _messages.add(
        const ChatMessage(
          role: ChatRole.assistant,
          text: 'Something went wrong while answering. Please try again.',
          isError: true,
        ),
      );
    } finally {
      _isBusy = false;
      notifyListeners();
    }
  }

  Future<String> _reply(String message) async {
    if (_narrative == null && _results.isEmpty) {
      // No case yet: the first message is the case narrative.
      return _runRetrieval(message, isNewCase: true);
    }
    final intent = classifyFollowUp(message);
    switch (intent) {
      case FollowUpIntent.why:
        return _statutoryAnswer(_explainWhy);
      case FollowUpIntent.simpler:
        return _statutoryAnswer(_explainSimply);
      case FollowUpIntent.otherLaws:
        return _statutoryAnswer(_otherLaws);
      case FollowUpIntent.missingFacts:
        return _statutoryAnswer(_missingFacts);
      case FollowUpIntent.jurisprudence:
        return _grounded(message, () => _noCasesOffline);
      case FollowUpIntent.procedure:
        return _statutoryAnswer(
          () =>
              'The local corpus holds statutory text only. It does not '
              'include court procedure, filing steps, deadlines for filing or '
              'fees, so I cannot answer that from the corpus. Please ask the '
              'relevant court or agency, or a qualified lawyer.',
        );
      case FollowUpIntent.newFact:
        return _runRetrieval(message, isNewCase: false);
      case FollowUpIntent.unclear:
        if (wordTokens(message).length < 4) {
          return 'I am not sure what you would like to know. You can ask: '
              '"Why is this article relevant?", "Explain it in simpler '
              'words", "What other law might apply?", "What facts should I '
              'clarify?" or describe a new fact, such as "What if we were '
              'not married?"';
        }
        return _runRetrieval(message, isNewCase: false, assumedFact: true);
    }
  }

  static const _noCasesOffline =
      'I can only list decisions from the on-device jurisprudence dataset '
      'while offline.';

  List<LawMatchResult> _articlesForPrompt() {
    final seen = <String>{};
    return [?_target, ..._results, ..._others]
        .where((r) => seen.add('${r.lawName}|${r.articleNumber}'))
        .take(8)
        .toList();
  }

  String _statutoryAnswer(String Function() answer) {
    _answerMode = RetrievalMode.onDevice;
    return answer();
  }

  /// Answers from the retrieved articles plus the best-matching decisions of
  /// the bundled jurisprudence dataset. Online it asks the proxy for a plain
  /// answer bound to those sources; offline it keeps the on-device answer and
  /// lists the matching decisions.
  Future<String> _grounded(String message, String Function() offline) async {
    final articles = _articlesForPrompt();
    if (articles.isEmpty) {
      _answerMode = RetrievalMode.onDevice;
      return 'No provision has been matched yet. The local corpus may not '
          'cover your concern; please add detail or consult a qualified lawyer.';
    }
    final index = await _loadCases();
    final hits = index.search(
      '$message $_processed',
      articles: articles,
      limit: 4,
    );
    final cases = [for (final hit in hits) hit.jurisprudence];

    final answerer = _followUp;
    if (answerer != null) {
      final answer = await answerer.answer(
        question: message,
        narrative: _narrative ?? '',
        language: detectQueryLanguage(message).code,
        articles: articles,
        cases: cases,
      );
      if (answer != null) {
        _answerMode = RetrievalMode.online;
        _answerNote =
            'Online-generated answer; its legal claims and citations have '
            'not been verified against the supplied sources.';
        final buffer = StringBuffer(answer.text);
        if (answer.citedCases.isNotEmpty) {
          buffer.writeln('\n\nDecisions cited (from the dataset):');
          for (final c in answer.citedCases) {
            buffer.writeln('- ${c.citation}');
          }
        }
        if (answer.searchedWeb) {
          buffer.writeln(
            '\nOnline sources consulted (not verified against the corpus): '
            '${answer.webSources.join('; ')}.',
          );
        }
        buffer.write(
          '\nThe online answer may contain unsupported claims or citations; '
          'verify them against the cited sources. $legalInformationNotice',
        );
        return buffer.toString();
      }
      _answerMode = RetrievalMode.onDeviceFallback;
    } else {
      _answerMode = RetrievalMode.onDevice;
    }

    final buffer = StringBuffer(offline());
    if (hits.isNotEmpty) {
      buffer.writeln(
        '\n\nRelated Supreme Court decisions in the on-device dataset '
        '(ranked by text similarity; not confirmed to apply to your facts):',
      );
      for (final hit in hits.take(3)) {
        final c = hit.jurisprudence;
        buffer.writeln(
          '- ${c.citation}: ${firstStatement(c.holding, maxLength: 180)}',
        );
      }
    }
    return buffer.toString().trimRight();
  }

  String _explainWhy() {
    final target = _target;
    if (target == null) {
      return 'No provision has been matched yet, so there is nothing to '
          'explain. Describe your situation first.';
    }
    final buffer = StringBuffer(
      'Why ${target.lawName} ${target.articleNumber} may be relevant:\n',
    );
    final text = target.articleText;
    if (text == null || text.trim().isEmpty) {
      buffer.writeln('- The retrieved provision text is unavailable.');
    } else {
      buffer.writeln('- Provision excerpt: "${firstStatement(text)}"');
      buffer.writeln('- ${_possibleConnection(target, _caseFacts)}');
      final issue =
          knownCorpusIssues[normalizedArticleId(
            target.lawName,
            target.articleNumber,
          )];
      if (issue != null) buffer.writeln('- $issue');
    }
    final story = _narrative;
    if (story != null && story.isNotEmpty) {
      buffer.writeln(
        '\nYour stated facts: "${firstStatement(story, maxLength: 200)}"',
      );
    }
    if (_newFacts.isNotEmpty) {
      buffer.writeln(
        'Facts added later: ${_newFacts.map((f) => '"$f"').join('; ')}',
      );
    }
    if (text != null && text.trim().isNotEmpty) {
      buffer.writeln(
        '\nUncertain: whether every condition in the quoted provision is '
        'met by your facts.',
      );
    }
    buffer.write(legalInformationNotice);
    return buffer.toString();
  }

  String _explainSimply() {
    final target = _target;
    if (target == null) {
      return 'No provision has been matched yet, so there is nothing to '
          'simplify.';
    }
    final provision = target.articleText;
    if (provision == null || provision.trim().isEmpty) {
      return 'The retrieved provision text is unavailable, so I cannot '
          'simplify it. $legalInformationNotice';
    }
    final text = provision.replaceAll(RegExp(r'\s+'), ' ').trim();
    final clauses = text
        .split(RegExp(r'(?<=[.;:])\s+(?=[A-Z(])'))
        .map((clause) => clause.trim())
        .where((clause) => clause.length > 3)
        .take(6)
        .toList();
    final buffer = StringBuffer(
      '${target.lawName} ${target.articleNumber}, split into shorter parts:\n',
    );
    for (final clause in clauses) {
      buffer.writeln('- ${firstStatement(clause, maxLength: 220)}');
    }
    buffer.writeln(
      '\nThese are excerpts, not a substitute for the full provision. I will '
      'not paraphrase them, because that could change their legal meaning.',
    );
    buffer.write(legalInformationNotice);
    return buffer.toString();
  }

  String _otherLaws() {
    final shown = {
      for (final result in _results)
        '${result.lawName}|${result.articleNumber}',
    };
    final others = [
      ..._results.where((r) => r != _target),
      ..._others.where(
        (r) => !shown.contains('${r.lawName}|${r.articleNumber}'),
      ),
    ].take(3).toList();
    if (others.isEmpty) {
      return 'No other provision in the local corpus was similar enough to '
          'your description. The corpus may not contain the law you need.';
    }
    final buffer = StringBuffer(
      'Other provisions that came close (ranked lower, not necessarily '
      'applicable):\n',
    );
    for (final result in others) {
      final text = result.articleText;
      buffer.writeln('- ${result.lawName} ${result.articleNumber}:');
      if (text == null || text.trim().isEmpty) {
        buffer.writeln(
          '  Provision text unavailable; relevance cannot be assessed.',
        );
      } else {
        buffer.writeln('  "${firstStatement(text, maxLength: 160)}"');
        buffer.writeln('  ${_possibleConnection(result, _caseFacts)}');
      }
    }
    buffer.write(legalInformationNotice);
    return buffer.toString();
  }

  String get _caseFacts => [?_narrative, ..._newFacts].join(' ');

  String _possibleConnection(LawMatchResult result, String facts) {
    if (facts.trim().isEmpty) {
      return 'No facts were provided to compare with this provision.';
    }
    final text = result.articleText;
    if (text == null || text.trim().isEmpty) {
      return 'The provision text is unavailable, so its relevance is uncertain.';
    }
    final shared = sharedWording(
      queryTexts: [facts],
      articleText: text,
    ).where((word) => !RegExp(r'^\d+$').hasMatch(word)).toList();
    if (shared.isEmpty) {
      return 'The search found a possible meaning match, but no shared '
          'wording was found. Applicability is uncertain.';
    }
    return 'Possible connection: your concern and this provision share '
        'wording related to ${shared.join(', ')}. This does not establish '
        'that the provision applies.';
  }

  String _missingFacts() {
    final domain = _analysis?.domain ?? QueryDomain.unknown;
    final buffer = StringBuffer(
      'Facts that would help decide which provisions apply (these are '
      'questions, not assumptions):\n',
    );
    for (final question in missingFactQuestions(domain)) {
      buffer.writeln('- $question');
    }
    buffer.write(
      'You can answer by describing the new facts, for example "What if we '
      'were not married?"',
    );
    return buffer.toString();
  }

  Future<String> _runRetrieval(
    String text, {
    required bool isNewCase,
    bool assumedFact = false,
  }) async {
    final hasNarrative = _narrative != null;
    isNewCase = isNewCase || !hasNarrative;
    final combined = isNewCase ? text : '${_narrative!} $text';
    final response = await _service.matchConcern(combined);
    _answerMode = RetrievalMode.onDevice;

    if (response.clarifyingQuestion != null) {
      return response.clarifyingQuestion!;
    }
    final previousIds = {
      for (final result in _results)
        normalizedArticleId(result.lawName, result.articleNumber),
    };

    if (isNewCase) {
      _narrative = text;
    } else {
      _newFacts.add(text);
    }
    _results = response.results;
    _others = response.otherCandidates;
    _analysis = response.analysis;
    _focus = null;

    if (response.results.isEmpty) {
      return '${response.warning}\nI would rather show nothing than an '
          'unrelated provision. The local corpus may not contain the law '
          'needed for your concern.';
    }

    final newIds = {
      for (final result in response.results)
        normalizedArticleId(result.lawName, result.articleNumber),
    };
    final buffer = StringBuffer();
    if (isNewCase) {
      buffer.writeln('Here are the closest provisions in the local corpus:');
    } else {
      if (assumedFact) {
        buffer.writeln('I read this as additional facts.');
      }
      buffer.writeln(
        'Noted as a new fact (not part of your original account): "$text"',
      );
      buffer.writeln(
        previousIds.difference(newIds).isEmpty &&
                newIds.difference(previousIds).isEmpty
            ? 'The same provisions still rank highest.'
            : 'This changes which provisions rank highest, so I searched again:',
      );
    }
    for (final result in response.results) {
      final provision = result.articleText;
      buffer.writeln('- ${result.lawName} ${result.articleNumber}:');
      if (provision == null || provision.trim().isEmpty) {
        buffer.writeln(
          '  Provision text unavailable; relevance cannot be assessed.',
        );
      } else {
        buffer.writeln('  "${firstStatement(provision, maxLength: 160)}"');
        buffer.writeln('  ${_possibleConnection(result, combined)}');
      }
    }
    buffer.write(
      'These are possible matches; the local corpus may not '
      'cover every relevant law. ',
    );
    buffer.write(legalInformationNotice);
    return buffer.toString();
  }
}
