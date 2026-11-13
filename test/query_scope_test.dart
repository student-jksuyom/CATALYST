import 'package:catol/services/jurisprudence_service.dart';
import 'package:catol/services/query_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only explicit unsupported legal areas are classified out of scope', () {
    expect(
      isClearlyOutsideCatalystScope(
        'I was arrested after a police investigation. What criminal charge?',
      ),
      isTrue,
    );
    expect(
      isClearlyOutsideCatalystScope(
        'My seller did not refund me after returning a defective product.',
      ),
      isFalse,
    );
    expect(
      isClearlyOutsideCatalystScope(
        'I was arrested, but the seller also refused to replace a defective phone.',
      ),
      isFalse,
    );
    expect(isClearlyOutsideCatalystScope('asdf qwer zxcv'), isFalse);
  });

  test('jurisprudence source must be an HTTPS Supreme Court E-Library URL', () {
    final base = <String, Object>{
      'id': 'case-1',
      'title': 'Case v. Example',
      'grNo': 'G.R. No. 1',
      'date': 'January 1, 2024',
    };

    final verified = JurisprudenceCase.fromJson({
      ...base,
      'sourceUrl':
          'https://elibrary.judiciary.gov.ph/thebookshelf/showdocs/1/1',
    });
    final untrusted = JurisprudenceCase.fromJson({
      ...base,
      'sourceUrl': 'https://example.com/case',
    });

    expect(verified.sourceUrl?.host, 'elibrary.judiciary.gov.ph');
    expect(untrusted.sourceUrl, isNull);
  });
}
