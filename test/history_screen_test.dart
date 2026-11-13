import 'package:catol/data/mock_history_entries.dart';
import 'package:catol/history_screen.dart';
import 'package:catol/law_details_screen.dart';
import 'package:catol/models/history_entry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('favorite entries show a ribbon and non-favorites do not', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    final favoriteRibbon = find.byKey(
      const ValueKey('favorite-ribbon-Hiwalayan ang asawa'),
    );
    final secondFavoriteRibbon = find.byKey(
      const ValueKey('favorite-ribbon-Tumataas na renta'),
    );
    final nonFavoriteRibbon = find.byKey(
      const ValueKey('favorite-ribbon-Defective na phone'),
    );

    expect(favoriteRibbon, findsOneWidget);
    expect(secondFavoriteRibbon, findsOneWidget);
    expect(nonFavoriteRibbon, findsNothing);
    expect(tester.getSize(favoriteRibbon), const Size(15, 21));
    final favoriteCard = find.byKey(
      const ValueKey('history-card-Hiwalayan ang asawa'),
    );
    expect(
      tester.getTopLeft(favoriteRibbon).dy,
      tester.getTopLeft(favoriteCard).dy,
    );
  });

  testWidgets('All and Favorites tabs display their corresponding entries', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Defective na phone'), findsOneWidget);
    expect(find.text('Tumataas na renta'), findsOneWidget);
    expect(find.text('False Advertisement'), findsOneWidget);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Tumataas na renta'), findsOneWidget);
    expect(find.text('Defective na phone'), findsNothing);
    expect(find.text('False Advertisement'), findsNothing);
  });

  testWidgets('tabs are compact and entry content has readable hierarchy', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    expect(
      tester.getSize(find.byKey(const ValueKey('history-tab-all'))).height,
      28,
    );
    expect(
      tester
          .getSize(find.byKey(const ValueKey('history-tab-favorites')))
          .height,
      28,
    );

    final title = tester.widget<Text>(find.text('Hiwalayan ang asawa'));
    final excerpt = tester.widget<Text>(
      find.text('“Gusto ko nang hiwalayan ang asawa ko...”'),
    );
    final law = tester.widget<Text>(
      find.text('Family Code Art. 55., Art. 56.,'),
    );
    expect(title.style?.fontSize, 15);
    expect(title.style?.fontWeight, FontWeight.w600);
    expect(excerpt.style?.fontSize, 11);
    expect(excerpt.style?.fontStyle, FontStyle.italic);
    expect(law.style?.fontSize, 13);
    expect(law.style?.fontWeight, FontWeight.w600);

    final card = find.byKey(const ValueKey('history-card-Hiwalayan ang asawa'));
    expect(tester.getSize(card).width, greaterThan(280));
    final outline = tester.widget<DecoratedBox>(
      find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).border != null,
        ),
      ),
    );
    final border = (outline.decoration as BoxDecoration).border! as Border;
    expect(border.top.color, const Color(0xFFC4D4EB));
    expect(border.top.width, 1.2);
  });

  testWidgets('Clear All cancellation preserves every entry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    await tester.tap(find.byTooltip('Clear All'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This will delete all non-favorite history entries. Favorites will be kept.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Defective na phone'), findsOneWidget);
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Tumataas na renta'), findsOneWidget);
  });

  testWidgets('Clear All deletes only non-favorite entries', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    await tester.tap(find.byTooltip('Clear All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Tumataas na renta'), findsOneWidget);
    expect(find.text('Defective na phone'), findsNothing);
    expect(find.text('False Advertisement'), findsNothing);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Tumataas na renta'), findsOneWidget);
  });

  testWidgets('Clear All with only favorites leaves them in both tabs', (
    tester,
  ) async {
    final favoriteEntries = mockHistoryEntries
        .where((entry) => entry.isFavorite)
        .toList();
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: favoriteEntries)),
    );

    await tester.tap(find.byTooltip('Clear All'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'There are no non-favorite history entries to delete. Your favorites will remain.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Tumataas na renta'), findsOneWidget);
  });

  testWidgets('individual deletion can be canceled without changing entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    await tester.tap(find.byTooltip('Delete Hiwalayan ang asawa'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete “Hiwalayan ang asawa” from your history?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
    expect(find.text('Defective na phone'), findsOneWidget);
  });

  testWidgets('individual deletion removes a favorite from both tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    await tester.tap(find.byTooltip('Delete Hiwalayan ang asawa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Hiwalayan ang asawa'), findsNothing);
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('Hiwalayan ang asawa'), findsNothing);
    expect(find.text('Tumataas na renta'), findsOneWidget);
  });

  testWidgets('individual deletion removes a non-favorite entry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    await tester.tap(find.byTooltip('Delete Defective na phone'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Defective na phone'), findsNothing);
    expect(find.text('Hiwalayan ang asawa'), findsOneWidget);
  });

  testWidgets('deleting the last non-favorite displays both empty states', (
    tester,
  ) async {
    final nonFavoriteEntries = mockHistoryEntries
        .where((entry) => !entry.isFavorite)
        .toList();
    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: nonFavoriteEntries)),
    );

    await tester.tap(find.byTooltip('Clear All'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('No history entries yet.'), findsOneWidget);

    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('No favorite entries yet.'), findsOneWidget);
  });

  testWidgets('selecting a history entry invokes the selection callback', (
    tester,
  ) async {
    HistoryEntry? selectedEntry;

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          entries: mockHistoryEntries,
          onEntrySelected: (entry) async {
            selectedEntry = entry;
          },
        ),
      ),
    );

    await tester.tap(find.text('Hiwalayan ang asawa'));

    expect(selectedEntry, same(mockHistoryEntries.first));
  });

  testWidgets('navigating from a favorite opens Law Details bookmarked', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          entries: mockHistoryEntries,
          onEntrySelected: (entry) async {
            await Navigator.of(tester.element(find.byType(HistoryScreen))).push(
              MaterialPageRoute<void>(
                builder: (context) => LawDetailsScreen(
                  result: entry.result,
                  initialIsBookmarked: entry.isFavorite,
                  onBookmarkChanged: (isBookmarked) =>
                      entry.isFavorite = isBookmarked,
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Hiwalayan ang asawa'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Remove bookmark'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/bookmark_filled.png',
      ),
      findsOneWidget,
    );
  });

  testWidgets('navigating from a non-favorite opens Law Details unbookmarked', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          entries: mockHistoryEntries,
          onEntrySelected: (entry) async {
            await Navigator.of(tester.element(find.byType(HistoryScreen))).push(
              MaterialPageRoute<void>(
                builder: (context) => LawDetailsScreen(
                  result: entry.result,
                  initialIsBookmarked: entry.isFavorite,
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Defective na phone'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('Bookmark'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/bookmark_outline.png',
      ),
      findsOneWidget,
    );
  });

  testWidgets('unfavoriting in Law Details updates History on return', (
    tester,
  ) async {
    final source = mockHistoryEntries.first;
    final entry = HistoryEntry(
      concernTitle: source.concernTitle,
      concernExcerpt: source.concernExcerpt,
      matchedLawLabel: source.matchedLawLabel,
      createdAt: source.createdAt,
      isFavorite: true,
      result: source.result,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          entries: [entry],
          onEntrySelected: (selected) async {
            await Navigator.of(tester.element(find.byType(HistoryScreen))).push(
              MaterialPageRoute<void>(
                builder: (context) => LawDetailsScreen(
                  result: selected.result,
                  initialIsBookmarked: selected.isFavorite,
                  onBookmarkChanged: (isBookmarked) =>
                      selected.isFavorite = isBookmarked,
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text(entry.concernTitle));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Remove bookmark'));
    await tester.pump();
    expect(entry.isFavorite, isFalse);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text(entry.concernTitle), findsOneWidget);
    expect(
      find.byKey(ValueKey('favorite-ribbon-${entry.concernTitle}')),
      findsNothing,
    );
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(find.text('No favorite entries yet.'), findsOneWidget);
    expect(find.text(entry.concernTitle), findsNothing);

    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.text(entry.concernTitle), findsOneWidget);
    expect(
      find.byKey(ValueKey('favorite-ribbon-${entry.concernTitle}')),
      findsNothing,
    );
  });

  testWidgets('individual trash does not open the selected history entry', (
    tester,
  ) async {
    HistoryEntry? selectedEntry;
    await tester.pumpWidget(
      MaterialApp(
        home: HistoryScreen(
          entries: mockHistoryEntries,
          onEntrySelected: (entry) async {
            selectedEntry = entry;
          },
        ),
      ),
    );

    await tester.tap(find.byTooltip('Delete Hiwalayan ang asawa'));
    await tester.pumpAndSettle();

    expect(find.text('Delete History Entry?'), findsOneWidget);
    expect(selectedEntry, isNull);
  });

  testWidgets('narrow layout keeps history cards within the screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(home: HistoryScreen(entries: mockHistoryEntries)),
    );

    final card = find.byKey(const ValueKey('history-card-Hiwalayan ang asawa'));
    expect(tester.getSize(card).width, lessThan(320));
    expect(tester.takeException(), isNull);
  });
}
