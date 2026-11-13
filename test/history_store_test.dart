import 'dart:io';

import 'package:catol/models/law_match_result.dart';
import 'package:catol/services/catalyst_local_retrieval_service.dart';
import 'package:catol/services/history_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late HistoryStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('catalyst_history_test_');
    store = HistoryStore(directory: () async => directory);
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  const result = LawMatchResult(
    lawName: 'Civil Code',
    articleNumber: 'Article 1',
    title: 'Title',
    description: 'Description',
    matchScore: 42.5,
    detailsReference: 'ref',
    chapterTitle: 'Chapter',
    articleText: 'Provision',
    contextualExplanation: 'Explanation',
    hasAiExplanation: true,
    caseExplanationPoints: ['A point'],
    explanationVariants: {
      'en': ExplanationVariant(points: ['Why'], reminders: ['Caution']),
    },
    defaultExplanationLanguage: 'en',
  );

  test('persists full searches and bookmarks across store instances', () async {
    final first = await store.addSearch(
      'A private concern',
      const CatalystMatchResponse(
        results: [result],
        otherCandidates: [result],
        processedQuery: 'processed',
        warning: 'warning',
      ),
    );
    await store.setFavorite(first.id, true);
    final empty = await store.addSearch(
      'An unclear concern',
      const CatalystMatchResponse(
        results: [],
        clarifyingQuestion: 'More facts?',
      ),
    );

    final reopened = HistoryStore(directory: () async => directory);
    var entries = await reopened.load();
    expect(entries.map((e) => e.id), [empty.id, first.id]);
    expect(entries.first.results, isEmpty);
    expect(entries.first.emptyMessage, 'More facts?');
    final saved = entries.last;
    expect(saved.concern, 'A private concern');
    expect(saved.isFavorite, isTrue);
    expect(saved.topResultCount, 1);
    expect(saved.processedQuery, 'processed');
    expect(saved.warning, 'warning');
    expect(saved.results.length, 2);
    expect(saved.result.toJson(), result.toJson());

    await reopened.clearNonFavorites();
    entries = await store.load();
    expect(entries.single.id, first.id);
    await store.setFavorite(first.id, false);
    await store.delete(first.id);
    expect(await reopened.load(), isEmpty);
  });

  test('serializes overlapping changes without losing searches', () async {
    await Future.wait([
      store.addSearch('First', const CatalystMatchResponse(results: [])),
      store.addSearch('Second', const CatalystMatchResponse(results: [])),
    ]);
    expect((await store.load()).map((e) => e.concern), ['Second', 'First']);
  });

  test('reports corrupt history without overwriting it', () async {
    final file = File(
      '${directory.path}${Platform.pathSeparator}search_history.json',
    );
    await file.writeAsString('not json');
    await expectLater(store.load(), throwsA(isA<HistoryStorageException>()));
    await expectLater(
      store.addSearch('New', const CatalystMatchResponse(results: [])),
      throwsA(isA<HistoryStorageException>()),
    );
    expect(await file.readAsString(), 'not json');
  });
}
