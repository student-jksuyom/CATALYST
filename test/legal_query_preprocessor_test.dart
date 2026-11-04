import 'package:catol/services/legal_query_preprocessor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TagalogQueryPreprocessor', () {
    test('translates a Taglish defective-phone query into English', () async {
      const query =
          'Binili ko yung phone pero sira agad kahit kakabili ko lang.';
      const translation =
          'I bought the phone but it broke right away even though I had just bought it.';
      final identifier = _FakeLanguageIdentifier(const []);
      final translator = _FakeTranslator(translation);
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: identifier,
        translator: translator,
      );

      expect(await preprocessor.preprocess(query), translation);
      expect(translator.queries, [query]);
      expect(identifier.queries, isEmpty);
    });

    test('translates a Tagalog defective-item refund query', () async {
      const query =
          'Ayaw ibalik ng seller yung pera ko kahit defective yung item.';
      const translation =
          'The seller refuses to return my money even though the item is defective.';
      final translator = _FakeTranslator(translation);
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: _FakeLanguageIdentifier(const []),
        translator: translator,
      );

      expect(await preprocessor.preprocess(query), translation);
      expect(translator.queries, [query]);
    });

    test('preserves negation when translating a Tagalog query', () async {
      const query = 'Hindi ko pinirmahan yung kontrata.';
      const translation = 'I did not sign the contract.';
      final translator = _FakeTranslator(translation);
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: _FakeLanguageIdentifier(const []),
        translator: translator,
      );

      expect(await preprocessor.preprocess(query), translation);
      expect(translator.queries, [query]);
      expect(translation, contains('not'));
    });

    test(
      'uses language identification for Tagalog without marker words',
      () async {
        const query = 'May karapatan ba akong humingi ng refund?';
        const translation = 'Can I ask for a refund?';
        final identifier = _FakeLanguageIdentifier(const [
          DetectedQueryLanguage(languageTag: 'tl', confidence: 0.9),
        ]);
        final translator = _FakeTranslator(translation);
        final preprocessor = TagalogQueryPreprocessor(
          languageIdentifier: identifier,
          translator: translator,
        );

        expect(await preprocessor.preprocess(query), translation);
        expect(identifier.queries, [query]);
        expect(translator.queries, [query]);
      },
    );

    test('recognizes the Filipino language tag and region suffix', () async {
      const query = 'May karapatan ba akong humingi ng refund?';
      const translation = 'Can I ask for a refund?';

      for (final languageTag in ['fil', 'fil-PH']) {
        final identifier = _FakeLanguageIdentifier([
          DetectedQueryLanguage(languageTag: languageTag, confidence: 0.9),
        ]);
        final translator = _FakeTranslator(translation);
        final preprocessor = TagalogQueryPreprocessor(
          languageIdentifier: identifier,
          translator: translator,
        );

        expect(await preprocessor.preprocess(query), translation);
        expect(identifier.queries, [query]);
        expect(translator.queries, [query]);
      }
    });

    test('does not translate equivalent English queries', () async {
      const queries = [
        'I bought the phone but it broke immediately even though I had just bought it.',
        'The seller refuses to return my money even though the item is defective.',
        'I did not sign the contract.',
      ];
      final identifier = _FakeLanguageIdentifier(const [
        DetectedQueryLanguage(languageTag: 'en', confidence: 0.99),
      ]);
      final translator = _FakeTranslator('must not be used');
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: identifier,
        translator: translator,
      );

      for (final query in queries) {
        expect(await preprocessor.preprocess(query), query);
      }
      expect(identifier.queries, queries);
      expect(translator.queries, isEmpty);
    });

    test('uses Filipino markers to translate an English-heavy Taglish query', () async {
      const query = 'Seller says defective yung item pero ayaw ibalik pera ko.';
      const translation =
          'The seller says the item is defective but refuses to return my money.';
      final translator = _FakeTranslator(translation);
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: _FakeLanguageIdentifier(const [
          DetectedQueryLanguage(languageTag: 'en', confidence: 0.8),
        ]),
        translator: translator,
      );

      expect(await preprocessor.preprocess(query), translation);
      expect(translator.queries, [query]);
    });

    test('rejects an empty translation so retrieval can fall back', () async {
      const query = 'Hindi ko pinirmahan yung kontrata.';
      final preprocessor = TagalogQueryPreprocessor(
        languageIdentifier: _FakeLanguageIdentifier(const []),
        translator: _FakeTranslator('  '),
      );

      await expectLater(
        preprocessor.preprocess(query),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _FakeLanguageIdentifier implements QueryLanguageIdentifier {
  _FakeLanguageIdentifier(this.languages);

  final List<DetectedQueryLanguage> languages;
  final List<String> queries = [];

  @override
  Future<List<DetectedQueryLanguage>> identifyPossibleLanguages(
    String query,
  ) async {
    queries.add(query);
    return languages;
  }
}

class _FakeTranslator implements TagalogToEnglishTranslator {
  _FakeTranslator(this.translation);

  final String translation;
  final List<String> queries = [];

  @override
  Future<String> translate(String query) async {
    queries.add(query);
    return translation;
  }
}
