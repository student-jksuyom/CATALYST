// Optional, deterministic Filipino word-form alignment for offline retrieval.
// Produces general legal vocabulary only. It cannot select any statute/article.
// The original query and multilingual E5 embedding are never changed.

final _wordFormFamilies = <(RegExp, List<String>)>[
  (RegExp(r'^(?:nagbayad|nagbabayad|magbabayad|binayaran|binabayaran|nabayaran|bayaran|pagbabayad|pinabayaran|bayad)$'),
    const ['payment', 'debt', 'obligation']),
  (RegExp(r'^(?:nagpagawa|nagpapagawa|pinagawa|pinapagawa|ipinagawa|ipagawa|pagawa|paggawa|gumawa|ginawa|gagawin|gawain)$'),
    const ['work', 'performance', 'undertaking']),
  (RegExp(r'^(?:nagpaayos|nagpapaayos|pinapaayos|pinaayos|ipinaayos|ipaayos|pag-aayos|inaayos|aayusin|ayusin|nagkumpuni|kinumpuni)$'),
    const ['repair', 'repairs', 'maintenance']),
  (RegExp(r'^(?:nangupahan|nangungupahan|pinauupahan|inuupahan|umuupa|umupa|paupahan|nagpaupa|nagrerenta|nirerenta)$'),
    const ['lease', 'lessor', 'lessee', 'rent']),
  (RegExp(r'^(?:nagbenta|ibinenta|binenta|ibinebenta|binebenta|pinagbili|ipinagbili|bumili|binili)$'),
    const ['sale', 'seller', 'buyer']),
  (RegExp(r'^(?:sinisingil|naningil|sinikil|pinasingil|singilin|nangolekta|nakolekta)$'),
    const ['debt', 'creditor', 'demand']),
  (RegExp(r'^(?:nagsustento|sinustentuhan|sustentuhan|nagsusuporta|sinuportahan)$'),
    const ['support', 'maintenance']),
  (RegExp(r'^(?:pumirma|pinirmahan|napirmahan|pipirma|nakapirma|nagpirma)$'),
    const ['signature', 'signed', 'writing']),
  (RegExp(r'^(?:namana|minana|minamana|ipinamana|pamana|pagmamana|tagapagmana)$'),
    const ['inheritance', 'heir', 'succession']),
  (RegExp(r'^(?:nasira|sinira|nasisira|pininsala|nabasag|nagkasira|sirain)$'),
    const ['damage', 'defect']),
];

List<String> normalizeTagalogForms(String narrative, {int maxTerms = 12}) {
  if (maxTerms <= 0) return const <String>[];
  final tokens = RegExp(r'[a-z]+')
      .allMatches(narrative.toLowerCase())
      .map((match) => match.group(0)!)
      .toSet();
  final terms = <String>{};
  for (final token in tokens) {
    for (final family in _wordFormFamilies) {
      if (!family.$1.hasMatch(token)) continue;
      terms.addAll(family.$2);
      if (terms.length >= maxTerms) {
        return terms.take(maxTerms).toList(growable: false);
      }
      break;
    }
  }
  return terms.toList(growable: false);
}
