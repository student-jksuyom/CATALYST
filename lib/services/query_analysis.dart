/// Deterministic, offline query analysis. It never decides legal meaning: it
/// only normalizes informal spelling, flags negation, adds English legal
/// keywords for common Filipino terms, and detects queries that are too thin.
library;

enum QueryDomain { family, consumer, civil, unknown }

class QueryAnalysis {
  const QueryAnalysis({
    required this.original,
    required this.normalized,
    required this.tokens,
    required this.negationCues,
    required this.glossaryTerms,
    required this.domain,
    required this.needsClarification,
    this.clarifyingQuestion,
  });

  final String original;
  final String normalized;
  final List<String> tokens;
  final List<String> negationCues;

  /// English legal keywords derived from Filipino terms; used as an extra
  /// retrieval signal, never shown as the user's words.
  final List<String> glossaryTerms;
  final QueryDomain domain;
  final bool needsClarification;
  final String? clarifyingQuestion;

  bool get hasNegation => negationCues.isNotEmpty;

  /// English keyword string for an additional embedding variant, or null.
  String? get glossaryQuery =>
      glossaryTerms.isEmpty ? null : glossaryTerms.join(' ');
}

const _informalSpellings = <String, String>{
  'di': 'hindi',
  'ndi': 'hindi',
  'nde': 'hindi',
  'hnd': 'hindi',
  'wla': 'wala',
  'walang': 'wala',
  'sya': 'siya',
  'nya': 'niya',
  'pano': 'paano',
  'pls': 'please',
  'tlga': 'talaga',
  'kc': 'kasi',
  'kse': 'kasi',
  'nirereturn': 'nirere-return',
};

const _negationCues = {
  'hindi',
  'wala',
  'ayaw',
  'huwag',
  'wag',
  'never',
  'not',
  'no',
  'without',
  'refuse',
  'refuses',
  'refused',
  "didn't",
  "doesn't",
  "don't",
  "isn't",
  "wasn't",
  "won't",
  'cannot',
  "can't",
};

// Phrase entries are matched before single words.
const _phraseGlossary = <String, List<String>>{
  'ayaw magbayad': ['refuse to pay', 'delay', 'debtor', 'obligation'],
  'ayaw bayaran': ['refuse to pay', 'delay', 'debtor', 'obligation'],
  'hindi kasal': ['outside marriage', 'illegitimate children', 'filiation'],
  'hindi nagbibigay': ['fails to provide', 'obligation'],
  'hindi nagbabayad': ['fails to pay', 'delay', 'debtor', 'obligation'],
  'tunay na ama': ['father', 'filiation', 'paternity'],
  'ayaw kilalanin': ['refuses to acknowledge', 'filiation', 'recognition'],
  'ayaw ibalik': ['refuse to return', 'refund', 'reimburse'],
  'ayaw tanggapin': ['refuse to accept', 'return', 'rescind'],
  'ayaw palitan': ['refuse to replace', 'replacement'],
  'ayaw i-refund': ['refuse refund', 'reimbursement'],
  'ayaw i refund': ['refuse refund', 'reimbursement'],
  'hindi pa tapos': ['not yet expired', 'period', 'term'],
  'hindi namin alam': ['without knowledge', 'consent'],
  'hindi ko pinirmahan': ['did not sign', 'consent', 'contract'],
  'may sira': ['defective', 'warranty'],
  'sira agad': ['defective', 'warranty'],
  'tunay na may-ari': ['owner', 'ownership'],
};

const _wordGlossary = <String, List<String>>{
  'utang': ['debt', 'loan', 'obligation'],
  'pautang': ['loan', 'creditor'],
  'nangutang': ['loan', 'debtor'],
  'magbayad': ['pay', 'payment'],
  'bayad': ['payment'],
  'nabayad': ['paid', 'payment'],
  'kontrata': ['contract', 'agreement'],
  'kasunduan': ['agreement', 'contract'],
  'pinirmahan': ['signed', 'consent'],
  'pumirma': ['signed', 'consent'],
  'upa': ['lease', 'rent'],
  'umuupa': ['lessee', 'lease', 'rent'],
  'nangungupahan': ['lessee', 'lease', 'rent'],
  'paupahan': ['lease', 'lessor', 'rent'],
  'pinalayas': ['evicted', 'ejectment', 'lessor', 'lease'],
  'pinaalis': ['evicted', 'ejectment', 'lessor', 'lease'],
  'lupa': ['land', 'property', 'ownership'],
  'ari-arian': ['property', 'ownership'],
  'magkakapatid': ['siblings', 'co-owners', 'co-ownership'],
  'binenta': ['sold', 'sale', 'vendor'],
  'ibinenta': ['sold', 'sale', 'vendor'],
  'benta': ['sale', 'vendor'],
  'nagbenta': ['seller', 'sale'],
  'binili': ['purchased', 'buyer', 'sale'],
  'bumili': ['purchased', 'buyer', 'sale'],
  'nabili': ['purchased', 'buyer', 'sale'],
  'sira': ['defective'],
  'depektibo': ['defective', 'warranty'],
  'palitan': ['replace', 'replacement'],
  'ibalik': ['return', 'refund'],
  'pera': ['money', 'price'],
  'resibo': ['receipt'],
  'reklamo': ['complaint'],
  'magreklamo': ['complaint'],
  'niloko': ['deceived', 'fraud'],
  'panloloko': ['fraud', 'deceptive'],
  'scam': ['fraud', 'deceptive'],
  'peke': ['counterfeit', 'deceptive'],
  'asawa': ['spouse', 'husband', 'wife'],
  'kasal': ['marriage', 'married'],
  'ikinasal': ['marriage', 'married'],
  'annulment': ['annulment', 'marriage'],
  'kabit': ['mistress', 'extramarital', 'illegitimate'],
  'anak': ['child', 'children'],
  'mga anak': ['children'],
  'ama': ['father'],
  'tatay': ['father'],
  'ina': ['mother'],
  'nanay': ['mother'],
  'pinsan': ['cousin', 'relative'],
  'sustento': ['support'],
  'suporta': ['support'],
  'magmana': ['inherit', 'succession', 'heir'],
  'mana': ['inheritance', 'succession'],
  'minana': ['inherited', 'inheritance', 'co-owners', 'co-ownership'],
  'namana': ['inherited', 'inheritance', 'co-owners', 'co-ownership'],
  'pinayagan': ['consent', 'permission'],
  'pumayag': ['consent', 'permission'],
  'pahintulot': ['consent', 'permission'],
  'kapatid': ['sibling', 'co-owners'],
  'kuya': ['sibling', 'co-owner'],
  'ate': ['sibling', 'co-owner'],
  'mamanahin': ['inherit', 'succession', 'heir'],
  'pamana': ['inheritance', 'succession'],
  'namatay': ['death', 'estate'],
  'testamento': ['will', 'testamentary'],
  'hiwalay': ['separation', 'separated'],
  'naghiwalay': ['separation', 'separated'],
  'kustodiya': ['custody', 'parental authority'],
  'kilalanin': ['acknowledge', 'filiation'],
  'pagkilala': ['acknowledgment', 'filiation'],
  'pamilya': ['family'],
  'trabaho': ['employment', 'work'],
  'pinagbantaan': ['threat'],
  'sinaktan': ['injury', 'violence'],
};

const _familyCues = {
  'asawa',
  'kasal',
  'anak',
  'ama',
  'ina',
  'tatay',
  'nanay',
  'sustento',
  'suporta',
  'hiwalay',
  'naghiwalay',
  'kustodiya',
  'annulment',
  'pamilya',
  'husband',
  'wife',
  'spouse',
  'child',
  'children',
  'marriage',
  'married',
  'custody',
  'support',
  'father',
  'mother',
  'divorce',
  'annulled',
  'kabit',
  'magmana',
  'inherit',
  'pinsan',
};
const _consumerCues = {
  'bumili',
  'binili',
  'seller',
  'product',
  'refund',
  'warranty',
  'resibo',
  'receipt',
  'online',
  'defective',
  'sira',
  'depektibo',
  'order',
  'inorder',
  'palitan',
  'store',
  'shop',
  'delivered',
  'parcel',
  'reklamo',
  'scam',
  'deceptive',
  'price',
  'buyer',
  'bought',
};
const _civilCues = {
  'utang',
  'kontrata',
  'lupa',
  'upa',
  'umuupa',
  'landlord',
  'tenant',
  'lease',
  'contract',
  'loan',
  'debt',
  'property',
  'sold',
  'sale',
  'binenta',
  'ibinenta',
  'nangutang',
  'kasunduan',
  'pinalayas',
  'evicted',
  'ownership',
  'magbayad',
  'bayad',
};

/// Missing-fact prompts are questions to the user, never assumed facts.
const _missingFactQuestions = <QueryDomain, List<String>>{
  QueryDomain.family: [
    'Are the people involved married to each other?',
    'How old is each child involved?',
    'Is there a birth record or signed document that names the parent?',
  ],
  QueryDomain.consumer: [
    'What exactly was bought, and when?',
    'Did you receive a receipt or a written warranty?',
    'Did you already complain to the seller in writing?',
  ],
  QueryDomain.civil: [
    'Is there a written contract or agreement?',
    'What are the amounts and dates involved?',
    'Has a demand (verbal or written) already been made?',
  ],
  QueryDomain.unknown: [
    'Who is involved and what is their relationship to you?',
    'What exactly happened, and when?',
    'What outcome do you want?',
  ],
};

List<String> missingFactQuestions(QueryDomain domain) =>
    _missingFactQuestions[domain] ??
    _missingFactQuestions[QueryDomain.unknown]!;

const clarifyingQuestionText =
    'Could you tell me a bit more? Please describe who is involved, what '
    'happened, and what outcome you want.';

final RegExp _wordPattern = RegExp(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*");

List<String> wordTokens(String text) => _wordPattern
    .allMatches(text.toLowerCase().replaceAll('’', "'"))
    .map((match) => match.group(0)!)
    .toList(growable: false);

String normalizeQueryText(String text) {
  final collapsed = text
      .replaceAll(RegExp(r'\s+'), ' ')
      // Elongated spellings such as "ayawww" become "ayaw".
      .replaceAllMapped(RegExp(r'([A-Za-z])\1{2,}'), (match) => match.group(1)!)
      .trim();
  return collapsed.splitMapJoin(
    _wordPattern,
    onMatch: (match) {
      final word = match.group(0)!;
      final replacement = _informalSpellings[word.toLowerCase()];
      return replacement == null || replacement.contains('-')
          ? word
          : replacement;
    },
  );
}

QueryAnalysis analyzeQuery(String query) {
  final normalized = normalizeQueryText(query);
  final tokens = wordTokens(normalized);
  final lowered = ' ${tokens.join(' ')} ';

  final glossary = <String>{};
  var remaining = lowered;
  for (final entry in _phraseGlossary.entries) {
    if (remaining.contains(' ${entry.key} ')) {
      glossary.addAll(entry.value);
      remaining = remaining.replaceAll(' ${entry.key} ', ' ');
    }
  }
  for (final token in tokens) {
    final terms = _wordGlossary[token];
    if (terms != null) {
      glossary.addAll(terms);
    }
  }
  if (lowered.contains(' mga anak ')) {
    glossary.addAll(_wordGlossary['mga anak']!);
  }

  final cues = <String>{
    for (final token in tokens)
      if (_negationCues.contains(token)) token,
  };

  var family = 0;
  var consumer = 0;
  var civil = 0;
  for (final token in tokens) {
    if (_familyCues.contains(token)) family++;
    if (_consumerCues.contains(token)) consumer++;
    if (_civilCues.contains(token)) civil++;
  }
  final best = [family, consumer, civil].reduce((a, b) => a > b ? a : b);
  final domain = best == 0
      ? QueryDomain.unknown
      : family == best
      ? QueryDomain.family
      : consumer == best
      ? QueryDomain.consumer
      : QueryDomain.civil;

  final tooShort = tokens.length < 2;
  return QueryAnalysis(
    original: query,
    normalized: normalized,
    tokens: tokens,
    negationCues: cues.toList(growable: false),
    glossaryTerms: glossary.toList(growable: false),
    domain: domain,
    needsClarification: tooShort,
    clarifyingQuestion: tooShort ? clarifyingQuestionText : null,
  );
}
