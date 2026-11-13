import 'package:flutter/material.dart';

import 'data/mock_xai_chat_content.dart';
import 'models/law_match_result.dart';
import 'services/case_conversation.dart';
import 'services/catalyst_local_retrieval_service.dart' show RetrievalMode;
import 'services/explanation_builder.dart';

class XaiChatbotScreen extends StatefulWidget {
  const XaiChatbotScreen({
    this.result,
    this.initialUserMessage = '',
    this.conversation,
    super.key,
  });

  final CaseConversation? conversation;
  final LawMatchResult? result;
  final String initialUserMessage;

  @override
  State<XaiChatbotScreen> createState() => _XaiChatbotScreenState();
}

class _XaiChatbotScreenState extends State<XaiChatbotScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _blue = Color(0xFF3E86F8);
  static const _purple = Color(0xFF8254F2);

  final _questionController = TextEditingController();
  final _conversationController = ScrollController();
  final List<String> _sentQuestions = [];

  static const _liveSuggestions = [
    'Why is this relevant?',
    'Explain it in simpler words',
    'What other law might apply?',
    'What facts should I clarify?',
  ];

  @override
  void initState() {
    super.initState();
    final conversation = widget.conversation;
    if (conversation != null) {
      conversation.focusOn(widget.result);
      conversation.addListener(_scrollToEnd);
    }
  }

  @override
  void dispose() {
    widget.conversation?.removeListener(_scrollToEnd);
    _questionController.dispose();
    _conversationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversation;
    if (conversation == null) {
      return _buildScaffold(context);
    }
    return ListenableBuilder(
      listenable: conversation,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    final result = widget.result;
    final conversation = widget.conversation;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _buildHeader(context),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(32, 12, 32, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  result == null
                      ? (conversation == null
                            ? 'General chat preview. AI responses are not connected yet.'
                            : conversation.usesOnlineFollowUp
                            ? 'Article retrieval stays on-device. XAI follow-up '
                                  'may use the online service and jurisprudence '
                                  'dataset.'
                            : 'Describe your situation in English, Tagalog or '
                                  'Taglish. Retrieval and follow-up are on this '
                                  'device and are not legal advice.')
                      : 'Article retrieval is on-device. Ask XAI follow-up for '
                            'jurisprudence context or a simpler explanation.',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    height: 1.4,
                    color: Color(0xFFA6A6A6),
                  ),
                ),
              ),
            ),
            if (conversation?.usesOnlineFollowUp ?? false)
              const Padding(
                padding: EdgeInsets.fromLTRB(32, 10, 32, 0),
                child: _OnlineFollowUpNotice(),
              ),
            Expanded(
              child: Semantics(
                label: result == null
                    ? 'General chat preview'
                    : 'Conversation about ${result.lawName}, '
                          '${result.articleNumber}',
                child: ListView(
                  controller: _conversationController,
                  padding: const EdgeInsets.fromLTRB(32, 40, 32, 20),
                  children: [
                    if (result != null) ...[
                      _LawResultCard(result: result),
                      const SizedBox(height: 28),
                      if (conversation == null) ...[
                        _UserMessageBubble(
                          message: widget.initialUserMessage.isEmpty
                              ? MockXaiChatContent.question
                              : widget.initialUserMessage,
                        ),
                        const SizedBox(height: 26),
                        const _PreviewResponseBubble(),
                      ],
                    ] else if (conversation == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Center(
                          child: Text(
                            'General chat preview\n'
                            'Responses are not connected yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              height: 1.5,
                              color: Color(0xFFA6A6A6),
                            ),
                          ),
                        ),
                      )
                    else if (conversation.messages.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 24),
                        child: Center(
                          child: Text(
                            'Describe your legal concern to get started.\n'
                            'Matches come from the legal corpus and the jurisprudence dataset.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              height: 1.5,
                              color: Color(0xFFA6A6A6),
                            ),
                          ),
                        ),
                      ),
                    for (final question in _sentQuestions) ...[
                      const SizedBox(height: 16),
                      _UserMessageBubble(message: question),
                    ],
                    if (conversation != null) ...[
                      for (final message in conversation.messages) ...[
                        const SizedBox(height: 16),
                        message.role == ChatRole.user
                            ? _UserMessageBubble(message: message.text)
                            : _AssistantBubble(
                                text: message.text,
                                isError: message.isError,
                                mode: message.mode,
                                sourceNote: message.sourceNote,
                              ),
                      ],
                      if (conversation.isBusy) ...[
                        const SizedBox(height: 16),
                        const _AssistantBubble(text: 'Searching the corpus...'),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            if (result != null || conversation != null) _buildFaqSuggestions(),
            _buildQuestionInput(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          IconButton(
            onPressed: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: const Icon(
              Icons.chevron_left_rounded,
              color: _purple,
              size: 30,
            ),
            tooltip: 'Back',
          ),
          const SizedBox(width: 2),
          const Text(
            'Ask CATALYST',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 23,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: _navy,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFaqSuggestions() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(54, 0, 32, 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final suggestion
                in widget.conversation != null
                    ? _liveSuggestions
                    : MockXaiChatContent.faqSuggestions) ...[
              if (suggestion !=
                  (widget.conversation != null
                          ? _liveSuggestions
                          : MockXaiChatContent.faqSuggestions)
                      .first)
                const SizedBox(height: 4),
              Material(
                color: const Color(0xFF3E86F8).withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(22),
                child: InkWell(
                  onTap: () {
                    if (widget.conversation != null) {
                      _sendQuestion(suggestion);
                      return;
                    }
                    _questionController
                      ..text = suggestion
                      ..selection = TextSelection.collapsed(
                        offset: suggestion.length,
                      );
                  },
                  borderRadius: BorderRadius.circular(22),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 7,
                    ),
                    child: Text(
                      suggestion,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        height: 1.2,
                        color: _blue,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildQuestionInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
      child: Container(
        constraints: const BoxConstraints(minHeight: 68, maxHeight: 140),
        padding: const EdgeInsets.fromLTRB(16, 8, 14, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFD8D8D8)),
          borderRadius: BorderRadius.circular(36),
          boxShadow: const [
            BoxShadow(
              color: Color(0x10000000),
              blurRadius: 16,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _questionController,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                minLines: 1,
                maxLines: 4,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  color: _navy,
                ),
                decoration: const InputDecoration(
                  hintText: 'Type here...',
                  hintStyle: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    color: Color(0xFFA6A6A6),
                  ),
                  border: InputBorder.none,
                  isCollapsed: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 44,
              height: 44,
              child: IconButton.filled(
                onPressed: () => _sendQuestion(),
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFF8C68F5),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.send_rounded, size: 23),
                tooltip: 'Send question',
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _sendQuestion([String? preset]) {
    final question = (preset ?? _questionController.text).trim();
    if (question.isEmpty) {
      return;
    }

    final conversation = widget.conversation;
    if (conversation != null) {
      _questionController.clear();
      conversation.send(question);
      return;
    }

    setState(() {
      _sentQuestions.add(question);
      _questionController.clear();
    });
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_conversationController.hasClients) {
        _conversationController.animateTo(
          _conversationController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }
}

class _OnlineFollowUpNotice extends StatelessWidget {
  const _OnlineFollowUpNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('online-followup-privacy-notice'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF7E5),
        border: Border.all(color: const Color(0xFFE7C878)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        'XAI follow-up may send your question, case narrative, retrieved '
        'articles and relevant decisions to CATALYST’s proxy and Google '
        'Gemini. Avoid names and contact details. Article retrieval itself '
        'stays on-device.',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          height: 1.35,
          color: Color(0xFF594A25),
        ),
      ),
    );
  }
}

class _UserMessageBubble extends StatelessWidget {
  const _UserMessageBubble({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF8254F2),
          borderRadius: BorderRadius.circular(15),
        ),
        child: Text(
          message,
          textAlign: TextAlign.right,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            height: 1.3,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _AssistantBubble extends StatelessWidget {
  const _AssistantBubble({
    required this.text,
    this.isError = false,
    this.mode,
    this.sourceNote,
  });

  final String text;
  final bool isError;
  final RetrievalMode? mode;
  final String? sourceNote;

  @override
  Widget build(BuildContext context) {
    final (IconData, Color, String)? tag = switch (mode) {
      RetrievalMode.online => (
        Icons.cloud_done_outlined,
        const Color(0xFF1E8E3E),
        'Online',
      ),
      RetrievalMode.onDeviceFallback => (
        Icons.cloud_off_outlined,
        const Color(0xFFC77700),
        'Offline (online unavailable)',
      ),
      RetrievalMode.onDevice => (
        Icons.phone_android_rounded,
        const Color(0xFF5F6B85),
        'Offline (on-device)',
      ),
      null => null,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Image.asset(
          'assets/images/xai_profile_bubble.png',
          width: 34,
          height: 34,
          fit: BoxFit.contain,
        ),
        const SizedBox(width: 1),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 17),
            decoration: BoxDecoration(
              color: isError
                  ? const Color(0x14D32F2F)
                  : const Color(0xFF3E86F8).withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (tag != null) ...[
                  Row(
                    key: const ValueKey('answer-source-tag'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(tag.$1, size: 15, color: tag.$2),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          tag.$3,
                          style: TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: tag.$2,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                ],
                SelectableText(
                  text,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 12,
                    height: 1.4,
                    color: Color(0xFF1A307F),
                  ),
                ),
                if (sourceNote != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    sourceNote!,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF6B7490),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewResponseBubble extends StatelessWidget {
  const _PreviewResponseBubble();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Image.asset(
          'assets/images/xai_profile_bubble.png',
          width: 34,
          height: 34,
          fit: BoxFit.contain,
        ),
        const SizedBox(width: 1),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 17),
            decoration: BoxDecoration(
              color: const Color(0xFF3E86F8).withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'Preview example',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 9,
                      fontStyle: FontStyle.italic,
                      color: Color(0xFF7E8AA7),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text.rich(
                  TextSpan(
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      height: 1.4,
                      color: Color(0xFF1A307F),
                    ),
                    children: [
                      const TextSpan(
                        text: MockXaiChatContent.responseLead,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const TextSpan(
                        text: MockXaiChatContent.responseRemainder,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LawResultCard extends StatefulWidget {
  const _LawResultCard({required this.result});

  final LawMatchResult result;

  @override
  State<_LawResultCard> createState() => _LawResultCardState();
}

class _LawResultCardState extends State<_LawResultCard> {
  var _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final variant = _selectedVariant(result);
    final explanationPoints =
        (variant?.points ?? result.caseExplanationPoints)
            ?.map((point) => stripEmphasis(point).trim())
            .where((point) => point.isNotEmpty)
            .toList() ??
        [];
    final summary = result.hasAiExplanation
        ? ((explanationPoints.length > 1
                  ? explanationPoints[1]
                  : explanationPoints.isEmpty
                  ? null
                  : explanationPoints.first) ??
              result.contextualExplanation ??
              'No fact-specific explanation is available.')
        : 'No fact-specific explanation is available; retrieval similarity '
              'does not establish that this provision applies.';

    return Material(
      color: const Color(0xFF3E86F8).withValues(alpha: 0.09),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => setState(() => _isExpanded = !_isExpanded),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          result.lawName,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF3E86F8),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${result.articleNumber} - ${result.title}',
                          maxLines: _isExpanded ? null : 2,
                          overflow: _isExpanded ? null : TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Montserrat',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                            color: Color(0xFF1A307F),
                          ),
                        ),
                        if (!_isExpanded && summary.trim().isNotEmpty) ...[
                          const SizedBox(height: 5),
                          Text(
                            summary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              height: 1.35,
                              color: Color(0xFF1A307F),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(
                    _isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: const Color(0xFF3E86F8),
                    size: 24,
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: _isExpanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, right: 8),
                        child: _ExpandedLawResult(result: result),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExpandedLawResult extends StatelessWidget {
  const _ExpandedLawResult({required this.result});

  final LawMatchResult result;

  @override
  Widget build(BuildContext context) {
    final variant = _selectedVariant(result);
    final points =
        (variant?.points ??
                [
                  if (result.hasAiExplanation &&
                      result.contextualExplanation != null)
                    result.contextualExplanation!,
                ])
            .map((point) => stripEmphasis(point).trim())
            .where((point) => point.isNotEmpty)
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          result.description,
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            height: 1.4,
            color: Color(0xFF1A307F),
          ),
        ),
        if (result.articleText?.trim().isNotEmpty ?? false) ...[
          const SizedBox(height: 10),
          const Text(
            'Article text',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF3E86F8),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            result.articleText!.trim(),
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              height: 1.4,
              color: Color(0xFF1A307F),
            ),
          ),
        ],
        if (points.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text(
            'Why this may relate to your concern',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF3E86F8),
            ),
          ),
          for (final point in points)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '• ',
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      color: Color(0xFF1A307F),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      point,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 12,
                        height: 1.4,
                        color: Color(0xFF1A307F),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 10),
        Text(
          'Match score: ${result.matchScore.round()}%',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 11,
            color: Color(0xFF66758E),
          ),
        ),
      ],
    );
  }
}

ExplanationVariant? _selectedVariant(LawMatchResult result) {
  final variants = result.explanationVariants;
  if (variants == null || variants.isEmpty) return null;
  final preferred = result.defaultExplanationLanguage;
  return variants[preferred] ?? variants['en'] ?? variants.values.first;
}
