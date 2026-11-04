import 'package:flutter/material.dart';

import 'data/mock_history_entries.dart';
import 'models/history_entry.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, this.entries, this.onEntrySelected});

  final List<HistoryEntry>? entries;
  final Future<void> Function(HistoryEntry)? onEntrySelected;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _navy = Color(0xFF1A307F);
  static const _blue = Color(0xFF3E86F8);
  static const _purple = Color(0xFF8254F2);
  static const _trashPurple = Color(0xFF3F2381);

  late List<HistoryEntry> _entries;
  var _showFavorites = false;

  @override
  void initState() {
    super.initState();
    _entries = List<HistoryEntry>.of(widget.entries ?? mockHistoryEntries);
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entries, widget.entries)) {
      _entries = List<HistoryEntry>.of(widget.entries ?? mockHistoryEntries);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayedEntries = _showFavorites
        ? _entries.where((entry) => entry.isFavorite).toList()
        : _entries;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: _buildHeader(context),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildTabs(),
              ),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: displayedEntries.isEmpty
                  ? _buildEmptyState()
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                      itemCount: displayedEntries.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final entry = displayedEntries[index];
                        return _HistoryCard(
                          entry: entry,
                          onTap: () => _handleEntryTap(entry),
                          onDelete: () => _confirmDeleteEntry(entry),
                        );
                      },
                    ),
            ),
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
            'History',
            style: TextStyle(
              fontFamily: 'Montserrat',
              fontSize: 23,
              fontWeight: FontWeight.w600,
              height: 1.2,
              color: _navy,
            ),
          ),
          const Spacer(),
          Tooltip(
            message: 'Clear All',
            child: InkWell(
              onTap: _confirmClearAll,
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 52,
                height: 52,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset(
                      'assets/images/history_trash.png',
                      width: 18,
                      height: 22,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 1),
                    const Text(
                      'Clear All',
                      style: TextStyle(
                        fontFamily: 'Inter',
                        fontSize: 10,
                        height: 1.1,
                        color: _navy,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return Row(
      children: [
        _HistoryTab(
          label: 'All',
          selected: !_showFavorites,
          key: const ValueKey('history-tab-all'),
          onTap: () => setState(() => _showFavorites = false),
        ),
        const SizedBox(width: 7),
        _HistoryTab(
          label: 'Favorites',
          selected: _showFavorites,
          key: const ValueKey('history-tab-favorites'),
          onTap: () => setState(() => _showFavorites = true),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _showFavorites
              ? 'No favorite entries yet.'
              : 'No history entries yet.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            color: _navy.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmClearAll() async {
    final removableCount = _entries.where((entry) => !entry.isFavorite).length;
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear All History?'),
        content: Text(
          removableCount == 0
              ? 'There are no non-favorite history entries to delete. Your favorites will remain.'
              : 'This will delete all non-favorite history entries. Favorites will be kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: _trashPurple)),
          ),
        ],
      ),
    );

    if (shouldClear == true && mounted) {
      setState(() {
        _entries.removeWhere((entry) => !entry.isFavorite);
      });
    }
  }

  Future<void> _confirmDeleteEntry(HistoryEntry entry) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete History Entry?'),
        content: Text('Delete “${entry.concernTitle}” from your history?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete', style: TextStyle(color: _trashPurple)),
          ),
        ],
      ),
    );

    if (shouldDelete == true && mounted) {
      setState(() {
        _entries.remove(entry);
      });
    }
  }

  Future<void> _handleEntryTap(HistoryEntry entry) async {
    final callback = widget.onEntrySelected;
    if (callback != null) {
      await callback(entry);
      if (mounted) setState(() {});
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('History navigation is not connected yet.')),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isAllTab = label == 'All';
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? const Color(0xFFDCECFE) : const Color(0xFFF1F6FD),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: isAllTab ? 56 : 82,
            height: 28,
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected
                      ? _HistoryScreenState._blue
                      : const Color(0xFFC4D4EB),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({
    required this.entry,
    required this.onTap,
    required this.onDelete,
  });

  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  static const _navy = Color(0xFF1A307F);

  @override
  Widget build(BuildContext context) {
    return Material(
      key: ValueKey('history-card-${entry.concernTitle}'),
      color: Colors.white,
      borderRadius: BorderRadius.circular(19),
      elevation: 2,
      shadowColor: const Color(0x141A307F),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(19),
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFC4D4EB), width: 1.2),
            borderRadius: BorderRadius.circular(19),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              SizedBox(
                height: 132,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 10, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.concernTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                                color: _navy,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 12, top: 2),
                              child: Text(
                                entry.concernExcerpt,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  height: 1.25,
                                  color: Color(0xFF66758E),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              entry.matchedLawLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                                color: _navy,
                              ),
                            ),
                            const Spacer(),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                _formatDate(entry.createdAt),
                                style: const TextStyle(
                                  fontFamily: 'Inter',
                                  fontSize: 10,
                                  height: 1.2,
                                  color: _navy,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 34,
                        child: Column(
                          children: [
                            SizedBox(
                              width: 28,
                              height: 28,
                              child: Tooltip(
                                message: 'Delete ${entry.concernTitle}',
                                child: InkWell(
                                  key: ValueKey(
                                    'delete-history-${entry.concernTitle}',
                                  ),
                                  onTap: onDelete,
                                  borderRadius: BorderRadius.circular(14),
                                  child: Center(
                                    child: Image.asset(
                                      'assets/images/history_trash.png',
                                      width: 13,
                                      height: 15,
                                      fit: BoxFit.contain,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            const Icon(
                              Icons.chevron_right_rounded,
                              color: Color(0xFF737373),
                              size: 24,
                            ),
                            const Spacer(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (entry.isFavorite)
                Positioned(
                  top: 0,
                  right: 44,
                  child: IgnorePointer(
                    child: CustomPaint(
                      key: ValueKey('favorite-ribbon-${entry.concernTitle}'),
                      size: const Size(15, 21),
                      painter: const _FavoriteRibbonPainter(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${monthNames[date.month - 1]} ${date.day}, ${date.year}';
  }
}

class _FavoriteRibbonPainter extends CustomPainter {
  const _FavoriteRibbonPainter();

  static const _purple = Color(0xFF794BE7);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, size.height - 5)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(0, size.height - 5)
      ..close();
    canvas.drawPath(path, Paint()..color = _purple);
  }

  @override
  bool shouldRepaint(covariant _FavoriteRibbonPainter oldDelegate) => false;
}
