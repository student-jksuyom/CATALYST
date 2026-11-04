import '../models/law_match_result.dart';
import 'lexical_index.dart';
import 'query_analysis.dart';

/// Stable article identifier shared by retrieval, tests and evaluation:
/// lowercase law and article with every non-alphanumeric character removed.
String normalizedArticleId(String law, String article) =>
    '${_alnum(law)}:${_alnum(article)}';

String _alnum(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Source-text problems verified against official sources during corpus
/// review. They are reported next to the article; the legal text itself is
/// never rewritten.
const Map<String, String> knownCorpusIssues = {
  'familycode:176':
      'Corpus note: this text predates Republic Act No. 9255 (2004), which '
      'allows an illegitimate child to use the father\'s surname when '
      'filiation is expressly recognized. Verify against an official source.',
  'familycode:213':
      'Corpus note: this text is truncated. The official article also says '
      'no child under seven is separated from the mother unless the court '
      'finds compelling reasons. Verify against an official source.',
};

const String duplicateIdNote =
    'Corpus note: this article number appears more than once in the corpus, '
    'so the text shown may belong to a different article. Verify against an '
    'official source.';

const String legalInformationNotice =
    'This is a retrieval match, not a legal conclusion. CATALYST provides '
    'legal information, not legal advice; confirm with a qualified lawyer.';

String firstStatement(String articleText, {int maxLength = 240}) {
  final text = articleText.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= maxLength) {
    return text;
  }
  final cut = text.substring(0, maxLength);
  final lastSpace = cut.lastIndexOf(' ');
  return '${cut.substring(0, lastSpace > 120 ? lastSpace : maxLength)}...';
}

/// Words from the user's facts whose stems also occur in [articleText].
List<String> sharedWording({
  required Iterable<String> queryTexts,
  required String articleText,
  int limit = 6,
}) {
  final articleStems = contentTerms(articleText).toSet();
  final shared = <String>[];
  final seenStems = <String>{};
  for (final text in queryTexts) {
    for (final word in wordTokens(text)) {
      final stems = contentTerms(word);
      if (stems.isEmpty) continue;
      final stem = stems.first;
      if (articleStems.contains(stem) && seenStems.add(stem)) {
        shared.add(word);
        if (shared.length >= limit) return shared;
      }
    }
  }
  return shared;
}

/// Explanation points mark their key phrase with `**...**`. The markers are
/// explicit annotations from the builder, never derived from keyword matching.
const String emphasisMarker = '**';

String stripEmphasis(String text) => text.replaceAll(emphasisMarker, '');

/// Splits an annotated point into (text, isEmphasized) segments.
List<({String text, bool emphasized})> parseEmphasis(String text) {
  final parts = text.split(emphasisMarker);
  if (parts.length.isEven) {
    // Unbalanced markers: show the plain text rather than guess.
    return [(text: stripEmphasis(text), emphasized: false)];
  }
  return [
    for (var i = 0; i < parts.length; i++)
      if (parts[i].isNotEmpty) (text: parts[i], emphasized: i.isOdd),
  ];
}

/// Marks the first sentence of the provision, after any "Art. N." label, as
/// its main stated rule.
String _emphasizeLead(String text) {
  final label = RegExp(r'^Art(?:icle|\.)?\s*\d+[A-Za-z\-]*\.\s*')
      .firstMatch(text);
  final start = label?.end ?? 0;
  final end = RegExp(r'[.;:](?=\s|$)').firstMatch(text.substring(start));
  final stop = end == null ? text.length : start + end.end;
  if (stop <= start) return text;
  return '${text.substring(0, start)}$emphasisMarker'
      '${text.substring(start, stop)}$emphasisMarker${text.substring(stop)}';
}

String _emphasizeVerify(String note) => note.replaceFirst(
  'Verify against an official source.',
  '${emphasisMarker}Verify against an official source.$emphasisMarker',
);

List<String> buildExplanationPoints({
  required QueryAnalysis? analysis,
  required String articleId,
  required String articleText,
  required Iterable<String> queryTexts,
  required bool hasDuplicateId,
}) {
  final points = <String>[
    'What the provision says: "${_emphasizeLead(firstStatement(articleText))}"',
  ];

  if (analysis != null) {
    final shared = sharedWording(
      queryTexts: queryTexts,
      articleText: articleText,
    );
    points.add(
      shared.isEmpty
          ? 'No direct wording overlap with your facts was found. This match '
                'rests on semantic similarity only, so **treat it as weaker.**'
          : 'Wording shared by your facts and this article: '
                '${shared.join(', ')}. Shared words suggest a possible link; '
                '**they do not prove the article applies.**',
    );
    if (analysis.hasNegation) {
      points.add(
        'Your facts include a refusal or negation '
        '(${analysis.negationCues.join(', ')}). **Check that the article\'s '
        'conditions match who did, or did not do, what.**',
      );
    }
  }

  final note = knownCorpusIssues[articleId];
  if (note != null) points.add(_emphasizeVerify(note));
  if (hasDuplicateId) points.add(_emphasizeVerify(duplicateIdNote));
  points.add(legalInformationNotice);
  return points;
}

const _tagalogNotes = {
  'familycode:176':
      'Tala sa corpus: mas luma ang tekstong ito kaysa sa Republic Act No. 9255 '
      '(2004), na nagpapahintulot sa batang illegitimate na gamitin ang apelyido '
      'ng ama kapag malinaw na kinilala ang filiation. **I-verify sa opisyal na source.**',
  'familycode:213':
      'Tala sa corpus: putol ang tekstong ito. Ayon sa opisyal na artikulo, hindi '
      'dapat ihiwalay sa ina ang batang wala pang pitong taong gulang maliban kung '
      'may nakakukumbinsing dahilan ayon sa korte. **I-verify sa opisyal na source.**',
};

const _tagalogDuplicateNote =
    'Tala sa corpus: lumilitaw nang higit sa isang beses ang numero ng artikulong '
    'ito sa corpus, kaya maaaring ibang artikulo ang tekstong ipinapakita. '
    '**I-verify sa opisyal na source.**';

/// Cautions and disclaimers for one language code (`en`, `taglish`, `tl`).
/// They are shown apart from the explanation, under a "Reminder" label.
List<String> buildReminders(
  String code, {
  required String articleId,
  bool hasDuplicateId = false,
}) {
  if (code == 'en') {
    return [
      'Shared words only suggest a link. **They do not prove this article '
          'applies to your case.**',
      'CATALYST gives legal information, not legal advice. Please confirm '
          'with a qualified lawyer.',
      if (knownCorpusIssues[articleId] != null)
        _emphasizeVerify(knownCorpusIssues[articleId]!),
      if (hasDuplicateId) _emphasizeVerify(duplicateIdNote),
    ];
  }
  final taglish = code == 'taglish';
  return [
    taglish
        ? 'Palatandaan lang ng posibleng link ang shared words. **Hindi nito '
              'napapatunayang applicable ang article sa kaso mo.**'
        : 'Palatandaan lang ng posibleng koneksyon ang magkaparehong salita. '
              '**Hindi nito napapatunayang naaangkop ang artikulo sa kaso mo.**',
    taglish
        ? 'Nagbibigay ang CATALYST ng legal information, hindi legal advice. '
              'Kumonsulta sa abogado para makasiguro.'
        : 'Nagbibigay ang CATALYST ng legal na impormasyon, hindi legal na payo. '
              'Kumonsulta sa abogado para makasiguro.',
    if (_tagalogNotes[articleId] != null) _tagalogNotes[articleId]!,
    if (hasDuplicateId) _tagalogDuplicateNote,
  ];
}

/// Offline explanation in all three languages. It cannot paraphrase the
/// provision, so it explains why the article surfaced and what to check, and
/// it does not repeat the article text shown on the same screen.
Map<String, ExplanationVariant> buildExplanationVariants({
  required QueryAnalysis analysis,
  required String articleId,
  required String articleText,
  required Iterable<String> queryTexts,
  required bool hasDuplicateId,
}) {
  final shared = sharedWording(
    queryTexts: queryTexts,
    articleText: articleText,
  );
  final words = shared.join(', ');
  final cues = analysis.negationCues.join(', ');

  List<String> points(String code) {
    final overlap = shared.isNotEmpty;
    switch (code) {
      case 'en':
        return [
          overlap
              ? 'This article came up because your story and the provision use '
                    'some of the same words: **$words.** Check whether it covers '
                    'what actually happened to you.'
              : 'This article came up because its meaning is close to your '
                    'story, but no words match exactly, so **treat it as a '
                    'weaker match.**',
          if (analysis.hasNegation)
            'Your story includes a refusal or a "not" ($cues). **Check whether '
                'the article\'s conditions fit who did, or did not do, what.**',
          'The full text of the law is shown above. Connect to the internet '
              'for a simple-words explanation of how it fits your story.',
        ];
      case 'tl':
        return [
          overlap
              ? 'Lumabas ang artikulong ito dahil may mga salita sa kuwento mo '
                    'na nakasulat din sa probisyon: **$words.** Tingnan kung '
                    'sakop nito ang totoong nangyari sa iyo.'
              : 'Lumabas ang artikulong ito dahil malapit ang kahulugan nito '
                    'sa kuwento mo, pero walang eksaktong magkaparehong salita, '
                    'kaya **ituring itong mas mahinang tugma.**',
          if (analysis.hasNegation)
            'May pagtanggi o "hindi" sa kuwento mo ($cues). **Suriin kung '
                'tugma ang mga kondisyon ng artikulo kung sino ang gumawa o '
                'hindi gumawa ng ano.**',
          'Nasa itaas ang buong teksto ng batas. Kumonekta sa internet para '
              'makakuha ng paliwanag sa simpleng salita kung paano ito '
              'konektado sa kuwento mo.',
        ];
      default:
        return [
          overlap
              ? 'Lumabas ang article na ito kasi may mga salita sa story mo na '
                    'nasa provision din: **$words.** I-check kung sakop talaga '
                    'nito ang nangyari sa iyo.'
              : 'Lumabas ang article na ito kasi malapit ang meaning nito sa '
                    'story mo, pero walang exact na magkaparehong salita, kaya '
                    '**mas mahina ang match na ito.**',
          if (analysis.hasNegation)
            'May pagtanggi o "hindi" sa story mo ($cues). **I-check kung tugma '
                'ang conditions ng article kung sino ang gumawa o hindi gumawa '
                'ng ano.**',
          'Nasa itaas ang buong text ng batas. Mag-connect sa internet para '
              'makakuha ng explanation sa simpleng salita kung paano ito '
              'konektado sa story mo.',
        ];
    }
  }

  return {
    for (final code in const ['en', 'taglish', 'tl'])
      code: ExplanationVariant(
        points: points(code),
        reminders: buildReminders(
          code,
          articleId: articleId,
          hasDuplicateId: hasDuplicateId,
        ),
      ),
  };
}
