import 'package:catol/services/explanation_builder.dart';
import 'package:catol/services/explanation_language.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('detectQueryLanguage', () {
    test('Tagalog queries', () {
      expect(
        detectQueryLanguage('Hindi ko pinirmahan yung kontrata.'),
        ExplanationLanguage.tagalog,
      );
      expect(
        detectQueryLanguage(
          'Ayaw ibalik ng seller yung pera ko kahit defective yung item.',
        ),
        ExplanationLanguage.tagalog,
      );
    });

    test('English queries', () {
      expect(
        detectQueryLanguage(
          'The seller refuses to refund my money even though the item is defective.',
        ),
        ExplanationLanguage.english,
      );
      expect(
        detectQueryLanguage('I did not sign the contract.'),
        ExplanationLanguage.english,
      );
    });

    test('Taglish queries', () {
      expect(
        detectQueryLanguage(
          'My kuya sold the lupa namin without asking the other heirs, hindi nila alam.',
        ),
        ExplanationLanguage.taglish,
      );
    });
  });

  group('offline explanation variants', () {
    const articleText =
        'Article 491. None of the co-owners shall, without the consent of the '
        'others, make alterations in the thing owned in common.';
    const query = 'Binenta ng kuya ko ang lupa nang walang pahintulot.';
    final variants = buildExplanationVariants(
      analysis: analyzeQuery(query),
      articleId: 'civilcode:491',
      articleText: articleText,
      queryTexts: const [query, 'sold land without consent'],
      hasDuplicateId: false,
    );

    test('exist in English, Taglish and Tagalog', () {
      expect(variants.keys, containsAll(['en', 'taglish', 'tl']));
    });

    test('do not repeat the article text', () {
      for (final variant in variants.values) {
        expect(
          variant.points.join(' '),
          isNot(contains('None of the co-owners')),
        );
      }
    });

    test('keep disclaimers out of the explanation points', () {
      for (final variant in variants.values) {
        expect(variant.reminders, isNotEmpty);
        expect(variant.points.join(' '), isNot(contains('legal advice')));
        expect(variant.points.join(' '), isNot(contains('legal na payo')));
      }
      expect(variants['en']!.reminders.join(' '), contains('not legal advice'));
      expect(
        variants['tl']!.reminders.join(' '),
        contains('hindi legal na payo'),
      );
    });

    test('each language is written in that language', () {
      expect(
        variants['tl']!.points.first,
        startsWith('Nakakita ang on-device search'),
      );
      expect(
        variants['en']!.points.first,
        startsWith('On-device search found'),
      );
    });
  });

  test('corpus notes are translated and kept as reminders', () {
    final tl = buildReminders('tl', articleId: 'familycode:213');
    expect(tl.join(' '), contains('putol ang tekstong ito'));
    final en = buildReminders(
      'en',
      articleId: 'familycode:213',
      hasDuplicateId: true,
    );
    expect(en.join(' '), contains('truncated'));
    expect(en.join(' '), contains('appears more than once'));
  });
}
