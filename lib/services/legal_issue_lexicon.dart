// Experimental, deterministic, legal-concept lexical expansion.
// These are general issue vocabulary bridges, NOT article-number decisions.
// Original query and E5 embeddings are unchanged.
import 'dart:collection';

class _IssueRule {
  const _IssueRule(this.requiredTerms, this.legalTerms);
  final List<String> requiredTerms;
  final List<String> legalTerms;
}

const _issueRules = <_IssueRule>[
  // Obligations / contracts / remedies
  _IssueRule(['agreement', 'contractor'], ['contract', 'meeting', 'minds', 'obligation', 'undertaking']),
  _IssueRule(['both', 'liable'], ['contracting', 'parties', 'bind', 'compliance']),
  _IssueRule(['kontrata', 'bawiin'], ['contract', 'rescission', 'consent', 'reciprocal']),
  _IssueRule(['contractor', 'hindi'], ['obligations', 'fulfillment', 'rescission', 'damages']),
  _IssueRule(['nagpagawa', 'hindi'], ['reciprocal', 'obligations', 'fulfillment', 'rescission']),
  _IssueRule(['hindi', 'natapos'], ['nonperformance', 'fulfillment', 'rescission']),
  _IssueRule(['loan', 'monthly'], ['loan', 'debtor', 'creditor', 'demand', 'delay']),
  _IssueRule(['utang', 'nagbabayad'], ['obligation', 'debtor', 'payment', 'demand', 'delay']),
  _IssueRule(['nangutang', 'magbabayad'], ['obligation', 'debtor', 'payment', 'delay']),
  _IssueRule(['ayaw', 'tanggapin'], ['tender', 'payment', 'consignation', 'creditor']),
  _IssueRule(['payment', 'refused'], ['tender', 'payment', 'consignation', 'creditor']),
  // Events, injuries and responsibility
  _IssueRule(['unexpected', 'flood'], ['unforeseen', 'inevitable', 'events', 'responsible']),
  _IssueRule(['baha', 'materials'], ['unforeseen', 'inevitable', 'events', 'obligation']),
  _IssueRule(['binaha', 'deliver'], ['unforeseen', 'inevitable', 'events', 'obligation']),
  _IssueRule(['rider', 'nagtatrabaho'], ['employers', 'employees', 'responsible', 'damages']),
  _IssueRule(['nabunggo', 'rider'], ['damages', 'negligence', 'employers', 'responsible']),
  _IssueRule(['employee', 'slipped'], ['fault', 'negligence', 'damage', 'quasi', 'delict']),
  _IssueRule(['wet', 'floor'], ['negligence', 'omission', 'damage', 'fault']),
  // Property / lease / donation / inheritance
  _IssueRule(['landlord', 'plumbing'], ['lessor', 'lessee', 'necessary', 'repairs', 'lease']),
  _IssueRule(['landlord', 'terminate'], ['lessee', 'habitation', 'serious', 'danger', 'life', 'health']),
  _IssueRule(['inuupahan', 'pinaalis'], ['lessor', 'lessee', 'lease', 'ejectment']),
  _IssueRule(['inuupahan', 'inaayos'], ['lessor', 'lessee', 'repairs', 'lease']),
  _IssueRule(['lupa', 'kasulatan'], ['immovable', 'public', 'document', 'donation', 'valid']),
  _IssueRule(['donasyon', 'kasulatan'], ['immovable', 'public', 'document', 'donation', 'valid']),
  _IssueRule(['lote', 'donasyon'], ['immovable', 'donation', 'public', 'document']),
  _IssueRule(['lupa', 'daan'], ['easement', 'way', 'outlet', 'public', 'highway']),
  _IssueRule(['public', 'road'], ['easement', 'outlet', 'highway', 'neighboring']),
  _IssueRule(['magkakapatid', 'hatiin'], ['coowners', 'partition', 'common', 'ownership']),
  _IssueRule(['lupa', 'hatiin'], ['coowners', 'partition', 'common', 'ownership']),
  _IssueRule(['machinery', 'defect'], ['hidden', 'defects', 'warranty', 'vendor', 'unfit']),
  _IssueRule(['makina', 'problema'], ['hidden', 'defects', 'warranty', 'vendor', 'unfit']),
  _IssueRule(['secondhand', 'sasakyan'], ['hidden', 'defects', 'warranty', 'vendor']),
  _IssueRule(['same', 'property'], ['double', 'sale', 'ownership', 'registration']),
  _IssueRule(['will', 'legitimate'], ['compulsory', 'heirs', 'legitime', 'preterition']),
  _IssueRule(['agent', 'authorized'], ['agency', 'authority', 'principal', 'ratification']),
  _IssueRule(['secondhand', 'motorcycle'], ['consent', 'offer', 'acceptance', 'contract']),
];

final RegExp _issueTokens = RegExp(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*");

/// Adds at most [maxTerms] unique legal words, based on **multiple** issue cues.
/// This supports BM25 only; no direct article routing or reference IDs.
List<String> expandLegalIssueTerms(String narrative, {int maxTerms = 20}) {
  if (maxTerms <= 0) return const <String>[];
  final words = _issueTokens.allMatches(narrative.toLowerCase())
      .map((m) => m.group(0)!)
      .toSet();
  final result = LinkedHashSet<String>();
  for (final rule in _issueRules) {
    if (rule.requiredTerms.every(words.contains)) {
      result.addAll(rule.legalTerms);
      if (result.length >= maxTerms) break;
    }
  }
  return result.take(maxTerms).toList(growable: false);
}
