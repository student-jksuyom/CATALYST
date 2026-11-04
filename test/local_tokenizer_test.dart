import 'package:catol/services/local_tokenizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalTokenizer tokenizer;

  setUpAll(() async {
    tokenizer = await LocalTokenizer.load();
  });

  test('tokenizes multilingual concerns like the Python baseline', () {
    const cases = <(String, List<int>)>[
      (
        'I bought a phone and it stopped working after only two days. Can I demand a refund or replacement?',
        [
          0,
          87,
          123997,
          10,
          24089,
          136,
          442,
          118066,
          20697,
          7103,
          4734,
          6626,
          13312,
          5,
          4171,
          87,
          35968,
          10,
          127402,
          707,
          91995,
          674,
          32,
          2,
        ],
      ),
      (
        'Binili ko ang telepono ngunit agad itong nasira. Ano ang maaari kong gawin bilang mamimili?',
        [
          0,
          16666,
          2104,
          298,
          348,
          118353,
          31,
          86187,
          53213,
          67039,
          1416,
          2634,
          5,
          11576,
          348,
          58631,
          13568,
          50633,
          20886,
          66419,
          28693,
          32,
          2,
        ],
      ),
      (
        'Nag-order ako online ng shoes, pero fake yung dumating. Pwede ko bang i-return at hingin ang refund?',
        [
          0,
          16321,
          9,
          80596,
          922,
          1118,
          234,
          148100,
          4,
          1788,
          106287,
          15932,
          165037,
          5,
          436,
          1177,
          112,
          298,
          11339,
          17,
          9,
          65395,
          19,
          99,
          101392,
          73,
          348,
          127402,
          32,
          2,
        ],
      ),
      (
        'Binili ko yung phone pero sira agad kahit kakabili ko lang',
        [
          0,
          16666,
          2104,
          298,
          15932,
          24089,
          1788,
          99315,
          53213,
          38076,
          156,
          160267,
          298,
          1937,
          2,
        ],
      ),
    ];

    for (final (query, expectedIds) in cases) {
      expect(tokenizer.encode(query).ids, expectedIds, reason: query);
    }
  });

  test('truncates to the Python model sequence limit', () {
    final encoded = tokenizer.encode(List.filled(160, 'consumer').join(' '));

    expect(encoded.ids, hasLength(128));
    expect(encoded.ids.first, 0);
    expect(encoded.ids.last, 2);
    expect(encoded.attentionMask, everyElement(1));
  });
}
