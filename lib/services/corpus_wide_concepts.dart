// Corpus-wide, offline legal-concept candidate discovery.
// No article IDs, answer labels, case IDs, model calls, or server dependencies.
// Every article is indexed from its OWN statutory text and headings.
import 'dart:math' as math;
import 'lexical_index.dart';
import 'bilingual_legal_lexicon.dart';
import 'tagalog_morphology.dart';

class _ConceptBridge {
  const _ConceptBridge(this.tag, this.statutePhrases, this.citizenPhrases);
  final String tag;
  final List<String> statutePhrases;
  final List<String> citizenPhrases;
}

// General legal terminology. Both sides can use either statute or citizen
// phrases. These are vocabulary bridges, not rules that select an article.
const _concepts = <_ConceptBridge>[
  _ConceptBridge('cxcontract', ['contract', 'agreement', 'contracting parties', 'meeting of minds'], ['kasunduan', 'kontrata', 'agreement', 'deal', 'nagkasundo', 'napagkasunduan', 'nag usap']),
  _ConceptBridge('cxobligation', ['obligation', 'obliged', 'obligor', 'obligee', 'bound to', 'undertaking'], ['responsibility', 'obligation', 'duty', 'dapat gawin', 'tungkulin', 'pangako', 'promised']),
  _ConceptBridge('cxworkperformance', ['obliged to do', 'render service', 'performance', 'executed at his cost', 'performed', 'fulfillment'], ['unfinished job', 'finish the work', 'failed to do', 'job halfway', 'trabaho', 'pagawa', 'nagpagawa', 'ipagawa', 'tapos', 'tinapos', 'ginawa', 'service']),
  _ConceptBridge('cxfailure', ['fails to do', 'failure', 'does not comply', 'non compliance', 'contravene', 'contravention', 'not comply', 'not fulfilled'], ['refused to', 'failed to', 'ayaw', 'hindi', 'did not', 'didn t', 'refuse', 'breach', 'hindi tumupad', 'hindi natapos', 'iniwan']),
  _ConceptBridge('cxsubstitute', ['executed at his cost', 'at his cost', 'poorly done be undone', 'poorly done', 'at the expense'], ['hire someone else', 'another worker', 'another shop', 'redo', 're do', 'ipagawa sa iba', 'pagawa sa iba', 'itama', 'pag ayos sa iba', 'their expense', 'pinasagot', 'paid for someone else']),
  _ConceptBridge('cxrescission', ['rescind', 'rescission', 'resolve the obligation', 'termination', 'cancellation'], ['cancel', 'terminate', 'kansela', 'bawiin', 'ibalik ang deposit', 'refund the deposit', 'refund payment', 'rescission']),
  _ConceptBridge('cxrefund', ['reimbursement', 'refund', 'return of price', 'return of payment', 'restore', 'restitution'], ['money back', 'deposit back', 'ibalik ang bayad', 'ibalik ang pera', 'refund', 'reimburse', 'return payment', 'bayad ibalik']),
  _ConceptBridge('cxpayment', ['payment', 'pay', 'paid', 'debt', 'debtor', 'creditor', 'price'], ['bayad', 'nagbayad', 'nagbabayad', 'singil', 'utang', 'debt', 'payment', 'installment', 'binayaran']),
  _ConceptBridge('cxdelay', ['delay', 'default', 'due date', 'demand', 'mora', 'delayed'], ['late', 'deadline', 'overdue', 'nahuli', 'naantala', 'hindi pa binabayaran', 'missed the deadline', 'nadelay']),
  _ConceptBridge('cxdamages', ['damages', 'damage', 'compensation', 'liable for damages', 'injury'], ['damages', 'compensation', 'nasira', 'napinsala', 'nasaktan', 'nabasag', 'nagasgas', 'damaged', 'extra expense', 'loss', 'injured']),
  _ConceptBridge('cxnegligence', ['negligence', 'negligent', 'fault', 'omission', 'carelessness'], ['careless', 'negligent', 'did not secure', 'without warning', 'hindi maingat', 'pabaya', 'kapabayaan', 'nagpabaya', 'hindi nag ingat', 'reckless']),
  _ConceptBridge('cxtort', ['quasi delict', 'fault or negligence', 'no pre existing contractual relation'], ['accident', 'no agreement', 'no contract', 'injured by', 'natumba', 'nahulog', 'nabangga', 'nasagasaan', 'accidental injury']),
  _ConceptBridge('cxemployer', ['employer', 'employee', 'employers', 'servants', 'course of employment'], ['worker', 'employer', 'employee', 'staff', 'kumpanya', 'rider', 'trabahador', 'nagtatrabaho']),
  _ConceptBridge('cxlease', ['lease', 'lessor', 'lessee', 'rental', 'rent', 'tenant'], ['rent', 'rented', 'lease', 'landlord', 'tenant', 'inuupahan', 'umuupa', 'nagpaupa', 'nag rerenta', 'nangungupahan', 'paupahan']),
  _ConceptBridge('cxrepairs', ['repair', 'repairs', 'maintain', 'maintenance', 'fit for the use', 'suitable for the use'], ['repairs', 'repair', 'fix', 'leaking', 'tubo', 'kumpuni', 'ipaayos', 'pinaayos', 'sira', 'ayusin', 'inaayos']),
  _ConceptBridge('cxhabitability', ['habitation', 'danger to life', 'suitable for the use', 'fit for the use', 'health', 'safe'], ['unsafe', 'dangerous', 'not safe', 'tumutulo', 'kuryente', 'electrical', 'unsafe to use', 'hindi ligtas']),
  _ConceptBridge('cxproperty', ['property', 'immovable', 'land', 'real property', 'estate', 'ownership'], ['lupa', 'bahay', 'property', 'ari arian', 'pagmamay ari', 'land', 'house', 'lot', 'lote']),
  _ConceptBridge('cxdonation', ['donation', 'donor', 'donee', 'donated', 'gift'], ['donated', 'gift', 'donasyon', 'regalo', 'ibinigay bilang regalo', 'ipinagkaloob', 'pinamigay']),
  _ConceptBridge('cxdocument', ['public document', 'instrument', 'writing', 'written', 'notarial', 'signed'], ['document', 'written', 'signed', 'notarized', 'notaryo', 'kasulatan', 'walang papel', 'walang pirma', 'notaryado', 'dokumento']),
  _ConceptBridge('cxcoownership', ['co ownership', 'co owners', 'co owner', 'common ownership', 'property held in common'], ['jointly owned', 'co owner', 'magkakasama ang may ari', 'pinagsasaluhan', 'shared property', 'coowned']),
  _ConceptBridge('cxpartition', ['partition', 'division of the property', 'divide the common property'], ['divide', 'partition', 'hatiin', 'paghatian', 'hati ng lupa', 'share inheritance']),
  _ConceptBridge('cxinheritance', ['inheritance', 'succession', 'heir', 'estate', 'decedent', 'testament'], ['mana', 'pamana', 'inheritance', 'inherit', 'namana', 'minana', 'heirs', 'testamento']),
  _ConceptBridge('cxeasement', ['easement', 'right of way', 'outlet to a public highway', 'dominant estate', 'servient estate'], ['right of way', 'daan', 'walang daan', 'access road', 'public road', 'daanan', 'pasukan']),
  _ConceptBridge('cxagency', ['agent', 'principal', 'agency', 'authority to act', 'representative'], ['agent', 'kinatawan', 'representative', 'pinahintulutan', 'authority', 'authorization']),
  _ConceptBridge('cxconsent', ['consent', 'approval', 'authorization', 'authority', 'agree'], ['permission', 'consent', 'pahintulot', 'walang pahintulot', 'hindi pumayag', 'did not agree', 'without consent']),
  _ConceptBridge('cxsale', ['sale', 'sold', 'seller', 'buyer', 'purchase', 'vendor'], ['bili', 'binili', 'bumili', 'benta', 'ibinenta', 'sold', 'seller', 'buyer', 'purchase', 'shop']),
  _ConceptBridge('cxgoods', ['goods', 'product', 'merchandise', 'commodity', 'article sold'], ['product', 'item', 'goods', 'produkto', 'paninda', 'binili', 'appliance', 'food']),
  _ConceptBridge('cxdefect', ['defect', 'defective', 'unfit', 'imperfect', 'deficiency', 'quality'], ['broken', 'defective', 'not working', 'sira', 'depekto', 'depektibo', 'mali ang produkto', 'reused part', 'faulty']),
  _ConceptBridge('cxwarranty', ['warranty', 'guarantee', 'remedy for defects', 'merchantable'], ['warranty', 'guarantee', 'repair under warranty', 'replacement', 'palitan', 'refund']),
  _ConceptBridge('cxconsumer', ['consumer', 'consumer product', 'consumer transaction', 'consumer service'], ['customer', 'consumer', 'buyer', 'shop', 'store', 'merchant', 'mamimili', 'tindahan']),
  _ConceptBridge('cxmisrepresentation', ['deceptive', 'misrepresent', 'fraudulent', 'false representation', 'false advertising'], ['advertised as new', 'fake', 'misled', 'misleading', 'niloko', 'panloloko', 'scam', 'peke', 'deceptive']),
  _ConceptBridge('cxunfair', ['unconscionable', 'unfair', 'grossly disadvantageous', 'consumer exploitation'], ['pressured', 'overpriced', 'could not understand', 'very costly', 'abusive', 'one sided', 'unfair', 'pinilit']),
  _ConceptBridge('cxfood', ['food', 'edible', 'food product', 'adulterated', 'contaminated'], ['food', 'pagkain', 'panis', 'bulok', 'contaminated', 'expired', 'inedible']),
  _ConceptBridge('cxservice', ['service', 'services', 'render services', 'labor', 'performed services'], ['service', 'services', 'repair shop', 'cleaning service', 'technician', 'workshop', 'nagpaayos']),
  _ConceptBridge('cxspouse', ['spouse', 'husband', 'wife', 'marriage', 'married'], ['asawa', 'mag asawa', 'husband', 'wife', 'spouse', 'kasal', 'married']),
  _ConceptBridge('cxcommunityproperty', ['absolute community', 'conjugal partnership', 'community property', 'common property of the spouses'], ['community property', 'conjugal', 'ari arian naming mag asawa', 'joint marital property', 'property ng mag asawa']),
  _ConceptBridge('cxchild', ['child', 'children', 'minor', 'offspring'], ['anak', 'bata', 'child', 'children', 'minor', 'batang anak']),
  _ConceptBridge('cxsupport', ['support', 'sustenance', 'maintenance of children', 'support for education'], ['support', 'sustento', 'suporta', 'child support', 'pag aaral', 'tuition', 'gamot', 'education expenses']),
  _ConceptBridge('cxparent', ['parent', 'parents', 'father', 'mother'], ['magulang', 'nanay', 'tatay', 'mother', 'father', 'parent', 'ama', 'ina']),
  _ConceptBridge('cxcustody', ['custody', 'parental authority', 'care of the child', 'parental responsibility'], ['custody', 'kustodiya', 'kanino titira ang anak', 'who gets custody', 'parental authority']),
  _ConceptBridge('cxmeans', ['means', 'resources', 'financial capacity', 'proportion to the resources'], ['salary', 'income', 'means', 'resources', 'kakayahang magbigay', 'sweldo', 'sahod']),
  _ConceptBridge('cxprescription', ['prescription', 'possess as owner', 'acquisitive prescription', 'thirty years'], ['long possession', 'matagal na nakatira', 'possess for years', 'prescription', 'nakapossess', 'hawak ang lupa']),
];

String _normalized(String text) {
  return ' ${text.toLowerCase().replaceAll(RegExp(r"[^a-z0-9]+"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim()} ';
}

bool _hasPhrase(String prepared, String phrase) =>
    prepared.contains(' ${_normalized(phrase).trim()} ');

Set<String> conceptTagsFromStatute(String text) {
  final prepared = _normalized(text);
  return {
    for (final bridge in _concepts)
      if (bridge.statutePhrases.any((phrase) => _hasPhrase(prepared, phrase)))
        bridge.tag,
  };
}

Set<String> conceptTagsFromNarrative(String text) {
  final enriched = '$text ${expandBilingualLegalTerms(text, maxTerms: 24).join(' ')}';
  final prepared = _normalized(enriched);
  return {
    for (final bridge in _concepts)
      if (bridge.citizenPhrases.any((phrase) => _hasPhrase(prepared, phrase)) ||
          bridge.statutePhrases.any((phrase) => _hasPhrase(prepared, phrase)))
        bridge.tag,
  };
}

/// Searchable concepts are extracted from all statutes, not 41 selected IDs.
/// Only tagged lexical candidates are retrieved here; existing E5/BM25 and
/// corpus-grounded explanations are not replaced.
class CorpusWideConceptIndex {
  CorpusWideConceptIndex._(
    this._index,
    this._articleTags,
    this._clauseTags,
    this._conceptIdf,
    this._highestIdf,
  );

  factory CorpusWideConceptIndex.build(List<String> statuteDocuments) {
    final articleTags = [
      for (final statute in statuteDocuments) conceptTagsFromStatute(statute),
    ];
    // Extract issue evidence within individual statutory clauses, not the
    // article-wide union. A lessor in sentence 1 and repairs in sentence 2
    // must not be treated as a single operative clause.
    final clauseTags = [
      for (final statute in statuteDocuments)
        [
          for (final clause in statute.split(RegExp(r'[.;:!?\n]+')))
            if (clause.trim().length >= 8)
              conceptTagsFromStatute(clause),
        ],
    ];
    final documents = [
      for (final tags in articleTags) [...tags, ...tags, ...tags].join(' '),
    ];
    // Document frequencies depend ONLY on the source statute corpus.
    // No user narratives, case IDs or reference labels enter these values.
    final frequencies = <String, int>{};
    for (final tags in articleTags) {
      for (final tag in tags) {
        frequencies[tag] = (frequencies[tag] ?? 0) + 1;
      }
    }
    final n = statuteDocuments.length.toDouble();
    final idf = <String, double>{
      for (final entry in frequencies.entries)
        entry.key: math.log(1.0 +
            (n - entry.value + 0.5) / (entry.value + 0.5)),
    };
    final peak = idf.values.fold<double>(
        0.0, (highest, value) => math.max(highest, value));
    return CorpusWideConceptIndex._(
      Bm25Index.build(documents), articleTags, clauseTags, idf, peak,
    );
  }

  final Bm25Index _index;
  final List<Set<String>> _articleTags;
  final List<List<Set<String>>> _clauseTags;

  // Generic concepts alone are too weak to identify an operative rule.
  // At least one more specific legal-issue concept must be shared.
  static const _broadConcepts = <String>{
    'cxproperty', 'cxfailure', 'cxpayment', 'cxgoods', 'cxsale',
    'cxconsumer', 'cxspouse', 'cxchild', 'cxparent', 'cxobligation',
  };
  final Map<String, double> _conceptIdf;
  final double _highestIdf;

  /// IDF-weighted concept F1, discounted when only common tags agree.
  /// Unlike the broad v3 bonus, this penalizes statutes that only match a
  /// small fraction of the query and have many unrelated article concepts.
  /// The score is always in [0,1]. It is NOT a relevance probability.
  double discriminativeConceptEvidence(int index, Set<String> queryTags) {
    if (index < 0 || index >= _articleTags.length ||
        queryTags.length < 2 || _highestIdf <= 0) return 0.0;
    final article = _articleTags[index];
    final shared = article.intersection(queryTags);
    if (shared.length < 2) return 0.0;
    double sumWeights(Iterable<String> tags) {
      var weight = 0.0;
      for (final tag in tags) {
        weight += _conceptIdf[tag] ?? 0.0;
      }
      return weight;
    }
    final commonWeight = sumWeights(shared);
    final articleWeight = sumWeights(article);
    final queryWeight = sumWeights(queryTags);
    if (commonWeight <= 0.0 || articleWeight <= 0.0 ||
        queryWeight <= 0.0) return 0.0;
    final precision = (commonWeight / articleWeight).clamp(0.0, 1.0);
    final recall = (commonWeight / queryWeight).clamp(0.0, 1.0);
    if (precision + recall <= 0.0) return 0.0;
    final overlapF1 = 2.0 * precision * recall / (precision + recall);
    final weights = [for (final tag in shared) _conceptIdf[tag] ?? 0.0]
      ..sort((a, b) => b.compareTo(a));
    // Two independent distinctive concepts are required. The rarity factor
    // limits promotions based on generic terms (e.g. property/failure).
    final pairSpecificity =
        ((weights[0] + weights[1]) / (2.0 * _highestIdf))
            .clamp(0.0, 1.0);
    return (overlapF1 * (0.25 + 0.75 * pairSpecificity))
        .clamp(0.0, 1.0).toDouble();
  }
  /// Corpus-grounded, within-clause legal-issue agreement in [0,1].
  /// Uses ONLY statute text and general bilingual concept vocabulary.
  /// Distinctive matches in a single clause count; matches spread across
  /// unrelated clauses do not. This is an evidence heuristic, not a
  /// probability or a determination of legal applicability.
  double clauseLocalEvidence(int index, Set<String> queryTags) {
    if (index < 0 || index >= _clauseTags.length ||
        queryTags.length < 2 || _highestIdf <= 0.0) return 0.0;
    double idfSum(Iterable<String> tags) => tags.fold<double>(
        0.0, (sum, tag) => sum + (_conceptIdf[tag] ?? 0.0));
    final queryWeight = idfSum(queryTags);
    if (queryWeight <= 0.0) return 0.0;
    var best = 0.0;
    for (final clause in _clauseTags[index]) {
      final shared = clause.intersection(queryTags);
      if (shared.length < 2 ||
          !shared.any((tag) => !_broadConcepts.contains(tag))) continue;
      final clauseWeight = idfSum(clause);
      final commonWeight = idfSum(shared);
      if (clauseWeight <= 0.0 || commonWeight <= 0.0) continue;
      final precision = (commonWeight / clauseWeight).clamp(0.0, 1.0);
      final recall = (commonWeight / queryWeight).clamp(0.0, 1.0);
      final harmonic = precision + recall > 0.0
          ? 2.0 * precision * recall / (precision + recall) : 0.0;
      final weights = [for (final tag in shared) _conceptIdf[tag] ?? 0.0]
        ..sort((a, b) => b.compareTo(a));
      final pairRarity = ((weights[0] + weights[1]) /
              (2.0 * _highestIdf)).clamp(0.0, 1.0);
      final value = (harmonic * (0.35 + 0.65 * pairRarity))
          .clamp(0.0, 1.0).toDouble();
      if (value > best) best = value;
    }
    return best;
  }

  int get indexedArticles => _articleTags.length;
  int get conceptTaggedArticles => _articleTags.where((tags) => tags.isNotEmpty).length;

  Set<String> queryTags(String narrative, {bool tagalogWordForms = false}) {
    if (!tagalogWordForms) return conceptTagsFromNarrative(narrative);
    final extra = normalizeTagalogForms(narrative).join(' ');
    return conceptTagsFromNarrative('$narrative $extra');
  }

  List<({int index, double score})> searchTags(
    Set<String> tags, {int limit = 100}) {
    if (tags.isEmpty) return const [];
    return _index.search(tags.join(' '), limit: limit);
  }

  int sharedConceptCount(int index, Set<String> tags) =>
      _articleTags[index].intersection(tags).length;
}
