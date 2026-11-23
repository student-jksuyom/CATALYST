// CATALYST evaluation-only bilingual legal lexicon.
// Expand legal *vocabulary* for BM25; no hard-coded statute IDs or predicted law.
// Never replace the citizen's original words or modify E5 embeddings.

const Map<String, List<String>> _phraseGlosses = {
  'hindi tumupad': <String>['obligation', 'comply', 'performance'],
  'hindi tinupad': <String>['obligation', 'comply', 'performance'],
  'ayaw tumupad': <String>['obligation', 'comply', 'performance'],
  'hindi natupad': <String>['obligation', 'performance'],
  'hindi ginawa': <String>['obligation', 'performance', 'execute'],
  'hindi tinapos': <String>['performance', 'work', 'undertaking'],
  'hindi natapos': <String>['performance', 'work', 'undertaking'],
  'hindi binayaran': <String>['payment', 'obligation', 'delay'],
  'hindi nagbayad': <String>['payment', 'obligation', 'delay'],
  'ayaw magbayad': <String>['payment', 'obligation', 'delay'],
  'ayaw bayaran': <String>['payment', 'obligation', 'delay'],
  'walang pahintulot': <String>['without', 'consent', 'authority'],
  'walang permiso': <String>['without', 'consent', 'authority'],
  'walang kasulatan': <String>['document', 'writing', 'formalities'],
  'walang dokumento': <String>['document', 'writing', 'formalities'],
  'walang kontrata': <String>['contract', 'agreement', 'writing'],
  'walang pirma': <String>['sign', 'signed', 'writing'],
  'hindi pinirmahan': <String>['contract', 'sign', 'consent'],
  'paalisin sa inuupahan': <String>['lease', 'lessee', 'lessor', 'ejectment'],
  'pinapaalis sa inuupahan': <String>['lease', 'lessee', 'lessor', 'ejectment'],
  'hindi maibalik': <String>['return', 'restitution', 'obligation'],
  'ayaw ibalik': <String>['return', 'restitution', 'obligation'],
  'ibalik ang bayad': <String>['refund', 'reimburse', 'price'],
  'pagbawi ng donasyon': <String>['donation', 'revoke', 'revocation'],
  'pagkansela ng kontrata': <String>['rescission', 'contract', 'obligation'],
  'pagkansela ng kasunduan': <String>['rescission', 'agreement', 'obligation'],
  'binawing kasunduan': <String>['rescission', 'agreement', 'obligation'],
  'pinabayaan ang trabaho': <String>['negligence', 'employer', 'employee'],
  'sinadyang sirain': <String>['damage', 'property', 'liability'],
  'napinsalang ari arian': <String>['damages', 'property', 'liability'],
  'baha at bagyo': <String>['fortuitous', 'unforeseen', 'inevitable'],
};

const Map<String, List<String>> _wordGlosses = {
  'napagkasunduan': <String>['agreement', 'consent', 'obligation'],
  'pinagkasunduan': <String>['agreement', 'consent', 'obligation'],
  'pinagkasunduang': <String>['agreement', 'consent', 'obligation'],
  'kasunduan': <String>['agreement', 'contract'],
  'kontrata': <String>['contract', 'obligation'],
  'napirmahan': <String>['signed', 'contract', 'consent'],
  'nagkasundo': <String>['agreement', 'consent'],
  'paglabag': <String>['violation', 'breach', 'obligation'],
  'lumabag': <String>['breach', 'obligation'],
  'nilabag': <String>['breach', 'obligation'],
  'pagtupad': <String>['performance', 'obligation'],
  'tumupad': <String>['performance', 'obligation'],
  'tinupad': <String>['performance', 'obligation'],
  'natupad': <String>['performance', 'obligation'],
  'nagpagawa': <String>['undertaking', 'work', 'execute'],
  'nagpapagawa': <String>['undertaking', 'work', 'execute'],
  'ipagawa': <String>['work', 'execute', 'expense'],
  'ipinagawa': <String>['work', 'execute', 'expense'],
  'pinagawa': <String>['work', 'execute'],
  'gumawa': <String>['work', 'performance'],
  'ginawa': <String>['work', 'performance'],
  'gumagawa': <String>['work', 'performance'],
  'pagkakayari': <String>['work', 'condition', 'quality'],
  'pananagutan': <String>['liability', 'responsibility'],
  'panagutan': <String>['liable', 'damages'],
  'bayaran': <String>['payment', 'obligation'],
  'nabayaran': <String>['payment', 'obligation'],
  'singilin': <String>['payment', 'obligation'],
  'sinisingil': <String>['payment', 'obligation'],
  'nahuli': <String>['delay'],
  'naantala': <String>['delay', 'performance'],
  'nadelay': <String>['delay', 'performance'],
  'pinabayaan': <String>['negligence', 'fault'],
  'pabaya': <String>['negligence', 'fault'],
  'kapabayaan': <String>['negligence', 'fault'],
  'nagpabaya': <String>['negligence', 'fault'],
  'pagkasira': <String>['damage', 'defect'],
  'napinsala': <String>['damages', 'injury'],
  'nabangga': <String>['negligence', 'damages'],
  'binangga': <String>['negligence', 'damages'],
  'nasagasaan': <String>['negligence', 'damages'],
  'aksidente': <String>['accident', 'negligence'],
  'nasaktan': <String>['injury', 'damages'],
  'nasugatan': <String>['injury', 'damages'],
  'baha': <String>['flood', 'unforeseen', 'inevitable'],
  'binaha': <String>['flood', 'unforeseen', 'inevitable'],
  'bumaha': <String>['flood', 'unforeseen', 'inevitable'],
  'bagyo': <String>['storm', 'unforeseen', 'inevitable'],
  'lindol': <String>['earthquake', 'unforeseen', 'inevitable'],
  'sakuna': <String>['fortuitous', 'unforeseen'],
  'nasunog': <String>['fire', 'damage'],
  'aksaya': <String>['damage', 'waste'],
  'nangupahan': <String>['lessee', 'lease'],
  'umuupa': <String>['lessee', 'lease'],
  'inuupahan': <String>['lease', 'rent'],
  'nangungupahan': <String>['lessee', 'lease'],
  'mayupa': <String>['lessor', 'lease'],
  'nagpaupa': <String>['lessor', 'lease'],
  'pinaalis': <String>['ejectment', 'eviction'],
  'pinalayas': <String>['ejectment', 'eviction'],
  'pinapaalis': <String>['ejectment', 'eviction'],
  'umalis': <String>['leave', 'vacate'],
  'nagrerenta': <String>['lessee', 'lease', 'rent'],
  'nirerenta': <String>['lessee', 'lease', 'rent'],
  'nagkumpuni': <String>['repairs', 'maintenance'],
  'pagkumpuni': <String>['repairs', 'maintenance'],
  'ayusin': <String>['repairs', 'maintenance'],
  'pinaayos': <String>['repairs', 'maintenance'],
  'ipaayos': <String>['repairs', 'maintenance'],
  'donasyon': <String>['donation'],
  'ibinigay': <String>['deliver', 'give'],
  'ipinamana': <String>['inheritance', 'succession'],
  'mana': <String>['inheritance', 'succession'],
  'pamana': <String>['inheritance', 'succession'],
  'pagmamayari': <String>['property', 'ownership'],
  'ariarian': <String>['property', 'ownership'],
  'lupa': <String>['land', 'property'],
  'kasulatan': <String>['document', 'writing'],
  'dokumento': <String>['document', 'writing'],
  'pirma': <String>['signature', 'document'],
  'notaryo': <String>['notarial', 'public', 'document'],
  'notaryado': <String>['notarial', 'public', 'document'],
  'peke': <String>['counterfeit', 'deceptive'],
  'panloloko': <String>['fraud', 'deception'],
  'niloko': <String>['fraud', 'deception'],
  'nadaya': <String>['fraud', 'deception'],
  'nabudol': <String>['fraud', 'deception'],
  'paninda': <String>['product', 'goods'],
  'pagkain': <String>['food', 'product'],
  'panis': <String>['adulterated', 'food'],
  'bulok': <String>['adulterated', 'food'],
  'nabulok': <String>['adulterated', 'food'],
  'napanis': <String>['adulterated', 'food'],
  'palitan': <String>['replacement'],
  'ibalik': <String>['return', 'refund'],
  'resibo': <String>['receipt'],
  'depekto': <String>['defect'],
  'depektibo': <String>['defect', 'warranty'],
  'nabasag': <String>['damage', 'defect'],
  'warranty': <String>['warranty'],
};

final RegExp _tokenPattern = RegExp(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*");

/// Optional, deterministic English legal terms to improve BM25 cross-language
/// candidate discovery. This returns terms *only*, never a legal conclusion.
List<String> expandBilingualLegalTerms(String narrative, {int maxTerms = 16}) {
  if (maxTerms <= 0) return const <String>[];
  final tokens = _tokenPattern.allMatches(narrative.toLowerCase())
      .map((match) => match.group(0)!)
      .toList(growable: false);
  final text = ' ${tokens.join(' ')} ';
  final terms = <String>{};
  for (final entry in _phraseGlosses.entries) {
    if (text.contains(' ${entry.key} ')) terms.addAll(entry.value);
    if (terms.length >= maxTerms) return terms.take(maxTerms).toList();
  }
  for (final token in tokens) {
    final aliases = _wordGlosses[token];
    if (aliases != null) terms.addAll(aliases);
    if (terms.length >= maxTerms) return terms.take(maxTerms).toList();
  }
  return terms.toList(growable: false);
}
