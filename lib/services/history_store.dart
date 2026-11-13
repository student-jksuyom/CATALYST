import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/history_entry.dart';
import 'catalyst_local_retrieval_service.dart';

class HistoryStorageException implements Exception {
  const HistoryStorageException();
}

class HistoryStore {
  HistoryStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();

  Future<T> _run<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _pending = _pending.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        developer.log(
          'History storage failed (${error.runtimeType})',
          name: 'catol.history',
          stackTrace: stackTrace,
        );
        completer.completeError(const HistoryStorageException(), stackTrace);
      }
    });
    return completer.future;
  }

  Future<File> _file() async {
    final directory = await _directory();
    return File(
      '${directory.path}${Platform.pathSeparator}search_history.json',
    );
  }

  Future<List<HistoryEntry>> _read() async {
    final file = await _file();
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1) {
      throw const FormatException('Unsupported history format.');
    }
    return (data['entries'] as List)
        .map((value) => HistoryEntry.fromJson(value as Map<String, dynamic>))
        .toList();
  }

  Future<void> _write(List<HistoryEntry> entries) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({'version': 1, 'entries': entries}),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  Future<List<HistoryEntry>> load() => _run(_read);

  Future<HistoryEntry> addSearch(
    String concern,
    CatalystMatchResponse response,
  ) => _run(() async {
    final entries = await _read();
    final now = DateTime.now();
    var id = now.microsecondsSinceEpoch.toString();
    while (entries.any((entry) => entry.id == id)) {
      id = '${id}_';
    }
    final compact = concern.replaceAll(RegExp(r'\s+'), ' ').trim();
    final results = [...response.results, ...response.otherCandidates];
    final entry = HistoryEntry(
      id: id,
      concern: concern,
      concernTitle: compact,
      concernExcerpt: '“$compact”',
      matchedLawLabel: results.isEmpty
          ? 'No matching laws'
          : '${results.first.lawName} ${results.first.articleNumber}',
      createdAt: now,
      isFavorite: false,
      results: results,
      processedQuery: response.processedQuery,
      warning: response.warning,
      emptyMessage: response.clarifyingQuestion,
      topResultCount: response.results.length,
    );
    entries.insert(0, entry);
    await _write(entries);
    return entry;
  });

  Future<void> setFavorite(String id, bool favorite) => _run(() async {
    final entries = await _read();
    final entry = entries.singleWhere((entry) => entry.id == id);
    entry.isFavorite = favorite;
    await _write(entries);
  });

  Future<void> delete(String id) => _run(() async {
    final entries = await _read();
    entries.removeWhere((entry) => entry.id == id);
    await _write(entries);
  });

  Future<void> clearNonFavorites() => _run(() async {
    final entries = await _read();
    entries.removeWhere((entry) => !entry.isFavorite);
    await _write(entries);
  });
}
