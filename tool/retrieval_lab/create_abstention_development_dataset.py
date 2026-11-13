"""Create a provisional, multilingual scope-classifier development workbook."""

from __future__ import annotations

from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "DATA" / "Datasets" / "Abstention_Development_Dataset.xlsx"

_LANGUAGES = ("English", "Tagalog", "Taglish")

_SCENARIOS = (
    {
        "issue_family": "civil_loan_repayment",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Civil Code: loan and obligation to repay",
        "rationale": "The requested answer concerns repayment of a private loan, an issue addressed by bundled Civil Code provisions.",
        "narratives": (
            "I lent a former coworker 18,000 pesos under a written agreement. The due date passed, but they have not repaid any of it. What rules in the local law collection apply?",
            "Nagpautang ako ng 18,000 pesos sa dating katrabaho at may kasulatan kami. Lumipas na ang takdang bayad pero wala pa siyang binabayaran. Anong tuntunin sa utang ang puwedeng tingnan?",
            "Nagpautang ako ng 18,000 pesos sa dati kong katrabaho, may written agreement kami. Lagpas na sa due date pero wala pa ring bayad. Anong rules sa utang ang relevant?",
        ),
    },
    {
        "issue_family": "civil_contract_performance",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Civil Code: obligations and contracts",
        "rationale": "The requested answer concerns performance of a private service agreement, covered by bundled Civil Code contract provisions.",
        "narratives": (
            "I paid a repair shop in full to fix my water pump by Friday. They kept the payment and never did the work. What contract rules in the local law collection are relevant?",
            "Binayaran ko nang buo ang repair shop para ayusin ang water pump bago mag-Biyernes. Tinanggap nila ang pera pero hindi ginawa ang trabaho. Anong tuntunin sa kontrata ang puwedeng tingnan?",
            "Full payment na sa repair shop para maayos ang water pump by Friday. Kinuha nila yung pera pero hindi nila ginawa. Anong contract rules sa local laws ang relevant?",
        ),
    },
    {
        "issue_family": "civil_lease_and_possession",
        "scope_label": "IN_SCOPE",
        "challenge_type": "DIRECT",
        "corpus_concept": "Civil Code: lease obligations and possession",
        "rationale": "The requested answer concerns a private residential lease and the parties' obligations under it.",
        "narratives": (
            "My landlord changed the locks while my rent was current and kept my deposit without explaining why. Which bundled civil-law rules address the lease and possession?",
            "Pinalitan ng landlord ang kandado kahit bayad ang upa ko at hindi niya ipinaliwanag kung bakit ayaw niyang ibalik ang deposito. Anong civil-law rules tungkol sa lease at possession ang sakop?",
            "Pinalitan ng landlord yung lock kahit updated ang rent ko, tapos ayaw ibalik ang deposit. Anong rules sa lease at possession ang covered ng local laws?",
        ),
    },
    {
        "issue_family": "civil_coownership",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Civil Code: co-ownership and property",
        "rationale": "The requested answer concerns rights and obligations among co-owners of private property.",
        "narratives": (
            "My sister and I inherited a small lot together. She sold a portion without asking me and refuses to account for my share. What property rules in the collection are relevant?",
            "Magkasama naming minana ng kapatid ko ang isang lote. Ipinagbili niya ang bahagi nito nang hindi ako kinakausap at ayaw niyang ibigay ang parte ko. Anong property rules ang puwedeng tingnan?",
            "Magkasama naming inherited ng sister ko yung lote. May binenta siyang portion without asking me at ayaw i-account yung share ko. Anong property rules sa corpus ang relevant?",
        ),
    },
    {
        "issue_family": "civil_negligence_damage",
        "scope_label": "IN_SCOPE",
        "challenge_type": "DIRECT",
        "corpus_concept": "Civil Code: obligations and civil liability",
        "rationale": "The requested answer concerns responsibility for damage caused by another person's careless act, addressed by bundled Civil Code provisions.",
        "narratives": (
            "A contractor left an uncovered hole beside my gate, and a delivery rider was injured there. I want to understand the civil responsibility rules in the bundled laws.",
            "May iniwang bukas na hukay ang contractor sa tabi ng gate namin at may delivery rider na nasaktan doon. Gusto kong malaman ang civil responsibility rules sa mga bundled law.",
            "May iniwang uncovered na hukay yung contractor sa tabi ng gate, tapos may rider na nasaktan. Anong civil liability rules sa local laws ang puwedeng i-check?",
        ),
    },
    {
        "issue_family": "civil_sale_and_delivery",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Civil Code: sale and contractual delivery",
        "rationale": "The requested answer concerns a private sale where the seller accepted payment but did not deliver the agreed item.",
        "narratives": (
            "I bought a used generator from a neighbor and paid the agreed price, but they gave it to someone else instead. Which sale and contract rules in the collection apply?",
            "Binili ko sa kapitbahay ang second-hand na generator at binayaran ko ang napag-usapan, pero sa iba niya ito ibinigay. Anong rules sa bentahan at kontrata ang sakop?",
            "Binayaran ko yung agreed price ng used generator sa kapitbahay ko, pero ibang tao ang binigyan niya. Anong sale/contract rules sa corpus ang puwedeng i-review?",
        ),
    },
    {
        "issue_family": "family_child_support",
        "scope_label": "IN_SCOPE",
        "challenge_type": "DIRECT",
        "corpus_concept": "Family Code: family support",
        "rationale": "The requested answer concerns a parent's family-law support obligation toward a child.",
        "narratives": (
            "The other parent stopped contributing to our child's food and school needs even though they have the means. What family-law rules in the local collection cover support?",
            "Tumigil na ang kabilang magulang sa pagbibigay para sa pagkain at pag-aaral ng anak namin kahit may kakayahan naman siya. Anong family-law rules tungkol sa suporta ang nasa collection?",
            "Hindi na nagbibigay yung other parent para sa pagkain at school needs ng anak namin kahit kaya naman niya. Anong support provisions sa local family law ang relevant?",
        ),
    },
    {
        "issue_family": "family_filiation",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Family Code: filiation and acknowledgment",
        "rationale": "The requested answer concerns a child's legal filiation and acknowledgment by a parent.",
        "narratives": (
            "A father is listed on the child's birth record but now denies being the parent. Which family-law provisions in the bundled collection address acknowledgment and filiation?",
            "Nakalagay ang pangalan ng ama sa birth record ng bata pero itinatanggi na niya ngayon na siya ang magulang. Anong family-law provisions ang tumatalakay sa pagkilala at filiation?",
            "Nasa birth record yung pangalan ng father pero ngayon dini-deny niya na siya ang parent. Anong filiation rules sa bundled family laws ang puwedeng tingnan?",
        ),
    },
    {
        "issue_family": "family_parental_authority",
        "scope_label": "IN_SCOPE",
        "challenge_type": "DIRECT",
        "corpus_concept": "Family Code: parental authority and custody",
        "rationale": "The requested answer concerns parental authority and care arrangements for a child.",
        "narratives": (
            "After we separated, my former partner refuses to let me see our child and makes every decision alone. What parental-authority rules in the collection may be relevant?",
            "Pagkatapos naming maghiwalay, ayaw akong papuntahin ng dati kong partner sa anak namin at siya lang ang nagpapasya sa lahat. Anong rules sa parental authority ang sakop?",
            "After separation, ayaw akong papuntahin ng ex ko sa anak namin at siya lang nagde-decide sa lahat. Anong custody at parental-authority provisions ang relevant?",
        ),
    },
    {
        "issue_family": "family_property_regime",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Family Code: property relations between spouses",
        "rationale": "The requested answer concerns ownership and management of property acquired during marriage.",
        "narratives": (
            "While we were married, my spouse sold a vehicle bought with our shared funds without telling me. Which bundled family-law rules address spouses' property?",
            "Noong kasal kami, ipinagbili ng asawa ko nang hindi sinasabi sa akin ang sasakyang binili gamit ang pinagsamang pera namin. Anong family-law rules tungkol sa property ng mag-asawa ang sakop?",
            "Habang kasal kami, binenta ng spouse ko yung vehicle na binili sa shared funds without telling me. Anong property rules ng Family Code ang puwedeng i-check?",
        ),
    },
    {
        "issue_family": "consumer_defective_goods",
        "scope_label": "IN_SCOPE",
        "challenge_type": "DIRECT",
        "corpus_concept": "Consumer Act: defective goods and warranty remedies",
        "rationale": "The requested answer concerns a defective retail product and the seller's warranty-related obligations.",
        "narratives": (
            "A newly purchased rice cooker stopped heating after two days. The shop refuses repair or replacement despite the written warranty. Which consumer provisions in the collection apply?",
            "Dalawang araw pa lang ay hindi na umiinit ang bagong rice cooker. Ayaw itong ipaayos o palitan ng tindahan kahit may nakasulat na warranty. Anong consumer provisions ang sakop?",
            "Two days pa lang, sira na yung bagong rice cooker. Ayaw i-repair or replace ng store kahit may written warranty. Anong Consumer Act provisions ang relevant?",
        ),
    },
    {
        "issue_family": "consumer_deceptive_advertising",
        "scope_label": "IN_SCOPE",
        "challenge_type": "IN_SCOPE_PARAPHRASE",
        "corpus_concept": "Consumer Act: deceptive sales representations",
        "rationale": "The requested answer concerns a seller's misleading representation about a product offered to consumers.",
        "narratives": (
            "An online seller advertised a phone as brand new and water resistant, but delivered a used device with no such feature. Which consumer-law rules in the corpus address misleading sales claims?",
            "Inanunsyo ng online seller na bago at water-resistant ang phone, pero second-hand na unit na walang ganoong feature ang ipinadala. Anong consumer-law rules tungkol sa mapanlinlang na alok ang sakop?",
            "Advertised as brand new at water-resistant yung phone, pero used unit na wala namang feature ang dumating. Anong deceptive-sales provisions sa Consumer Act ang puwedeng tingnan?",
        ),
    },
    {
        "issue_family": "labor_overtime",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No specific Labor Code overtime rule is bundled",
        "rationale": "The requested overtime rate and computation are labor standards, not answered by the bundled Civil Code, Family Code, or Consumer Act. Synthetic scope label; legal review required.",
        "narratives": (
            "My employer says the work contract makes overtime part of my salary, so no extra pay is due. What exact overtime premium does Philippine labor law require?",
            "Sabi ng employer ko kasama na raw sa work contract at sahod ang overtime kaya wala nang dagdag. Magkano ang eksaktong overtime premium sa labor law?",
            "Sabi ng employer, included na sa salary at contract ang overtime. Anong exact overtime rate ang required ng Labor Code?",
        ),
    },
    {
        "issue_family": "labor_termination_benefits",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No specific statutory separation-pay formula is bundled",
        "rationale": "The requested separation-pay eligibility and formula are labor standards outside the bundled statutes; general contract language does not provide that formula. Synthetic scope label; legal review required.",
        "narratives": (
            "I was dismissed after eight years and my employer says the separation amount in my contract is zero. What statutory separation pay should I receive?",
            "Tinanggal ako matapos ang walong taon at sinasabi ng employer na zero ang separation amount sa contract ko. Magkano ang statutory separation pay na dapat matanggap?",
            "Dismissed ako after eight years, tapos zero daw ang separation amount sa contract. Anong statutory separation pay ang dapat kong makuha?",
        ),
    },
    {
        "issue_family": "labor_workplace_injury",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No workers' compensation or labor-inspection rules are bundled",
        "rationale": "The requested workplace injury benefit and labor-inspection process are statutory labor matters not supplied by the bundled texts. Synthetic scope label; legal review required.",
        "narratives": (
            "A machine injured me during my shift, and my supervisor says the employment agreement releases the company from workplace compensation. What labor benefit and inspection rules apply?",
            "Nasaktan ako sa makina habang naka-duty at sinasabi ng supervisor na nililibre ng employment agreement ang kumpanya sa workplace compensation. Anong labor benefits at inspection rules ang applicable?",
            "Nasaktan ako sa machine habang shift, sabi ng supervisor waived daw sa employment agreement ang compensation. Anong workplace-injury benefits at labor inspection rules ang required?",
        ),
    },
    {
        "issue_family": "criminal_search_and_seizure",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No criminal procedure or warrant rules are bundled",
        "rationale": "The requested search-warrant and evidence-suppression rules are criminal procedure, not answered by the bundled civil, family, or consumer statutes. Synthetic scope label; legal review required.",
        "narratives": (
            "Police searched my rented room without showing a warrant and took my phone. Which rule decides whether the search and evidence are valid?",
            "Hinalughog ng pulis ang inuupahan kong kuwarto nang walang ipinakitang warrant at kinuha ang phone ko. Anong rule ang nagsasabi kung valid ang search at ebidensya?",
            "Nag-search ang police sa rented room ko without showing a warrant, tapos kinuha ang phone. Anong criminal-procedure rule ang nagde-decide kung valid yung evidence?",
        ),
    },
    {
        "issue_family": "criminal_bail",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No criminal bail schedules or procedure are bundled",
        "rationale": "The requested bail eligibility and amount are criminal-procedure questions absent from the bundled texts. Synthetic scope label; legal review required.",
        "narratives": (
            "My brother was arrested and the family wants to know the bail amount and filing steps. Which court rule sets the amount for this charge?",
            "Inaresto ang kapatid ko at gusto naming malaman ang halaga ng piyansa at mga hakbang sa paghahain. Anong court rule ang nagtatakda ng halaga para sa kasong ito?",
            "Na-arrest ang brother ko at gusto naming malaman yung bail amount at filing steps. Anong court rule ang nagse-set ng amount para sa charge?",
        ),
    },
    {
        "issue_family": "tax_refund_deadline",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No tax assessment, VAT, or tax-refund provisions are bundled",
        "rationale": "The requested VAT refund eligibility and filing deadline are tax rules not contained in the bundled statutes. Synthetic scope label; legal review required.",
        "narratives": (
            "I paid VAT twice on a business purchase and want a refund. What tax rule sets the deadline for filing a VAT refund claim?",
            "Dalawang beses akong nagbayad ng VAT sa binili ng negosyo at gusto ko itong ma-refund. Anong tax rule ang nagtatakda ng deadline ng VAT refund claim?",
            "Twice akong nagbayad ng VAT sa business purchase. Anong tax rule ang nagse-set ng filing deadline para sa refund?",
        ),
    },
    {
        "issue_family": "immigration_visa",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No immigration visa eligibility or residency rules are bundled",
        "rationale": "The requested visa eligibility and residency period are immigration rules absent from the bundled texts; family relationships are incidental to the visa criteria. Synthetic scope label; legal review required.",
        "narratives": (
            "My spouse and I have a marriage certificate, but I need to know which visa category lets me work here and how long I must reside first.",
            "May marriage certificate kami ng asawa ko, pero gusto kong malaman kung anong visa category ang puwedeng magtrabaho ako rito at gaano katagal dapat muna akong manirahan.",
            "May marriage certificate kami, pero anong visa category ang puwede akong mag-work dito at ilang taon muna dapat ang residency?",
        ),
    },
    {
        "issue_family": "intellectual_property_registration",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No copyright or trademark registration procedure is bundled",
        "rationale": "The requested trademark registration requirements and filing steps are intellectual-property rules not included in the bundled statutes; ownership and sale terms are incidental. Synthetic scope label; legal review required.",
        "narratives": (
            "I own a small clothing brand and a former business partner copied its name. What documents and filing steps are required to register the trademark?",
            "May sarili akong clothing brand at kinopya ng dating business partner ang pangalan nito. Anong dokumento at filing steps ang kailangan para mairehistro ang trademark?",
            "May clothing brand ako at ginaya ng former business partner yung name. Anong documents at filing steps ang kailangan para ma-register ang trademark?",
        ),
    },
    {
        "issue_family": "data_privacy_access",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No Data Privacy Act subject-access deadlines or compliance process are bundled",
        "rationale": "The requested data-subject access process and response deadline are specific privacy-compliance rules absent from the bundled texts; consent and damages are incidental. Synthetic scope label; legal review required.",
        "narratives": (
            "A clinic has my records and refuses my written request for a copy. What data-privacy deadline and complaint process require it to respond?",
            "Nasa clinic ang records ko at ayaw nilang ibigay ang kopya kahit may nakasulat akong request. Anong data-privacy deadline at complaint process ang nag-oobliga sa kanila?",
            "Nasa clinic yung records ko at refused nila yung written request ko for a copy. Anong data-privacy deadline at complaint process ang dapat sundin?",
        ),
    },
    {
        "issue_family": "traffic_license_suspension",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "CLEARLY_OUTSIDE_DOMAIN",
        "corpus_concept": "No traffic-code license suspension or demerit rules are bundled",
        "rationale": "The requested driver's-license suspension period and demerit process are traffic-regulation rules not included in the bundled statutes. Synthetic scope label; legal review required.",
        "narratives": (
            "I received a traffic citation and need to know how many demerit points suspend a driver's license and how to appeal them.",
            "Nakatanggap ako ng traffic citation at gusto kong malaman kung ilang demerit points bago masuspinde ang lisensya at paano umapela.",
            "May traffic citation ako. Ilang demerit points bago ma-suspend ang driver's license, at paano mag-appeal?",
        ),
    },
    {
        "issue_family": "environmental_permit",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "SHARED_CORPUS_TERMS",
        "corpus_concept": "No environmental permit or emissions-standard rules are bundled",
        "rationale": "The requested environmental permit and emissions thresholds are regulatory standards absent from the bundled statutes; property ownership is incidental. Synthetic scope label; legal review required.",
        "narratives": (
            "I own a parcel near a river and want to open a small workshop. What environmental permit and emissions limit must I satisfy before construction?",
            "May-ari ako ng lote malapit sa ilog at magbubukas sana ako ng maliit na pagawaan. Anong environmental permit at emissions limit ang kailangan bago magpatayo?",
            "May property ako malapit sa river at magtatayo sana ng small workshop. Anong environmental permit at emissions limits ang kailangan muna?",
        ),
    },
    {
        "issue_family": "social_security_benefit",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "CLEARLY_OUTSIDE_DOMAIN",
        "corpus_concept": "No SSS contribution or benefit-eligibility rules are bundled",
        "rationale": "The requested SSS contribution credits and benefit eligibility are social-security rules not included in the bundled statutes. Synthetic scope label; legal review required.",
        "narratives": (
            "My online SSS record is missing several contributions. What contribution count qualifies me for sickness benefit and how do I correct the record?",
            "May ilang hulog na nawawala sa online SSS record ko. Ilang contribution ang kailangan para maging eligible sa sickness benefit at paano itama ang record?",
            "May missing contributions sa SSS record ko. Ilang hulog ang kailangan para sa sickness benefit, at paano ipa-correct yung record?",
        ),
    },
    {
        "issue_family": "election_procedure",
        "scope_label": "OUT_OF_SCOPE",
        "challenge_type": "CLEARLY_OUTSIDE_DOMAIN",
        "corpus_concept": "No election-registration or polling procedure is bundled",
        "rationale": "The requested voter-registration and polling-place procedure is election law, outside the bundled statutes. Synthetic scope label; legal review required.",
        "narratives": (
            "I moved to another city and want to know the deadline and documents for transferring my voter registration before the next election.",
            "Lumipat ako sa ibang lungsod at gusto kong malaman ang deadline at dokumento para mailipat ang voter registration bago ang susunod na eleksyon.",
            "Lumipat ako ng city. Ano ang deadline at documents para ma-transfer yung voter registration ko bago ang next election?",
        ),
    },
)

_HEADERS = (
    "Case_ID",
    "Narrative",
    "Language",
    "Scope_Label",
    "Issue_Family",
    "Challenge_Type",
    "Corpus_Concept",
    "Provisional_Label_Rationale",
    "Label_Status",
    "Legal_Review_Required",
    "Reviewer_Scope_Label",
    "Reviewer_Rationale",
    "Reviewer_Name_or_Role",
    "Review_Date",
)


def build_workbook() -> None:
    workbook = Workbook()
    cases = workbook.active
    cases.title = "Cases"
    cases.append(_HEADERS)

    case_number = 1
    for scenario in _SCENARIOS:
        for language, narrative in zip(_LANGUAGES, scenario["narratives"]):
            cases.append(
                (
                    f"ABST-{case_number:03d}",
                    narrative,
                    language,
                    scenario["scope_label"],
                    scenario["issue_family"],
                    scenario["challenge_type"],
                    scenario["corpus_concept"],
                    scenario["rationale"],
                    "PROVISIONAL_SYNTHETIC",
                    "YES",
                    None,
                    None,
                    None,
                    None,
                )
            )
            case_number += 1

    cases.freeze_panes = "A2"
    cases.auto_filter.ref = cases.dimensions
    widths = (14, 72, 14, 18, 34, 28, 54, 95, 25, 22, 22, 80, 28, 18)
    for column, width in enumerate(widths, start=1):
        cases.column_dimensions[cases.cell(row=1, column=column).column_letter].width = width
    cases.row_dimensions[1].height = 30
    for cell in cases[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="243B53")
        cell.alignment = Alignment(wrap_text=True, vertical="center")
    for row in cases.iter_rows(min_row=2):
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical="top")

    guide = workbook.create_sheet("Label_Guide")
    guide.append(("Field", "Meaning"))
    guide_rows = (
        (
            "Purpose",
            "Separate development data for a provisional abstention classifier. It was authored independently; it is not the held-out quality-gate workbook.",
        ),
        (
            "IN_SCOPE",
            "The narrative asks for a substantive answer represented in the bundled Civil Code, Family Code, or Consumer Act. It does not assert legal applicability to any real person.",
        ),
        (
            "OUT_OF_SCOPE",
            "The specific rule or procedure requested is not represented in those three bundled laws. Shared words and possible collateral remedies do not make that requested answer present.",
        ),
        (
            "Challenge_Type",
            "SHARED_CORPUS_TERMS marks an out-of-scope request that deliberately uses words also found in bundled-law subject matter. IN_SCOPE_PARAPHRASE checks that unfamiliar wording is not itself a reason to abstain.",
        ),
        (
            "Provisional labels",
            "All labels are synthetic and unverified. A legal professional must review both positive and negative scope judgments before release use.",
        ),
        (
            "Review",
            "Use Reviewer_Scope_Label, Reviewer_Rationale, Reviewer_Name_or_Role, and Review_Date columns if conducting legal review. Do not overwrite the original provisional columns.",
        ),
        (
            "No production use",
            "The accompanying classifier is an offline experiment only. It must not suppress or alter production retrieval results.",
        ),
    )
    for row in guide_rows:
        guide.append(row)
    guide.column_dimensions["A"].width = 28
    guide.column_dimensions["B"].width = 120
    for row in guide.iter_rows():
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical="top")
    for cell in guide[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="243B53")
    guide.freeze_panes = "A2"

    if OUTPUT.exists():
        raise FileExistsError(
            f"Refusing to overwrite the development workbook: {OUTPUT}"
        )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(OUTPUT)
    print(f"Created {case_number - 1} provisional cases at {OUTPUT.relative_to(ROOT)}.")


if __name__ == "__main__":
    build_workbook()
