import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'data/mock_law_match_results.dart';
import 'models/law_match_result.dart';
import 'services/gemma_article_selector.dart';
import 'services/explanation_builder.dart';

class _RetrievalSourcePanel extends StatelessWidget {
  const _RetrievalSourcePanel({required this.gemmaEnabled});

  final bool gemmaEnabled;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF5F6B85);
    const title = 'On-device retrieval';
    final body = gemmaEnabled
        ? 'The baseline runs on this device. Gemma sends your concern and up '
              'to 50 retrieved article texts to the local model server over '
              'USB; no cloud AI service is used.'
        : 'Article matching and explanations run on this device. Only Near '
              'Legal Services and XAI follow-up may use the internet.';
    return Semantics(
      container: true,
      label: '$title. $body',
      child: Container(
        key: const ValueKey('retrieval-source-panel'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.phone_android_rounded, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    body,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 12,
                      height: 1.3,
                      color: Color(0xFF4A5470),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MatchResultsScreen extends StatefulWidget {
  const MatchResultsScreen({
    super.key,
    this.results = mockLawMatchResults,
    this.userConcern = '',
    this.retrievalWarning = 'Similarity is a retrieval signal, not a probability or legal conclusion.',
    this.onResultSelected,
    this.emptyMessage,
    this.aiCandidates = const [],
    this.onGemmaAssessment,
    this.gemmaUnavailableReason,
  });

  /// Shown instead of the default text when there are no results.
  final String? emptyMessage;

  final List<LawMatchResult> results;
  final String userConcern;
  final String retrievalWarning;

  /// Connect this callback to a Law Details route when that screen is ready.
  final ValueChanged<LawMatchResult>? onResultSelected;
  final List<LawMatchResult> aiCandidates;
  final Future<GemmaArticleAssessment> Function()? onGemmaAssessment;
  final String? gemmaUnavailableReason;

  @override
  State<MatchResultsScreen> createState() => _MatchResultsScreenState();
}

class _MatchResultsScreenState extends State<MatchResultsScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _purple = Color(0xFF8254F2);
  static const _muted = Color(0xFFA6A6A6);

  var _showAllResults = false;
  var _showGemmaResults = false;
  var _isAssessingWithGemma = false;
  String? _gemmaError;
  GemmaArticleAssessment? _gemmaAssessment;

  List<LawMatchResult> get _sortedResults {
    if (_showGemmaResults) {
      return _gemmaAssessment?.results ?? const [];
    }
    // Stable: equal scores keep the retrieval order.
    final indexed = widget.results.indexed.toList()
      ..sort((a, b) {
        final byScore = b.$2.matchScore.compareTo(a.$2.matchScore);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return [for (final entry in indexed) entry.$2];
  }

  @override
  Widget build(BuildContext context) {
    final sortedResults = _sortedResults;
    final displayedResults = _showAllResults
        ? sortedResults
        : sortedResults.take(3).toList();

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalInset = (constraints.maxWidth * 0.06)
                .clamp(20.0, 24.0)
                .toDouble();

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: _buildHeader(context),
                ),
                Expanded(
                  child: ListView(
                    key: const PageStorageKey<String>('match-results-scroll'),
                    padding: EdgeInsets.fromLTRB(
                      horizontalInset,
                      18,
                      horizontalInset,
                      32,
                    ),
                    children: [
                      _buildInformationBox(),
                      if (displayedResults.isNotEmpty ||
                          widget.onGemmaAssessment != null ||
                          widget.gemmaUnavailableReason != null) ...[
                        const SizedBox(height: 12),
                        _RetrievalSourcePanel(
                          gemmaEnabled: widget.onGemmaAssessment != null,
                        ),
                        if (widget.onGemmaAssessment != null ||
                            widget.gemmaUnavailableReason != null) ...[
                          const SizedBox(height: 10),
                          _buildGemmaPanel(),
                        ],
                      ],
                      const SizedBox(height: 24),
                      _buildTabs(),
                      const SizedBox(height: 16),
                      if (displayedResults.isEmpty)
                        _buildEmptyState()
                      else
                        for (
                          var index = 0;
                          index < displayedResults.length;
                          index++
                        ) ...[
                          if (index > 0) const SizedBox(height: 14),
                          _ResultCard(
                            result: displayedResults[index],
                            rank: index + 1,
                            onTap: () =>
                                _handleResultTap(displayedResults[index]),
                          ),
                        ],
                    ],
                  ),
                ),
              ],
            );
          },
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
            'Match Results',
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

  Widget _buildInformationBox() {
    return Container(
      constraints: const BoxConstraints(minHeight: 96),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF3E86F8).withValues(alpha: 0.09),
        border: Border.all(color: const Color(0xFFC4D4EB), width: 1.5),
        borderRadius: BorderRadius.circular(19),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFDCE0FC),
            ),
            child: const Icon(
              Icons.lightbulb_outline_rounded,
              color: Color(0xFF794BE7),
              size: 34,
            ),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Potential retrieval matches to:',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    height: 1.3,
                    color: _navy,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.userConcern.trim().isEmpty
                      ? '“ USER INPUT HERE ”'
                      : '“ ${widget.userConcern.trim()} ”',
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                    color: _navy,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          _buildTab(
            'Top Matches',
            selected: !_showAllResults,
            onTap: () {
              setState(() => _showAllResults = false);
            },
          ),
          _buildTab(
            'All Results',
            selected: _showAllResults,
            onTap: () {
              setState(() => _showAllResults = true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTab(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? _navy : _muted,
                  ),
                ),
              ),
            ),
            Container(
              height: selected ? 3 : 1.5,
              color: selected ? _purple : const Color(0xFFD0D0D0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          (_showGemmaResults && _gemmaAssessment != null
                  ? _gemmaAssessment!.explanation
                  : widget.emptyMessage) ??
              (widget.userConcern.trim().isEmpty
                  ? 'No matching results yet.'
                  : 'The retrieval service returned no matching articles.'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 15,
            color: _navy.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Widget _buildGemmaPanel() {
    final assessment = _gemmaAssessment;
    return Container(
      key: const ValueKey('gemma-comparison-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E8),
        border: Border.all(color: const Color(0xFFE7D39E)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Gemma 4 E4B — local experiment',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: _navy,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Optional AI selection from the top 50 retrieved articles. '
            'The local CPU model can take several minutes.',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              height: 1.35,
              color: Color(0xFF4A5470),
            ),
          ),
          if (widget.onGemmaAssessment == null &&
              widget.gemmaUnavailableReason != null) ...[
            const SizedBox(height: 8),
            Text(
              widget.gemmaUnavailableReason!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                height: 1.35,
                color: Color(0xFF8A4B08),
              ),
            ),
          ],
          if (assessment == null) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              key: const ValueKey('run-gemma-assessment'),
              onPressed:
                  _isAssessingWithGemma || widget.onGemmaAssessment == null
                  ? null
                  : () => unawaited(_runGemmaAssessment()),
              icon: _isAssessingWithGemma
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome, size: 18),
              label: Text(
                _isAssessingWithGemma ? 'Gemma is assessing...' : 'Run Gemma',
              ),
            ),
          ] else ...[
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(value: false, label: Text('Baseline')),
                ButtonSegment<bool>(value: true, label: Text('Gemma')),
              ],
              selected: {_showGemmaResults},
              onSelectionChanged: (selection) {
                setState(() => _showGemmaResults = selection.single);
              },
            ),
            const SizedBox(height: 8),
            Text(
              assessment.explanation,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 12,
                height: 1.35,
                color: _navy,
              ),
            ),
            if (assessment.rejectedIds > 0 ||
                assessment.rejectedQuotes > 0) ...[
              const SizedBox(height: 4),
              Text(
                'Ignored ${assessment.rejectedIds} invalid ID(s) and '
                '${assessment.rejectedQuotes} unsupported quote(s).',
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  color: Color(0xFF8A4B08),
                ),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Gemma inference: ${assessment.elapsed.inSeconds}s. '
              'Not legal advice.',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                color: Color(0xFF5F6B85),
              ),
            ),
          ],
          if (_gemmaError != null) ...[
            const SizedBox(height: 8),
            Text(
              _gemmaError!,
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                color: Color(0xFF9B1C1C),
              ),
            ),
            TextButton(
              onPressed: _isAssessingWithGemma
                  ? null
                  : () => unawaited(_runGemmaAssessment()),
              child: const Text('Retry Gemma'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runGemmaAssessment() async {
    final assess = widget.onGemmaAssessment;
    if (assess == null || _isAssessingWithGemma) return;
    setState(() {
      _isAssessingWithGemma = true;
      _gemmaError = null;
    });
    try {
      final assessment = await assess();
      if (!mounted) return;
      setState(() {
        _gemmaAssessment = assessment;
        _showGemmaResults = true;
        _showAllResults = false;
      });
    } on GemmaArticleAssessmentException catch (error) {
      if (mounted) setState(() => _gemmaError = error.message);
    } catch (error, stackTrace) {
      developer.log(
        'Gemma article assessment failed (${error.runtimeType})',
        name: 'catol.gemma',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(
          () => _gemmaError =
              'Gemma assessment failed unexpectedly. The baseline results '
              'are unchanged.',
        );
      }
    } finally {
      if (mounted) setState(() => _isAssessingWithGemma = false);
    }
  }

  void _handleResultTap(LawMatchResult result) {
    final callback = widget.onResultSelected;
    if (callback != null) {
      callback(result);
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Law Details navigation is not connected yet.'),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.rank,
    required this.onTap,
  });

  final LawMatchResult result;
  final int rank;
  final VoidCallback onTap;

  static const _navy = Color(0xFF1A307F);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      elevation: 2,
      shadowColor: const Color(0x14000000),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFC4D4EB), width: 1.2),
            borderRadius: BorderRadius.circular(19),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 136),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.lawName,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              color: _navy,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${result.articleNumber} - ${result.title}',
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 12,
                              height: 1.35,
                              color: _navy,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            result.description,
                            maxLines: 4,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Inter',
                              fontSize: 11,
                              height: 1.35,
                              color: _navy,
                            ),
                          ),
                          const SizedBox(height: 10),
                          _buildRelevanceExplanation(result),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 44,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _ScoreBadge(
                            score: result.matchScore,
                            rank: rank,
                            gemmaRank: result.hasAiExplanation,
                          ),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFF737373),
                            size: 26,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRelevanceExplanation(LawMatchResult result) {
    final explanation = _contextualExplanation(result);
    final quote = result.supportingQuote;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F0FE),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why this may relate',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _navy,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            explanation ??
                'No fact-specific explanation is available. Similarity '
                    'ranking alone does not show that this provision applies.',
            style: const TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              height: 1.4,
              color: _navy,
            ),
          ),
          if (quote != null && quote.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Supporting text: “$quote”',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 10,
                height: 1.35,
                color: _navy,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String? _contextualExplanation(LawMatchResult result) {
    // AI-selected articles must show Gemma's own explanation, not a
    // pre-existing baseline explanation variant.
    if (result.hasAiExplanation) {
      final reason = result.contextualExplanation?.trim();
      if (reason != null && reason.isNotEmpty) return stripEmphasis(reason);
    }
    final variants = result.explanationVariants;
    if (variants != null && variants.isNotEmpty) {
      final preferred = result.defaultExplanationLanguage;
      final variant =
          variants[preferred] ?? variants['en'] ?? variants.values.first;
      if (variant.points.isNotEmpty) {
        final index = result.hasAiExplanation && variant.points.length > 1
            ? 1
            : 0;
        return stripEmphasis(variant.points[index]);
      }
    }

    if (!result.hasAiExplanation) return null;
    final reason = result.contextualExplanation?.trim();
    return reason == null || reason.isEmpty ? null : stripEmphasis(reason);
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({
    required this.score,
    required this.rank,
    this.gemmaRank = false,
  });

  final double score;
  final int rank;
  final bool gemmaRank;

  @override
  Widget build(BuildContext context) {
    final background = switch (rank) {
      1 => const Color(0xFFC0AFFC),
      2 => const Color(0xFFCDCEFE),
      3 => const Color(0xFFDCECFE),
      _ => const Color(0xFFDCECFE),
    };
    final foreground = rank <= 2 ? Colors.white : const Color(0xFF3E86F8);

    return Tooltip(
      message: gemmaRank ? 'Gemma-selected rank' : 'Relevance score',
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: gemmaRank
            ? 'Gemma-selected rank: $rank'
            : 'Relevance score: ${score.round()}%',
        child: ExcludeSemantics(
          child: Container(
            width: 44,
            height: 19,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              gemmaRank ? 'AI #$rank' : '${score.round()}%',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
