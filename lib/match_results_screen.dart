import 'package:flutter/material.dart';

import 'data/mock_law_match_results.dart';
import 'models/law_match_result.dart';
import 'services/explanation_builder.dart';

class _RetrievalSourcePanel extends StatelessWidget {
  const _RetrievalSourcePanel();

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF5F6B85);
    const title = 'Offline retrieval (on-device)';
    const body =
        'Article matching and explanations run on this device. Only Near '
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
  });

  /// Shown instead of the default text when there are no results.
  final String? emptyMessage;

  final List<LawMatchResult> results;
  final String userConcern;
  final String retrievalWarning;

  /// Connect this callback to a Law Details route when that screen is ready.
  final ValueChanged<LawMatchResult>? onResultSelected;

  @override
  State<MatchResultsScreen> createState() => _MatchResultsScreenState();
}

class _MatchResultsScreenState extends State<MatchResultsScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _purple = Color(0xFF8254F2);
  static const _muted = Color(0xFFA6A6A6);

  var _showAllResults = false;

  List<LawMatchResult> get _sortedResults {
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

            return Padding(
              padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: _buildHeader(context),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                    child: _buildInformationBox(),
                  ),
                  if (displayedResults.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalInset,
                      ),
                      child: const _RetrievalSourcePanel(),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: horizontalInset),
                    child: _buildTabs(),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: horizontalInset,
                      ),
                      child: displayedResults.isEmpty
                          ? _buildEmptyState()
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 12),
                              itemCount: displayedResults.length,
                              separatorBuilder: (context, index) =>
                                  const SizedBox(height: 14),
                              itemBuilder: (context, index) {
                                final result = displayedResults[index];
                                return _ResultCard(
                                  result: result,
                                  rank: index + 1,
                                  onTap: () => _handleResultTap(result),
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
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
          widget.emptyMessage ??
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
                          _ScoreBadge(score: result.matchScore, rank: rank),
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
        ],
      ),
    );
  }

  String? _contextualExplanation(LawMatchResult result) {
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
  const _ScoreBadge({required this.score, required this.rank});

  final double score;
  final int rank;

  @override
  Widget build(BuildContext context) {
    final background = switch (rank) {
      1 => const Color(0xFFC0AFFC),
      2 => const Color(0xFFCDCEFE),
      3 => const Color(0xFFDCECFE),
      _ => const Color(0xFFDCECFE),
    };
    final foreground = rank <= 2 ? Colors.white : const Color(0xFF3E86F8);

    return Container(
      width: 44,
      height: 19,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '${score.round()}%',
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1,
          color: foreground,
        ),
      ),
    );
  }
}
