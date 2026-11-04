"""Builds assets/data/jurisprudence.json from tool/jurisprudence/out/raw/*.txt.

Each record keeps only what the follow-up chat needs: citation metadata, the
Court's lead statement (holding), the dispositive paragraph, the statute
articles the decision relies on, and a few passages that discuss them.
Scanned PDFs without a text layer are skipped and reported.
"""
import collections
import json
import pathlib
import re

here = pathlib.Path(__file__).resolve().parent
root = here.parents[1]
raw = here / "out" / "raw"
target = root / "assets" / "data" / "jurisprudence.json"

LAWS = {
    "CivilCode": ("Civil Code", r"(?:Civil Code|NCC)"),
    "FamilyCode": ("Family Code", r"Family Code"),
    "ConsumerAct": ("Consumer Act", r"(?:Consumer Act|R\.?A\.? No\.? 7394)"),
}
LIGATURES = {"\ufb01": "fi", "\ufb02": "fl", "\ufb03": "ffi", "\ufb04": "ffl", "\ufb00": "ff"}


def clean(text: str) -> str:
    for ligature, plain in LIGATURES.items():
        text = re.sub(f"{ligature} (?=[a-z])", plain, text)
        text = text.replace(ligature, plain)
    text = text.replace("\u02d9", "").replace("\u00ad", "")
    text = re.sub(r"-\n(?=[a-z])", "", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\b\d{0,4}\s*VOL\.\s*[\dA-Z\-]+,\s*[A-Z]+ \d{1,2}, \d{4}", " ", text)
    text = re.sub(r"(?:\d{1,4}\s*)?PHILIPPINE REPORTS(?:\s*\d{1,4})?", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip()


ORG_WORDS = re.compile(r"\b(Inc|Corp|Corporation|Company|Co|Department|Dep't|Republic|People|Office|Bank|Authority|Commission|Heirs|Resort|Services|Lines|Marketing|Motors|Shipping|Foods?|Alabang|Properties)\b", re.I)
SMALL = {"of", "the", "and", "for", "in", "on", "de", "la"}


def party_name(raw: str) -> str:
    raw = re.sub(r"\s+", " ", raw.strip(" ."))
    first = re.split(r"\s+AND\s+|\s+and\s+|\bet al\b|;", raw)[0]
    if re.match(r"(?i)spouses", raw):
        surname = re.split(r"\s+", re.split(r",", raw)[0].strip())[-1]
        return f"Spouses {surname.title()}"
    name = first.split(",")[0].strip(" .")
    if ORG_WORDS.search(name):
        name = re.sub(r"\b(Corporation|Incorporated)\b", lambda m: m.group(0).title(), name) if name.isupper() else name
        if name.isupper():
            name = " ".join(w if w.lower() in SMALL and i else w.capitalize() for i, w in enumerate(name.lower().split()))
        name = re.sub(r"\b(Corporation|Incorporated|Inc\.?|Corp\.?)$", "", name).strip(" ,.")
        return name[:48]
    surname = name.split()[-1]
    return surname.title() if surname.isupper() else surname


def title_of(text: str, fallback: str) -> str:
    cap = re.search(
        r"\]\s+(.{3,160}?),\s*(?:PETITIONERS?|Petitioners?|petitioners?)\b.{0,160}?,?\s*(?:v\.|vs\.?|VS\.?)\s+(.{3,160}?),\s*(?:RESPONDENTS?|Respondents?|respondents?)\b",
        clean(text[:1500]),
    )
    if cap:
        return f"{party_name(cap.group(1))} v. {party_name(cap.group(2))}"
    head = re.search(r"([A-Z][^\d\[\]]{2,60}?\s(?:v\.|vs\.)\s[^\d\[\]]{2,60}?)\s*(?:\d|EN BANC|[A-Z]+ DIVISION)", clean(text[:400]))
    if head:
        return re.sub(r"^(?:PHILIPPINE REPORTS|VOL\.)\s*", "", head.group(1)).strip(" ,.")
    return fallback


def paragraphs(body: str):
    pieces = re.split(r"(?<=[.?!\"\u201d])\s+(?=[A-Z])", body)
    merged, current = [], ""
    for piece in pieces:
        current = f"{current} {piece}".strip()
        if len(current) >= 380:
            merged.append(current)
            current = ""
    if current:
        merged.append(current)
    return merged


TITLE_OVERRIDES = {
    "CivilCode-Negligence": "Gaisano Superstore v. Spouses Rhedey",
    "CivilCode-Obligation": "Lara's Gifts & Decors v. Midtown Industrial Sales",
    "CivilCode-PropertySale": "Spouses Cueno v. Spouses Bautista",
    "ConsumerAct-DeceptiveSales": "Aowa Electronic Philippines v. Department of Trade and Industry",
    "ConsumerAct-Defective Product": "Toyota Shaw v. Aldecañas",
    "ConsumerAct-DefectiveVehicle": "Mazda Quezon Avenue v. Caruncho",
    "ConsumerAct-DefectiveVehicle3": "Department of Trade and Industry v. Toyota Balintawak",
    "ConsumerAct-HealthHazard": "Foodsphere v. Mauricio",
    "ConsumerAct-Negligence": "Department of Health v. Nestle Philippines",
    "ConsumerAct-Parking": "Office of the Solicitor General v. Ayala Land",
    "ConsumerAct-UnauthorizedPromotion": "Department of Health v. Philip Morris Philippines Manufacturing",
    "ConsumerAct-DeceptiveProduct": "PPC Asia v. Department of Trade and Industry",
    "FamilyCode-Divorce(Jap-Fil)": "Republic v. Ng",
    "FamilyCode-HomoMarriage": "Falcis v. Civil Registrar General",
    "FamilyCode-PaternityFiliation": "Ordoña v. Local Civil Registrar of Pasig City",
    "FamilyCode-UnsettledPropertySale": "Heirs of Caburnay v. Heirs of Sison",
    "CivilCode-PropertyDispute": "Dakak Beach Resort v. Spouses Mendezona",
    "CivilCode-PublicDominion": "Republic v. Pasig Rizal Co.",
    "ConsumerAct-AppealOfOrder": "Moran v. Office of the President",
    "ConsumerAct-ProductStandard": "Department of Trade and Industry v. Steelasia",
}
records, skipped = [], []
for path in sorted(raw.glob("*.txt")):
    text = path.read_text(encoding="utf-8")
    law_key, _, topic = path.stem.partition("-")
    if len(text) < 2000:
        skipped.append(path.stem)
        continue
    law_name, law_pattern = LAWS[law_key]
    text_clean = clean(text)

    gr = re.search(r"\[\s*(G\.R\. Nos?\.?[^\]]{3,80}?)\s*\]", text_clean)
    gr_text = gr.group(1) if gr else ""
    gr_no = re.sub(r"[.;,]\s*[A-Z][a-z]+ \d{1,2}, \d{4}.*$", "", gr_text).strip()
    date = re.search(r"([A-Z][a-z]+ \d{1,2}, \d{4})", gr_text)

    after = re.search(r"(?:D\s?E\s?C\s?I\s?S\s?I\s?O\s?N|R\s?E\s?S\s?O\s?L\s?U\s?T\s?I\s?O\s?N)\s+.{0,60}?J\.\s*,?\s*(?:J\.)?\s*:?\s*(.*)", text_clean)
    body = after.group(1) if after else text_clean
    holding = body[:650].rsplit(" ", 1)[0]
    wherefore = list(re.finditer(r"WHEREFORE", body))
    dispositive = body[wherefore[-1].start(): wherefore[-1].start() + 650].rsplit(" ", 1)[0] if wherefore else ""

    counts = collections.Counter()
    for m in re.finditer(r"Articles?\s+(\d{1,4})(?:\s+of\s+(?:the\s+)?([A-Za-z0-9. ]{3,30}))?", body):
        owner = m.group(2) or ""
        if not owner or re.search(law_pattern, owner):
            counts[m.group(1)] += 1
    articles = [a for a, _ in counts.most_common(8)]

    passages = []
    if articles:
        cited = re.compile(r"Articles?\s+(?:" + "|".join(articles) + r")\b")
        for para in paragraphs(body):
            if cited.search(para) and len(para) <= 1100:
                passages.append(para)
            if len(passages) >= 6:
                break

    records.append(
        {
            "id": path.stem,
            "law": law_key,
            "lawName": law_name,
            "topic": re.sub(r"(?<=[a-z])(?=[A-Z0-9])", " ", topic),
            "title": TITLE_OVERRIDES.get(path.stem) or title_of(text, path.stem),
            "grNo": gr_no,
            "date": date.group(1) if date else "",
            "holding": holding,
            "dispositive": dispositive,
            "articles": articles,
            "passages": passages,
        }
    )

target.write_text(json.dumps(records, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
print(f"wrote {len(records)} cases, {target.stat().st_size // 1024} KB; skipped scanned: {skipped}")
for r in records:
    print(f"{r['id']}\t{r['title'][:55]}\t{r['grNo']}\t{r['date']}\tart={r['articles'][:4]}\tp={len(r['passages'])}")
