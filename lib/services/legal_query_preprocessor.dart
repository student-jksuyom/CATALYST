import 'package:google_mlkit_language_id/google_mlkit_language_id.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

class DetectedQueryLanguage {
  const DetectedQueryLanguage({
    required this.languageTag,
    required this.confidence,
  });

  final String languageTag;
  final double confidence;
}

abstract interface class QueryLanguageIdentifier {
  Future<List<DetectedQueryLanguage>> identifyPossibleLanguages(String query);
}

abstract interface class TagalogToEnglishTranslator {
  Future<String> translate(String query);
}

abstract interface class LegalQueryPreprocessor {
  Future<String> preprocess(String query);
}

class TagalogQueryPreprocessor implements LegalQueryPreprocessor {
  const TagalogQueryPreprocessor({
    required this.languageIdentifier,
    required this.translator,
  });

  static const double _minimumTagalogConfidence = 0.15;
  static const Set<String> _clearFilipinoMarkers = {
    'ako',
    'ayaw',
    'binili',
    'dahil',
    'hindi',
    'ibalik',
    'kahit',
    'kakabili',
    'mga',
    'pero',
    'pinirmahan',
    'sira',
    'agad',
    'wala',
    'wag',
    'huwag',
    'yung',
  };
  static const Set<String> _contextualFilipinoMarkers = {
    'ang',
    'ko',
    'mo',
    'na',
    'ng',
    'sa',
  };

  final QueryLanguageIdentifier languageIdentifier;
  final TagalogToEnglishTranslator translator;

  @override
  Future<String> preprocess(String query) async {
    if (!_hasFilipinoMarkers(query)) {
      final languages = await languageIdentifier.identifyPossibleLanguages(
        query,
      );
      if (!_isTagalogOrTaglish(languages)) {
        return query;
      }
    }

    final translated = (await translator.translate(query)).trim();
    if (translated.isEmpty) {
      throw StateError('The on-device translator returned an empty query.');
    }
    return translated;
  }

  bool _hasFilipinoMarkers(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((word) => word.isNotEmpty)
        .toSet();
    if (words.intersection(_clearFilipinoMarkers).isNotEmpty) {
      return true;
    }
    return words.intersection(_contextualFilipinoMarkers).length >= 2;
  }

  bool _isTagalogOrTaglish(List<DetectedQueryLanguage> languages) {
    final tagalogConfidence = languages
        .where((language) {
          final primaryTag = language.languageTag
              .toLowerCase()
              .split(RegExp(r'[-_]'))
              .first;
          return primaryTag == 'tl' || primaryTag == 'fil';
        })
        .fold<double>(0, (highest, language) {
          return language.confidence > highest ? language.confidence : highest;
        });
    if (tagalogConfidence < _minimumTagalogConfidence) {
      return false;
    }

    final englishConfidence = languages
        .where((language) => language.languageTag == 'en')
        .fold<double>(0, (highest, language) {
          return language.confidence > highest ? language.confidence : highest;
        });
    return englishConfidence == 0 ||
        tagalogConfidence >= englishConfidence * 0.5;
  }
}

class MlKitQueryLanguageIdentifier implements QueryLanguageIdentifier {
  const MlKitQueryLanguageIdentifier();

  @override
  Future<List<DetectedQueryLanguage>> identifyPossibleLanguages(
    String query,
  ) async {
    final identifier = LanguageIdentifier(confidenceThreshold: 0.01);
    try {
      final detected = await identifier.identifyPossibleLanguages(query);
      return detected
          .map(
            (language) => DetectedQueryLanguage(
              languageTag: language.languageTag,
              confidence: language.confidence,
            ),
          )
          .toList(growable: false);
    } finally {
      await identifier.close();
    }
  }
}

class MlKitTagalogToEnglishTranslator implements TagalogToEnglishTranslator {
  const MlKitTagalogToEnglishTranslator();

  @override
  Future<String> translate(String query) async {
    final modelManager = OnDeviceTranslatorModelManager();
    for (final language in [
      TranslateLanguage.tagalog,
      TranslateLanguage.english,
    ]) {
      final downloaded = await modelManager.downloadModel(
        language.bcpCode,
        isWifiRequired: true,
      );
      if (!downloaded) {
        throw StateError(
          'The ${language.bcpCode} translation model was not downloaded.',
        );
      }
    }

    final translator = OnDeviceTranslator(
      sourceLanguage: TranslateLanguage.tagalog,
      targetLanguage: TranslateLanguage.english,
    );
    try {
      return await translator.translateText(query);
    } finally {
      await translator.close();
    }
  }
}

const LegalQueryPreprocessor defaultLegalQueryPreprocessor =
    TagalogQueryPreprocessor(
      languageIdentifier: MlKitQueryLanguageIdentifier(),
      translator: MlKitTagalogToEnglishTranslator(),
    );
