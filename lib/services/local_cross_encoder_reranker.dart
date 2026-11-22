import 'dart:collection';
import 'dart:math' as math;

import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

class CrossEncoderCandidate {
  const CrossEncoderCandidate({
    required this.articleId,
    required this.articleText,
    required this.hybridScore,
  });

  final String articleId;
  final String articleText;
  final double hybridScore;
}

typedef CrossEncoderSessionLoader =
    Future<OrtSession> Function(String modelAssetPath);

abstract interface class ArticleCrossEncoderReranker {
  Future<List<double>> score(
    String query,
    List<CrossEncoderCandidate> candidates,
  );
}

class LocalCrossEncoderReranker implements ArticleCrossEncoderReranker {
  LocalCrossEncoderReranker({
    AssetBundle? assetBundle,
    String? modelAssetPath,
    this.sessionLoader,
    this.batchSize = 8,
    this.documentTokenCacheLimit = 512,
  }) : _assetBundle = assetBundle ?? rootBundle,
       _modelAssetPath =
           modelAssetPath ?? modelAssetForPlatform(defaultTargetPlatform);

  static const androidModelAssetPath =
      'assets/models/catalyst_cross_encoder_qint8_arm64.onnx';
  static const desktopModelAssetPath =
      'assets/models/catalyst_cross_encoder_quint8_avx2.onnx';
  static const tokenizerAssetPath =
      'assets/models/catalyst_cross_encoder_tokenizer.json';

  static const _maximumSequenceLength = 256;
  static const _maximumQueryTokens = 128;
  static const _documentWindowOverlap = 32;
  static const _paddingTokenId = 1;
  static const _bosTokenId = 0;
  static const _eosTokenId = 2;

  static String modelAssetForPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android || TargetPlatform.iOS => androidModelAssetPath,
        _ => desktopModelAssetPath,
      };

  final AssetBundle _assetBundle;
  final String _modelAssetPath;
  final CrossEncoderSessionLoader? sessionLoader;
  final int batchSize;
  final int documentTokenCacheLimit;
  final LinkedHashMap<String, List<int>> _documentTokenCache =
      LinkedHashMap<String, List<int>>();

  Future<SentencePieceTokenizer>? _tokenizerFuture;
  Future<OrtSession>? _sessionFuture;

  @override
  Future<List<double>> score(
    String query,
    List<CrossEncoderCandidate> candidates,
  ) async {
    if (batchSize <= 0 || documentTokenCacheLimit < 0) {
      throw ArgumentError('Invalid cross-encoder runtime configuration.');
    }
    if (candidates.isEmpty) return const [];

    final tokenizer = await _loadTokenizer();
    final session = await _loadSession();
    final queryTokens = tokenizer
        .encode(query, addSpecialTokens: false)
        .ids
        .take(_maximumQueryTokens)
        .toList(growable: false);
    final rows = <({int candidate, List<int> tokens})>[];

    for (
      var candidateIndex = 0;
      candidateIndex < candidates.length;
      candidateIndex++
    ) {
      final candidate = candidates[candidateIndex];
      final documentTokens = _tokensFor(tokenizer, candidate.articleText);
      for (final tokens in _documentWindows(queryTokens, documentTokens)) {
        rows.add((candidate: candidateIndex, tokens: tokens));
      }
    }

    final bestLogits = List<double>.filled(
      candidates.length,
      double.negativeInfinity,
    );
    for (var offset = 0; offset < rows.length; offset += batchSize) {
      final batch = rows.skip(offset).take(batchSize).toList(growable: false);
      final width = batch.fold<int>(
        0,
        (maximum, row) => math.max(maximum, row.tokens.length),
      );
      final ids = Int64List(batch.length * width);
      final attentionMask = Int64List(batch.length * width);
      for (var rowIndex = 0; rowIndex < batch.length; rowIndex++) {
        final tokens = batch[rowIndex].tokens;
        final rowOffset = rowIndex * width;
        for (var tokenIndex = 0; tokenIndex < width; tokenIndex++) {
          ids[rowOffset + tokenIndex] = tokenIndex < tokens.length
              ? tokens[tokenIndex]
              : _paddingTokenId;
          attentionMask[rowOffset + tokenIndex] = tokenIndex < tokens.length
              ? 1
              : 0;
        }
      }

      final idsTensor = await OrtValue.fromList(ids, [batch.length, width]);
      try {
        final maskTensor = await OrtValue.fromList(attentionMask, [
          batch.length,
          width,
        ]);
        Map<String, OrtValue>? outputs;
        try {
          outputs = await session.run({
            'input_ids': idsTensor,
            'attention_mask': maskTensor,
          });
          final logits = outputs['logits'];
          if (logits == null ||
              logits.shape.length != 2 ||
              logits.shape[0] != batch.length ||
              logits.shape[1] != 1) {
            throw const FormatException(
              'The cross-encoder returned an unexpected logits shape.',
            );
          }
          final values = await logits.asFlattenedList();
          if (values.length != batch.length) {
            throw const FormatException(
              'The cross-encoder returned an invalid logits count.',
            );
          }
          for (var rowIndex = 0; rowIndex < values.length; rowIndex++) {
            final value = (values[rowIndex] as num).toDouble();
            if (!value.isFinite) {
              throw const FormatException(
                'The cross-encoder returned a non-finite logit.',
              );
            }
            final candidateIndex = batch[rowIndex].candidate;
            if (value > bestLogits[candidateIndex]) {
              bestLogits[candidateIndex] = value;
            }
          }
        } finally {
          if (outputs != null) {
            for (final output in outputs.values) {
              await output.dispose();
            }
          }
          await maskTensor.dispose();
        }
      } finally {
        await idsTensor.dispose();
      }
    }

    if (bestLogits.any((value) => !value.isFinite)) {
      throw const FormatException(
        'The cross-encoder did not score every candidate.',
      );
    }
    return bestLogits;
  }

  List<int> _tokensFor(SentencePieceTokenizer tokenizer, String text) {
    final cached = _documentTokenCache.remove(text);
    if (cached != null) {
      _documentTokenCache[text] = cached;
      return cached;
    }

    final tokens = tokenizer
        .encode(text, addSpecialTokens: false)
        .ids
        .toList(growable: false);
    if (documentTokenCacheLimit > 0) {
      _documentTokenCache[text] = tokens;
      if (_documentTokenCache.length > documentTokenCacheLimit) {
        _documentTokenCache.remove(_documentTokenCache.keys.first);
      }
    }
    return tokens;
  }

  static List<List<int>> _documentWindows(
    List<int> queryTokens,
    List<int> documentTokens,
  ) {
    final documentCapacity = _maximumSequenceLength - queryTokens.length - 4;
    if (documentCapacity <= _documentWindowOverlap) {
      throw const FormatException(
        'The query leaves insufficient room for cross-encoder document text.',
      );
    }
    if (documentTokens.isEmpty) {
      return [
        [_bosTokenId, ...queryTokens, _eosTokenId, _eosTokenId, _eosTokenId],
      ];
    }

    final stride = documentCapacity - _documentWindowOverlap;
    final windows = <List<int>>[];
    for (var start = 0; start < documentTokens.length; start += stride) {
      final end = math.min(start + documentCapacity, documentTokens.length);
      windows.add([
        _bosTokenId,
        ...queryTokens,
        _eosTokenId,
        _eosTokenId,
        ...documentTokens.sublist(start, end),
        _eosTokenId,
      ]);
      if (end == documentTokens.length) break;
    }
    return windows;
  }

  Future<SentencePieceTokenizer> _loadTokenizer() {
    final current = _tokenizerFuture;
    if (current != null) return current;

    final pending = _assetBundle
        .loadString(tokenizerAssetPath)
        .then(HuggingFaceTokenizerLoader.fromJsonString);
    _tokenizerFuture = pending;
    return pending.catchError((Object error) {
      if (identical(_tokenizerFuture, pending)) _tokenizerFuture = null;
      throw error;
    });
  }

  Future<OrtSession> _loadSession() {
    final current = _sessionFuture;
    if (current != null) return current;

    final pending =
        sessionLoader?.call(_modelAssetPath) ??
        OnnxRuntime().createSessionFromAsset(
          _modelAssetPath,
          options: OrtSessionOptions(
            intraOpNumThreads: 2,
            interOpNumThreads: 1,
            providers: const [OrtProvider.CPU],
          ),
        );
    late final Future<OrtSession> validated;
    validated = pending
        .then((session) async {
          if (!session.inputNames.contains('input_ids') ||
              !session.inputNames.contains('attention_mask') ||
              !session.outputNames.contains('logits')) {
            await session.close();
            throw const FormatException(
              'The cross-encoder model has an unsupported tensor signature.',
            );
          }
          return session;
        })
        .catchError((Object error) {
          if (identical(_sessionFuture, validated)) _sessionFuture = null;
          throw error;
        });
    _sessionFuture = validated;
    return validated;
  }
}
