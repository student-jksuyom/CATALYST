import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:flutter/services.dart';

class LocalTokenizer {
  LocalTokenizer(this._tokenizer);

  static const assetPath = 'assets/models/e5_tokenizer.json';
  static const maxSequenceLength = 128;

  final SentencePieceTokenizer _tokenizer;

  static Future<LocalTokenizer> load({AssetBundle? assetBundle}) async {
    final tokenizerJson = await (assetBundle ?? rootBundle).loadString(
      assetPath,
    );
    final tokenizer = HuggingFaceTokenizerLoader.fromJsonString(tokenizerJson)
      ..enableTruncation(maxLength: maxSequenceLength);
    return LocalTokenizer(tokenizer);
  }

  Encoding encode(String text) => _tokenizer.encode(text);
}
