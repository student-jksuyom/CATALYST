import 'package:flutter/material.dart';

import 'models/law_match_result.dart';
import 'services/case_conversation.dart';
import 'services/explanation_builder.dart';
import 'services/explanation_language.dart';
import 'services/history_store.dart';
import 'xai_chatbot_screen.dart';

class LawDetailsScreen extends StatefulWidget {
  const LawDetailsScreen({
    required this.result,
    this.initialIsBookmarked = false,
    this.onBookmarkChanged,
    this.onBookmarkSave,
    this.conversation,
    super.key,
  });

  final CaseConversation? conversation;
  final LawMatchResult result;
  final bool initialIsBookmarked;
  final ValueChanged<bool>? onBookmarkChanged;
  final Future<void> Function(bool)? onBookmarkSave;

  @override
  State<LawDetailsScreen> createState() => _LawDetailsScreenState();
}

class _LawDetailsScreenState extends State<LawDetailsScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _blue = Color(0xFF3E86F8);
  static const _purple = Color(0xFF8254F2);

  late bool _isBookmarked;
  var _savingBookmark = false;

  Future<void> _toggleBookmark() async {
    final next = !_isBookmarked;
    final save = widget.onBookmarkSave;
    if (save == null) {
      setState(() => _isBookmarked = next);
      widget.onBookmarkChanged?.call(next);
      return;
    }
    setState(() => _savingBookmark = true);
    try {
      await save(next);
      if (mounted) {
        setState(() => _isBookmarked = next);
        widget.onBookmarkChanged?.call(next);
      }
    } on HistoryStorageException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save bookmark on this device.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _savingBookmark = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _isBookmarked = widget.initialIsBookmarked;
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return PopScope(
      canPop: !_savingBookmark,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _buildHeader(context),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(32, 14, 32, 24),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 320),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCECFE),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(
                          result.lawName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _blue,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Text(
                            _articleHeading(result),
                            style: const TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              height: 1.25,
                              letterSpacing: -0.25,
                              color: _navy,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _ScoreBadge(score: result.matchScore),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _ArticleText(text: result.articleText),
                    const SizedBox(height: 52),
                    _CaseExplanationCard(result: result),
                  ],
                ),
              ),
              _buildQuestionInput(),
            ],
          ),
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
            onPressed: _savingBookmark
                ? null
                : () {
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
            'Law Details',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 23,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: _navy,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: _savingBookmark ? null : _toggleBookmark,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 48, height: 48),
            icon: _BookmarkStateIcon(isBookmarked: _isBookmarked),
            tooltip: _isBookmarked ? 'Remove bookmark' : 'Bookmark',
          ),
        ],
      ),
    );
  }

  Widget _buildQuestionInput() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 10, 32, 24),
      child: Align(
        alignment: Alignment.center,
        child: SizedBox(
          width: 64,
          height: 64,
          child: FloatingActionButton(
            onPressed: _openXaiChat,
            backgroundColor: const Color(0xFF8E63F5),
            foregroundColor: Colors.white,
            tooltip: 'Ask a follow-up question',
            child: const Icon(Icons.chat_bubble, size: 32),
          ),
        ),
      ),
    );
  }

  Future<void> _openXaiChat() async {
    final conversation = widget.conversation;
    if (conversation?.usesOnlineFollowUp ?? false) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Online XAI follow-up'),
          content: const Text(
            'Your question, case narrative, retrieved articles and relevant '
            'decisions may be sent to CATALYST’s proxy and Google Gemini. '
            'Avoid names and contact details.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => XaiChatbotScreen(
          result: widget.result,
          initialUserMessage: '',
          conversation: conversation,
        ),
      ),
    );
    // Focus on this result for the conversation
    conversation?.focusOn(widget.result);
  }
}

class _BookmarkStateIcon extends StatelessWidget {
  const _BookmarkStateIcon({required this.isBookmarked});

  final bool isBookmarked;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: Center(
        child: Image.asset(
          isBookmarked
              ? 'assets/images/bookmark_filled.png'
              : 'assets/images/bookmark_outline.png',
          width: 22.3,
          height: 28,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final double score;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFFC0AFFC),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        '${score.round()}%',
        style: const TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1,
          color: Colors.white,
        ),
      ),
    );
  }
}

final _articlePrefix = RegExp(
  r'^\s*(?:Article|Art\.)\s*\S+?\.\s+',
  caseSensitive: false,
);
final _itemMarker = RegExp(r'(?:^|\s)\(((?:\d{1,2})|[a-mo-z])\)\s+(?=\S)');
const _abbreviations = [
  'no.',
  'nos.',
  'art.',
  'arts.',
  'sec.',
  'secs.',
  'par.',
  'vs.',
  'r.a.',
  'e.o.',
];

/// The corpus has no article names, so the heading shows the opening words of
/// the provision after the article number.
String _articleHeading(LawMatchResult result) {
  final number = result.articleNumber.replaceFirst(
    RegExp(r'^(?:Article|Art\.)\s*', caseSensitive: false),
    '',
  );
  final label = 'Article $number';
  var body = (result.articleText ?? '').replaceFirst(_articlePrefix, '').trim();
  body = body.replaceFirst(RegExp(r'^\([a-z0-9]+\)\s*'), '');
  if (body.isEmpty) {
    return result.title.isEmpty ? label : '$label - ${result.title}';
  }
  final stop = RegExp(r'[.;:]').firstMatch(body);
  var name = stop != null && stop.start >= 20
      ? body.substring(0, stop.start)
      : body;
  const maxLength = 70;
  var shortened = false;
  if (name.length > maxLength) {
    final cut = name.lastIndexOf(' ', maxLength);
    name = name.substring(0, cut > 20 ? cut : maxLength);
    shortened = true;
  }
  name = name.replaceFirst(RegExp(r'[\s,]+$'), '');
  return '$label: $name${shortened ? '\u2026' : ''}';
}

class _ArticleBlock {
  const _ArticleBlock(this.text, {this.marker});

  final String text;
  final String? marker;
}

List<_ArticleBlock> _splitArticle(String raw) {
  final text = raw
      .replaceFirst(_articlePrefix, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final markers = _itemMarker.allMatches(text).toList();
  final blocks = <_ArticleBlock>[];
  final introEnd = markers.isEmpty ? text.length : markers.first.start;
  blocks.addAll(_paragraphs(text.substring(0, introEnd)));
  for (var i = 0; i < markers.length; i++) {
    final end = i + 1 < markers.length ? markers[i + 1].start : text.length;
    final item = text.substring(markers[i].end, end).trim();
    if (item.isNotEmpty) {
      blocks.add(_ArticleBlock(item, marker: '(${markers[i].group(1)})'));
    }
  }
  return blocks;
}

List<_ArticleBlock> _paragraphs(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  final sentences = <String>[];
  var start = 0;
  for (final m in RegExp(
    r'[.!?]["\u201D]?\s+(?=[A-Z"\u201C])',
  ).allMatches(trimmed)) {
    final candidate = trimmed.substring(start, m.end).trim();
    final lastWord = candidate.split(' ').last.toLowerCase();
    if (_abbreviations.contains(lastWord)) continue;
    sentences.add(candidate);
    start = m.end;
  }
  if (start < trimmed.length) sentences.add(trimmed.substring(start).trim());

  final paragraphs = <_ArticleBlock>[];
  var current = '';
  for (final sentence in sentences) {
    if (current.isNotEmpty && current.length + sentence.length > 320) {
      paragraphs.add(_ArticleBlock(current));
      current = sentence;
    } else {
      current = current.isEmpty ? sentence : '$current $sentence';
    }
  }
  if (current.isNotEmpty) paragraphs.add(_ArticleBlock(current));
  return paragraphs;
}

class _ArticleText extends StatefulWidget {
  const _ArticleText({required this.text});

  final String? text;

  @override
  State<_ArticleText> createState() => _ArticleTextState();
}

class _ArticleTextState extends State<_ArticleText> {
  static const _maxCollapsedLines = 12;
  static const _markerWidth = 34.0;
  static const _purple = Color(0xFF8254F2);
  static const _style = TextStyle(
    fontFamily: 'Inter',
    fontSize: 14,
    height: 1.5,
    color: Color(0xFF1A307F),
  );

  bool _expanded = false;

  int _lines(String text, double width, TextScaler scaler) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final count = painter.computeLineMetrics().length;
    painter.dispose();
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final articleText = widget.text?.trim();
    if (articleText == null || articleText.isEmpty) {
      return const Text(
        'Legal text will appear here when available.',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 14,
          height: 1.5,
          color: Color(0xFF858585),
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final blocks = _splitArticle(articleText);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = [
          for (final b in blocks)
            b.marker == null
                ? constraints.maxWidth
                : constraints.maxWidth - _markerWidth,
        ];
        final lineCounts = [
          for (var i = 0; i < blocks.length; i++)
            _lines(blocks[i].text, widths[i], scaler),
        ];
        final total = lineCounts.fold<int>(0, (a, b) => a + b);
        final needsToggle = total > _maxCollapsedLines + 3;

        final children = <Widget>[];
        var remaining = _maxCollapsedLines;
        for (var i = 0; i < blocks.length; i++) {
          if (needsToggle && !_expanded && remaining <= 0) break;
          final truncate =
              needsToggle && !_expanded && lineCounts[i] > remaining;
          final block = blocks[i];
          final body = Text(
            block.text,
            textAlign: TextAlign.justify,
            maxLines: truncate ? remaining : null,
            overflow: truncate ? TextOverflow.ellipsis : TextOverflow.clip,
            style: _style,
          );
          if (children.isNotEmpty) {
            children.add(SizedBox(height: block.marker == null ? 10 : 6));
          }
          children.add(
            block.marker == null
                ? body
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: _markerWidth,
                        child: Text(block.marker!, style: _style),
                      ),
                      Expanded(child: body),
                    ],
                  ),
          );
          remaining -= lineCounts[i];
          if (truncate) break;
        }
        if (needsToggle) {
          children.add(
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: _purple,
                  padding: const EdgeInsets.only(top: 8),
                  minimumSize: const Size(0, 36),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  _expanded ? 'See less' : 'See more',
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

class _CaseExplanationCard extends StatefulWidget {
  const _CaseExplanationCard({required this.result});

  final LawMatchResult result;

  @override
  State<_CaseExplanationCard> createState() => _CaseExplanationCardState();
}

class _CaseExplanationCardState extends State<_CaseExplanationCard> {
  static const _purple = Color(0xFF8254F2);
  static const _order = ['en', 'taglish', 'tl'];
  static const _headings = {
    'en': 'Why this may relate to your concern',
    'taglish': 'Paano ito posibleng may kaugnayan sa concern mo',
    'tl': 'Bakit ito posibleng may kaugnayan sa concern mo',
  };
  static const _reminderLabels = {
    'en': 'Reminder',
    'taglish': 'Reminder',
    'tl': 'Paalala',
  };

  String? _language;

  Map<String, ExplanationVariant> get _variants => {
    for (final code in _order) code: ?widget.result.explanationVariants?[code],
  };

  String? get _activeLanguage {
    final variants = _variants;
    if (variants.isEmpty) return null;
    if (variants.containsKey(_language)) return _language;
    final preferred = widget.result.defaultExplanationLanguage;
    return variants.containsKey(preferred) ? preferred : variants.keys.first;
  }

  @override
  Widget build(BuildContext context) {
    final variants = _variants;
    final language = _activeLanguage;
    final variant = language == null ? null : variants[language];
    final explanationPoints = widget.result.hasAiExplanation
        ? (variant?.points ??
                  [
                    if (widget.result.contextualExplanation != null)
                      widget.result.contextualExplanation!,
                  ])
              .map((point) => point.trim())
              .where((point) => point.isNotEmpty)
              .toList()
        : (variant?.points ?? widget.result.caseExplanationPoints ?? const [])
              .map((point) => point.trim())
              .where((point) => point.isNotEmpty)
              .toList();
    final reminders =
        variant?.reminders
            .map((point) => point.trim())
            .where((point) => point.isNotEmpty)
            .toList() ??
        const <String>[];
    final hasExplanation = explanationPoints.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFDCECFE),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/images/details_bulb.png',
                width: 40,
                height: 40,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  _headings[language] ?? _headings['en']!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: _LawDetailsScreenState._blue,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (variants.length > 1) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(Icons.translate_rounded, size: 18, color: _purple),
              for (final code in variants.keys)
                ChoiceChip(
                  label: Text(ExplanationLanguage.fromCode(code).label),
                  selected: code == language,
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  selectedColor: _purple,
                  backgroundColor: const Color(0xFFEDE7FD),
                  side: BorderSide.none,
                  labelStyle: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: code == language ? Colors.white : _purple,
                  ),
                  onSelected: (_) => setState(() => _language = code),
                ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        Text(
          widget.result.hasAiExplanation
              ? 'AI-generated from your concern and the retrieved article; it describes a possible connection, not a legal conclusion.'
              : 'On-device retrieval only. Similarity does not establish that this provision applies.',
          style: const TextStyle(
            fontFamily: 'Inter',
            fontSize: 12,
            height: 1.4,
            color: Color(0xFF66758E),
          ),
        ),
        const SizedBox(height: 10),
        if (hasExplanation)
          for (final point in explanationPoints) ...[
            _ExplanationBullet(point: point),
            const SizedBox(height: 10),
          ]
        else
          const Text(
            'Explanation is not available yet.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 14,
              height: 1.5,
              fontStyle: FontStyle.italic,
              color: Color(0xFF66758E),
            ),
          ),
        if (reminders.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 18, color: _purple),
              const SizedBox(width: 6),
              Text(
                _reminderLabels[language] ?? 'Reminder',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: _purple,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final reminder in reminders) ...[
            _ExplanationBullet(point: reminder, muted: true),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

class _ExplanationBullet extends StatelessWidget {
  const _ExplanationBullet({required this.point, this.muted = false});

  final String point;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontFamily: 'Inter',
      fontSize: muted ? 13 : 14,
      height: 1.5,
      color: muted ? const Color(0xFF4A5A80) : const Color(0xFF1A307F),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('• ', style: style),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: style,
              children: [
                for (final segment in parseEmphasis(point))
                  TextSpan(
                    text: segment.text,
                    style: segment.emphasized
                        ? const TextStyle(
                            fontWeight: FontWeight.w700,
                            backgroundColor: Color(0xFFEDE7FD),
                          )
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
