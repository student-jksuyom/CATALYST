"""Create separate, lawyer-review-ready abstention development and evaluation sets."""

from __future__ import annotations

from pathlib import Path

from openpyxl import Workbook
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.worksheet.datavalidation import DataValidation


ROOT = Path(__file__).resolve().parents[2]
DEV_OUTPUT = ROOT / "DATA" / "Datasets" / "Abstention_Development_Review_Set.xlsx"
EVAL_OUTPUT = ROOT / "DATA" / "Datasets" / "Abstention_Independent_Evaluation_Set.xlsx"
LANGUAGES = ("English", "Tagalog", "Taglish")

_DEV_SCENARIOS = (
    {
        "issue_family": "dev_civil_personal_loan",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Private loan and repayment obligations",
        "rationale": "A private loan repayment dispute may be addressed by Civil Code provisions; reviewer should identify the exact relevant articles.",
        "narratives": (
            "I lent my cousin ₱24,000 for a motorcycle repair. He said he would pay me back last month, but now he is ignoring my messages. What can I do about the unpaid loan?",
            "Pinahiram ko ang pinsan ko ng ₱24,000 para sa paayos ng motor. Sabi niya babayaran niya ako noong nakaraang buwan, pero hindi na siya sumasagot. Ano ang puwede kong gawin sa utang?",
            "Pinahiram ko yung cousin ko ng ₱24,000 pangpaayos ng motor. Last month dapat magbayad, pero sine-seen na lang niya messages ko. Ano puwede kong gawin sa utang?",
        ),
    },
    {
        "issue_family": "dev_civil_unperformed_service",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Failure to perform a paid private service agreement",
        "rationale": "A paid service agreement that was not performed may raise Civil Code contract and obligation issues; exact article relevance needs review.",
        "narratives": (
            "I paid a carpenter half in advance to build kitchen cabinets. He stopped coming after taking the money and has not returned the materials. What are my options?",
            "Nagbigay ako ng kalahating bayad sa karpintero para gumawa ng cabinets. Hindi na siya bumalik matapos kunin ang pera at wala rin ang mga materyales. Ano ang puwede kong gawin?",
            "Nag-down ako ng half payment sa carpenter para sa kitchen cabinets. Hindi na siya bumalik after makuha yung pera, pati materials wala. Ano options ko?",
        ),
    },
    {
        "issue_family": "dev_civil_lease_deposit",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Residential lease and return of a deposit",
        "rationale": "The dispute concerns obligations under a private lease; counsel should confirm which Civil Code provisions answer the specific facts.",
        "narratives": (
            "I moved out when my one-year apartment lease ended. The owner kept my deposit for repainting but did not show receipts or a list of damage. Can they do that?",
            "Umalis ako nang matapos ang isang-taong upa ko sa apartment. Hindi ibinalik ng may-ari ang deposito dahil daw sa pintura, pero wala siyang resibo o listahan ng sira. Puwede ba iyon?",
            "Natapos na yung one-year apartment lease ko at nag-move out ako. Kinamkam ng owner yung deposit para raw sa repainting, pero walang resibo o damage list. Puwede ba yun?",
        ),
    },
    {
        "issue_family": "dev_civil_copossession",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Co-ownership of inherited property",
        "rationale": "The parties share inherited property, a subject potentially addressed by Civil Code co-ownership rules; exact relevance is for counsel.",
        "narratives": (
            "My brother and I inherited our parents' house. He rents it out and keeps all the rent, even though we are both listed as heirs. How should the income be handled?",
            "Namana naming magkapatid ang bahay ng mga magulang namin. Pinapaupahan ito ng kuya ko at kinukuha niya lahat ng bayad kahit pareho kaming tagapagmana. Paano dapat hatiin ang kita?",
            "Namana naming magkapatid yung bahay ng parents namin. Pinaparentahan ng kuya ko at sa kanya lahat ng rent, kahit pareho kaming heirs. Paano dapat yung kita?",
        ),
    },
    {
        "issue_family": "dev_family_child_support",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Parental duty to support a child",
        "rationale": "The narrative asks about parental support for a child, potentially covered by Family Code provisions; reviewer must identify relevant articles.",
        "narratives": (
            "My child's father has a regular job but has not helped with school or medical expenses for six months. We were never married. What support can I ask for?",
            "May regular na trabaho ang tatay ng anak ko pero anim na buwan na siyang walang tulong sa school at pagpapagamot. Hindi kami nagpakasal. Ano ang puwede kong hingin na suporta?",
            "May regular work yung father ng anak ko pero six months nang walang share sa school at medical expenses. Hindi kami kasal. Anong support ang puwede kong hingin?",
        ),
    },
    {
        "issue_family": "dev_family_filiation",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Establishing a child's parentage",
        "rationale": "The issue concerns legal filiation and parentage, which may be addressed by Family Code provisions; facts and evidence affect applicability.",
        "narratives": (
            "My daughter is using my surname, but her father will not sign the papers to acknowledge her. What legal steps can I take about her parentage?",
            "Apelyido ko ang gamit ng anak kong babae, pero ayaw pumirma ng tatay niya para kilalanin siya. Ano ang legal na puwede kong gawin tungkol sa pagkilala sa kanya?",
            "Surname ko ang gamit ng daughter ko, pero ayaw pumirma ng father niya para i-acknowledge siya. Ano puwede kong gawin tungkol sa filiation niya?",
        ),
    },
    {
        "issue_family": "dev_family_parental_authority",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Parental authority and child-care arrangements",
        "rationale": "The question concerns parental authority and custody-related decisions; the specific legal answer and missing facts require lawyer review.",
        "narratives": (
            "My ex and I share a child. We disagree about which school she should attend, and he enrolled her without telling me. Who gets to decide?",
            "May anak kami ng ex ko at hindi kami magkasundo kung saang school siya papasok. Ipinatala siya ng tatay niya nang hindi ako sinabihan. Sino ang dapat magdesisyon?",
            "May anak kami ng ex ko. Hindi kami agree kung saang school siya, pero pina-enroll na siya ng father niya without telling me. Sino dapat mag-decide?",
        ),
    },
    {
        "issue_family": "dev_family_marital_property",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Property relations between spouses",
        "rationale": "The dispute concerns property acquired during marriage and may be governed by Family Code property-regime provisions; marriage facts are essential.",
        "narratives": (
            "We bought a small house after we got married. My spouse says it belongs only to them because the title is in their name. Is that always true?",
            "Bumili kami ng maliit na bahay pagkatapos naming ikasal. Sabi ng asawa ko sa kanya lang daw iyon dahil pangalan niya ang nasa titulo. Lagi bang ganoon?",
            "Bumili kami ng maliit na bahay after getting married. Sabi ng spouse ko kanya lang kasi name niya nasa title. Automatic ba yun?",
        ),
    },
    {
        "issue_family": "dev_consumer_defective_appliance",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Defective consumer product and warranty remedy",
        "rationale": "The narrative concerns a defective retail product and a refused warranty remedy, potentially covered by Consumer Act provisions.",
        "narratives": (
            "The washing machine I bought stopped spinning in the first week. The store says the warranty is only for the motor, not the machine. What can I ask them to do?",
            "Tumigil umikot ang washing machine na binili ko sa unang linggo pa lang. Sabi ng tindahan motor lang daw ang sakop ng warranty. Ano ang puwede kong hilingin sa kanila?",
            "First week pa lang, ayaw nang umikot ng washing machine na binili ko. Motor lang daw covered ng warranty sabi ng store. Ano puwede kong ipagawa o ipalit?",
        ),
    },
    {
        "issue_family": "dev_consumer_misleading_listing",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Misleading product description in a consumer sale",
        "rationale": "The seller's product description may be a deceptive sales representation covered by Consumer Act provisions; counsel should verify the exact fit.",
        "narratives": (
            "The listing showed a solid-wood dining table, but the one delivered is thin laminated board. The seller says photos are only for display. Can I return it?",
            "Solid wood daw ang dining table sa listing, pero manipis na laminated board ang dumating. Sabi ng seller display lang daw ang pictures. Puwede ko ba itong ibalik?",
            "Solid wood yung nasa listing, pero laminated board yung dining table na dumating. Sabi ng seller for display lang pics. Puwede ko ba itong i-return?",
        ),
    },
    {
        "issue_family": "dev_labor_overtime",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Labor-law overtime premium and computation",
        "rationale": "The requested overtime rate is a labor-standard rule absent from the bundled statutes; possible general civil-law implications need counsel review.",
        "narratives": (
            "My manager says overtime is already included in my monthly salary because I signed the contract. How much extra should I be paid for Sunday work?",
            "Sabi ng manager kasama na raw sa buwanang sahod ang overtime dahil pinirmahan ko ang kontrata. Magkano ang dagdag kapag Linggo ako nagtrabaho?",
            "Included na raw sa monthly salary yung overtime dahil pinirmahan ko contract. Magkano dapat extra kapag Sunday shift?",
        ),
    },
    {
        "issue_family": "dev_labor_termination",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Statutory separation pay after termination",
        "rationale": "The requested separation-pay formula and eligibility are labor standards not stated in the bundled laws; legal review should check for relevant general provisions.",
        "narratives": (
            "I was laid off after nine years. HR offered one month's pay and says the employment contract allows that. Is there a required separation-pay formula?",
            "Tinanggal ako matapos ang siyam na taon. Isang buwang sahod lang ang alok ng HR at iyon daw ang nasa kontrata. May required bang computation ng separation pay?",
            "Na-layoff ako after nine years. One month pay lang offer ng HR, yun daw nasa employment contract. May required separation-pay formula ba?",
        ),
    },
    {
        "issue_family": "dev_criminal_search",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Criminal procedure governing warrantless searches",
        "rationale": "Search validity and suppression of evidence are criminal-procedure issues absent from the bundled statutes; collateral civil claims are not the requested answer.",
        "narratives": (
            "Officers searched my rented room and took my laptop without showing a warrant. How do I challenge the search in the criminal case?",
            "Hinalughog ng mga pulis ang inuupahan kong kuwarto at kinuha ang laptop ko nang walang ipinakitang warrant. Paano ko kukuwestiyunin ang search sa kasong kriminal?",
            "Nag-search ang officers sa rented room ko at kinuha laptop ko without showing a warrant. Paano i-challenge yung search sa criminal case?",
        ),
    },
    {
        "issue_family": "dev_criminal_bail",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "CLEARLY_OUTSIDE_DOMAIN",
        "concept": "Bail eligibility and criminal-court procedure",
        "rationale": "Bail eligibility, amount, and filing procedure are criminal-procedure matters not covered by the bundled statutes.",
        "narratives": (
            "My brother was arrested last night. Where do we file for bail, and how is the amount decided?",
            "Inaresto ang kapatid ko kagabi. Saan kami maghahain para sa piyansa at paano itinatakda ang halaga?",
            "Naaresto yung brother ko kagabi. Saan magfa-file ng bail at paano kino-compute ang amount?",
        ),
    },
    {
        "issue_family": "dev_tax_vat_refund",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "VAT credit and tax-refund filing deadline",
        "rationale": "The requested VAT refund qualification and deadline are tax rules not in the bundled statutes; using the word refund does not make it a consumer refund issue.",
        "narratives": (
            "Our shop was charged VAT twice on a supplier invoice. What is the deadline to claim the extra payment back from the tax authority?",
            "Dalawang beses kaming siningil ng VAT sa invoice ng supplier. Ano ang deadline para mabawi ang sobrang bayad mula sa tax authority?",
            "Double-charged ng VAT yung supplier invoice namin. Ano deadline para ma-claim back yung sobra sa tax authority?",
        ),
    },
    {
        "issue_family": "dev_immigration_work_visa",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Immigration visa eligibility and work authorization",
        "rationale": "Visa category and work authorization requirements are immigration rules absent from the bundled statutes; a spouse relationship is only context.",
        "narratives": (
            "I married a Filipino citizen and want to work here. Which visa lets me take a job, and how long can I stay before applying?",
            "Nagpakasal ako sa Filipino citizen at gusto kong magtrabaho rito. Anong visa ang puwede kong kunin at gaano katagal akong puwedeng manatili bago mag-apply?",
            "Kinasal ako sa Filipino citizen at gusto kong mag-work dito. Anong visa ang kailangan at gaano katagal puwedeng mag-stay bago mag-apply?",
        ),
    },
    {
        "issue_family": "dev_ip_trademark_registration",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Trademark registration process and required evidence",
        "rationale": "The requested trademark registration steps are intellectual-property procedures absent from the bundled laws; brand ownership or a former contract is incidental.",
        "narratives": (
            "A former business partner is using the name of my clothing shop. What forms and proof do I need to register the brand name?",
            "Ginagamit ng dating business partner ang pangalan ng clothing shop ko. Anong forms at patunay ang kailangan para mairehistro ang brand name?",
            "Ginagamit ng former business partner yung name ng clothing shop ko. Anong forms at proof ang kailangan para ma-register yung brand?",
        ),
    },
    {
        "issue_family": "dev_privacy_access_request",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Data-subject access request and response deadline",
        "rationale": "The requested access right and compliance deadline are specific privacy rules absent from the bundled statutes; the reviewer should check whether any provision is separately relevant.",
        "narratives": (
            "A clinic will not give me a copy of my medical records even after I signed its request form. How many days does it have to respond?",
            "Ayaw ibigay ng clinic ang kopya ng medical records ko kahit pinirmahan ko ang request form. Ilang araw ang palugit nila para sumagot?",
            "Ayaw ibigay ng clinic yung copy ng medical records ko kahit signed yung request form. Ilang days dapat sila mag-respond?",
        ),
    },
    {
        "issue_family": "dev_traffic_license_suspension",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "CLEARLY_OUTSIDE_DOMAIN",
        "concept": "Traffic-code license suspension and appeal process",
        "rationale": "License suspension thresholds and traffic-ticket appeals are traffic-regulation matters not included in the bundled statutes.",
        "narratives": (
            "I received a ticket for using my phone while driving. How many violations can suspend my license, and where do I appeal?",
            "Nakatanggap ako ng ticket dahil gumamit ako ng phone habang nagmamaneho. Ilang violation bago masuspinde ang lisensya at saan ako aapela?",
            "May ticket ako dahil nag-phone habang nagda-drive. Ilang violations bago ma-suspend license ko at saan mag-a-appeal?",
        ),
    },
    {
        "issue_family": "dev_environmental_permit",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Environmental permit and emissions standards",
        "rationale": "The requested environmental permit and emissions thresholds are regulatory requirements absent from the bundled statutes; property ownership is incidental.",
        "narratives": (
            "I own a lot near a creek and want to open a small paint shop. What environmental clearance and emissions limits must I meet first?",
            "May lote ako malapit sa sapa at magbubukas sana ako ng maliit na pagawaan ng pintura. Anong environmental clearance at emissions limit ang kailangan muna?",
            "May lot ako malapit sa creek at mag-o-open sana ng small paint shop. Anong environmental clearance at emissions limits ang kailangan?",
        ),
    },
)

_EVAL_SCENARIOS = (
    {
        "issue_family": "eval_civil_advance_payment",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Return of advance payment after a private sale is cancelled",
        "rationale": "A private sale and advance-payment dispute may involve Civil Code obligations; the reviewer should identify relevant provisions.",
        "narratives": (
            "I paid a 10,000-peso deposit for a second-hand refrigerator. The seller changed the price afterward, so I backed out, but they refuse to return the deposit. What can I do?",
            "Nagbigay ako ng ₱10,000 na paunang bayad para sa second-hand na ref. Tinaasan ng seller ang presyo kaya umatras ako, pero ayaw ibalik ang bayad. Ano ang puwede kong gawin?",
            "Nag-down ako ng ₱10,000 sa second-hand ref. Nagbago yung seller ng price kaya umatras ako, pero ayaw ibalik yung deposit. Ano puwede kong gawin?",
        ),
    },
    {
        "issue_family": "eval_civil_boundary_dispute",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Ownership, boundaries, and use of neighboring land",
        "rationale": "The dispute concerns private ownership and use of land, potentially covered by Civil Code property provisions; survey and title facts matter.",
        "narratives": (
            "My neighbor moved the fence several feet onto our side after we bought the lot. Our title has a different boundary description. How can we resolve this?",
            "Inusog ng kapitbahay ang bakod papasok sa lote namin matapos namin itong bilhin. Iba ang sukat sa titulo namin. Paano ito maaayos?",
            "Inusog ng neighbor yung fence papasok sa lot namin after purchase. Iba yung boundary sa title. Paano namin ito ma-resolve?",
        ),
    },
    {
        "issue_family": "eval_civil_shared_expense",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Reimbursement of shared private expenses",
        "rationale": "The narrative concerns a private agreement to share expenses and may involve Civil Code obligations; exact relevance needs attorney review.",
        "narratives": (
            "I paid the full cost to repair the roof we co-own. My cousin agreed to split it but now says there was no agreement. Can I recover their share?",
            "Ako ang nagbayad ng buong paayos ng bubong na pag-aari naming magpinsan. Nangako siyang hahatiin namin pero sinasabi niyang wala raw usapan. Puwede ko bang singilin ang parte niya?",
            "Ako nagbayad ng full roof repair sa property naming magpinsan. Usapan hati kami, pero ngayon deny siya. Puwede ko bang singilin yung share niya?",
        ),
    },
    {
        "issue_family": "eval_civil_sold_property_delivery",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Private sale where the promised item was not delivered",
        "rationale": "The seller accepted payment but did not deliver the agreed property, potentially a Civil Code sale/obligation issue.",
        "narratives": (
            "I paid for a used delivery van, but the owner sold it to another buyer before turning it over to me. We have signed receipts. What should I do?",
            "Binayaran ko ang second-hand na delivery van, pero naibenta ito ng may-ari sa iba bago niya ibigay sa akin. May pirmadong resibo kami. Ano ang dapat kong gawin?",
            "Bayad na yung used delivery van, pero binenta ng owner sa ibang buyer bago i-turn over sa akin. May signed receipts kami. Ano dapat kong gawin?",
        ),
    },
    {
        "issue_family": "eval_family_parental_travel_consent",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Parental authority and decisions affecting a child",
        "rationale": "The dispute concerns parental decision-making for a child and may be covered by Family Code provisions; facts about custody and consent require review.",
        "narratives": (
            "My child's other parent plans to take her abroad for a month and will not tell me the dates. We both have parental authority. Can I object?",
            "Plano ng kabilang magulang na dalhin sa ibang bansa ang anak namin nang isang buwan pero ayaw sabihin ang petsa. Pareho kaming may parental authority. Puwede ba akong tumutol?",
            "Plano ng other parent dalhin abroad yung anak namin for a month pero ayaw sabihin dates. Pareho kaming may parental authority. Puwede ba akong mag-object?",
        ),
    },
    {
        "issue_family": "eval_family_parent_recognition",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Legal recognition of a child by a parent",
        "rationale": "The question concerns establishing legal parentage and may involve Family Code rules; evidence and status require lawyer review.",
        "narratives": (
            "My son's father wants to acknowledge him now, but the birth certificate was registered without his name. What is the proper way to do that?",
            "Gusto nang kilalanin ng ama ang anak ko pero nairehistro ang birth certificate nang wala ang pangalan niya. Ano ang tamang paraan para maitama iyon?",
            "Gusto nang i-acknowledge ng father yung son ko, pero wala siya sa birth certificate. Ano yung proper process para ma-update iyon?",
        ),
    },
    {
        "issue_family": "eval_family_child_medical_support",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Support obligations for a child's health needs",
        "rationale": "The request concerns family support for a child's medical needs, potentially addressed by Family Code provisions.",
        "narratives": (
            "My former partner sends money for food but refuses to share the cost of our child's prescribed therapy. Is medical care part of child support?",
            "Nagpapadala ng pera ang dati kong partner para sa pagkain pero ayaw niyang makihati sa therapy na nireseta sa anak namin. Kasama ba sa suporta ang pagpapagamot?",
            "Nagpapadala yung ex ko para sa food pero ayaw mag-share sa prescribed therapy ng anak namin. Part ba ng child support ang medical care?",
        ),
    },
    {
        "issue_family": "eval_family_spouse_property_sale",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Property relations between married spouses",
        "rationale": "The issue concerns disposal of property acquired during marriage; applicable Family Code provisions depend on the spouses' property regime.",
        "narratives": (
            "My spouse sold the small business we started after our wedding without discussing it with me. Does the fact that the business is registered under one name settle ownership?",
            "Ipinagbili ng asawa ko ang maliit na negosyong sinimulan namin matapos ikasal nang hindi ako kinakausap. Sapat na bang patunay ng pag-aari ang isang pangalan lang sa rehistro?",
            "Binenta ng spouse ko yung small business na sinimulan namin after the wedding without telling me. Isang pangalan lang sa registration—ibig sabihin ba kanya lang?",
        ),
    },
    {
        "issue_family": "eval_consumer_hidden_fee",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PARAPHRASE",
        "concept": "Consumer disclosure and misleading price representations",
        "rationale": "The seller displayed one price but added an undisclosed required fee, potentially a consumer-law issue requiring exact article review.",
        "narratives": (
            "The appliance store advertised a refrigerator for ₱18,000, then added a mandatory handling fee at checkout. They say the displayed price was only a guide. Is that allowed?",
            "₱18,000 ang presyong nakapaskil sa ref sa tindahan, pero nagdagdag sila ng required handling fee sa cashier. Gabay lang daw ang presyo. Puwede ba iyon?",
            "₱18,000 yung advertised price ng ref, pero may mandatory handling fee sa checkout. Guide lang daw yung price. Allowed ba iyon?",
        ),
    },
    {
        "issue_family": "eval_consumer_repair_warranty",
        "proposed": "PROPOSED_HAS_RELEVANT_ARTICLE",
        "challenge": "IN_SCOPE_PLAIN_LANGUAGE",
        "concept": "Consumer warranty and repair of a defective product",
        "rationale": "The narrative concerns a product fault and refused warranty service, potentially within Consumer Act coverage.",
        "narratives": (
            "The phone I bought keeps shutting off. The shop repaired it twice but it still has the same problem and now they want to charge me again. What can I ask for?",
            "Paulit-ulit namamatay ang phone na binili ko. Dalawang beses na itong inayos ng tindahan pero ganoon pa rin, at gusto na naman nila akong singilin. Ano ang puwede kong hingin?",
            "Laging namamatay yung phone na binili ko. Twice na inayos ng store pero same issue, tapos gusto nila maningil ulit. Ano puwede kong i-request?",
        ),
    },
    {
        "issue_family": "eval_labor_wage_deduction",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Labor standards governing wage deductions",
        "rationale": "The requested permissible wage deductions are labor standards absent from the bundled statutes; a contract keyword is incidental.",
        "narratives": (
            "My employer deducts the cost of broken tools from every paycheck, even when I did not use them. Is that deduction allowed under labor rules?",
            "Ibinabawas ng employer ang presyo ng sirang tools sa bawat sahod ko kahit hindi ko naman ginamit. Pinapayagan ba iyon ng labor rules?",
            "Laging kaltas sa paycheck ko yung sirang tools kahit hindi ko ginamit. Allowed ba yung deduction under labor rules?",
        ),
    },
    {
        "issue_family": "eval_criminal_evidence",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Criminal evidence admissibility and procedure",
        "rationale": "The requested evidence-admissibility standard belongs to criminal procedure, not the bundled civil, family, or consumer texts.",
        "narratives": (
            "The prosecutor wants to use a recording made inside my home without my permission. What rule determines whether it can be used as evidence?",
            "Gustong gamitin ng prosecutor ang recording na ginawa sa loob ng bahay ko nang walang pahintulot. Anong rule ang nagtatakda kung puwede itong gawing ebidensya?",
            "Gustong gamitin ng prosecutor yung recording sa loob ng bahay ko na walang consent. Anong rule kung admissible iyon as evidence?",
        ),
    },
    {
        "issue_family": "eval_tax_income_deduction",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Income-tax deduction eligibility and documentation",
        "rationale": "The requested deductible expense categories and tax documentation are tax rules absent from the bundled statutes.",
        "narratives": (
            "I paid for equipment for my small business and want to deduct it from taxable income. Which receipts and tax rules do I need to follow?",
            "Bumili ako ng kagamitan para sa maliit na negosyo at gusto ko itong ibawas sa taxable income. Anong resibo at tax rules ang kailangan?",
            "Bumili ako ng equipment para sa small business. Paano ibawas sa taxable income at anong receipts ang kailangan?",
        ),
    },
    {
        "issue_family": "eval_immigration_visa_extension",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Immigration visa extension and overstay rules",
        "rationale": "The requested visa-extension process and overstay consequences are immigration matters absent from the bundled statutes.",
        "narratives": (
            "My visitor visa expires next week, but I need to stay longer to care for my spouse. How do I extend it and avoid an overstay penalty?",
            "Mag-e-expire na sa susunod na linggo ang visitor visa ko pero kailangan kong magtagal para alagaan ang asawa ko. Paano ito i-e-extend at maiiwasan ang penalty?",
            "Next week na expiry ng visitor visa ko, pero kailangan ko mag-stay para alagaan spouse ko. Paano mag-extend at avoid overstay penalty?",
        ),
    },
    {
        "issue_family": "eval_ip_music_copyright",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Copyright permission and licensing for music",
        "rationale": "The requested copyright permission and licensing requirements are intellectual-property rules not in the bundled statutes.",
        "narratives": (
            "A cafe is playing my song recordings every night without asking. What permission or license must it get before using my music?",
            "Pinapatugtog ng cafe ang mga recording ng kanta ko gabi-gabi nang hindi nagpapaalam. Anong pahintulot o lisensya ang kailangan nila bago gamitin ang musika ko?",
            "Pinapatugtog ng cafe yung song recordings ko nightly without asking. Anong permission or license ang kailangan bago gamitin yung music ko?",
        ),
    },
    {
        "issue_family": "eval_privacy_deletion_request",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Data-privacy deletion request and compliance deadline",
        "rationale": "The requested data-deletion entitlement and response deadline are privacy-compliance rules absent from the bundled laws; consent-related civil claims are not the requested process.",
        "narratives": (
            "A shopping app still has my account and purchase history after I asked it to delete everything. What deadline does it have to comply?",
            "Nasa shopping app pa rin ang account at purchase history ko kahit hiniling kong burahin lahat. Anong deadline ang dapat nilang sundin?",
            "Nasa shopping app pa yung account at purchase history ko kahit nag-request akong i-delete lahat. Anong deadline nila?",
        ),
    },
    {
        "issue_family": "eval_traffic_license_renewal",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "CLEARLY_OUTSIDE_DOMAIN",
        "concept": "Driver's-license renewal and traffic-code requirements",
        "rationale": "The requested license-renewal requirements and traffic-code penalties are not in the bundled statutes.",
        "narratives": (
            "My driver's license expired while I was abroad. What documents do I need to renew it, and will I be fined?",
            "Nag-expire ang lisensya ko habang nasa abroad ako. Anong dokumento ang kailangan para mag-renew at may multa ba?",
            "Nag-expire driver's license ko habang abroad ako. Anong documents para mag-renew at may fine ba?",
        ),
    },
    {
        "issue_family": "eval_zoning_business_permit",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Zoning approval and local business-permit requirements",
        "rationale": "The requested zoning classification and business-permit process are regulatory matters outside the bundled statutes; ownership of the premises is incidental.",
        "narratives": (
            "I own a house and want to convert its ground floor into a small bakery. How do I check if the zoning allows it and which permit comes first?",
            "May-ari ako ng bahay at gagawing maliit na panaderya ang ground floor. Paano malalaman kung pinapayagan ng zoning at anong permit ang uunahin?",
            "May-ari ako ng bahay at gagawing small bakery yung ground floor. Paano i-check kung allowed sa zoning at anong permit muna?",
        ),
    },
    {
        "issue_family": "eval_social_security_sickness",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "CLEARLY_OUTSIDE_DOMAIN",
        "concept": "Social-security contribution and sickness-benefit qualification",
        "rationale": "The requested contribution threshold and sickness-benefit procedure are social-security rules absent from the bundled statutes.",
        "narratives": (
            "I have been paying SSS but missed several months last year. How many contributions do I need before I can claim sickness benefit?",
            "Nagbabayad ako ng SSS pero may ilang buwan akong hindi nahulugan noong nakaraang taon. Ilang hulog ang kailangan bago makakuha ng sickness benefit?",
            "Nagbabayad ako ng SSS pero may missed contributions last year. Ilang hulog kailangan para makapag-claim ng sickness benefit?",
        ),
    },
    {
        "issue_family": "eval_customs_import_duty",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Customs duty assessment and import-tax refund",
        "rationale": "The requested import-duty assessment and customs refund rules are tax/customs matters not included in the bundled statutes.",
        "narratives": (
            "I ordered a laptop from overseas and customs charged more than the amount shown in the notice. How do I dispute the assessment or get a refund?",
            "Umorder ako ng laptop mula sa ibang bansa at mas mataas ang siningil ng customs kaysa sa nakalagay sa notice. Paano ko kokontrahin ang assessment o hihingi ng refund?",
            "Nag-order ako ng laptop overseas, tapos mas mataas yung customs charge kaysa sa notice. Paano i-dispute yung assessment o mag-refund?",
        ),
    },
    {
        "issue_family": "eval_environmental_discharge",
        "proposed": "PROPOSED_NO_RELEVANT_ARTICLE",
        "challenge": "SHARED_CORPUS_TERMS",
        "concept": "Environmental discharge permit and water-quality standards",
        "rationale": "The requested discharge permit and water-quality thresholds are environmental regulations absent from the bundled statutes; property damage may be a separate issue.",
        "narratives": (
            "A workshop beside our property drains used chemicals into the creek. Which permit and water-quality limit is it required to meet?",
            "Naglalabas ng ginamit na kemikal sa sapa ang pagawaan sa tabi ng lupa namin. Anong permit at limit sa kalidad ng tubig ang kailangan nilang sundin?",
            "Nagdi-drain ng used chemicals sa creek yung workshop katabi ng property namin. Anong permit at water-quality limit ang required?",
        ),
    },
)

_HEADERS = (
    "Case_ID",
    "Narrative",
    "Language",
    "Issue_Family",
    "Challenge_Type",
    "Candidate_Scope_Label",
    "Candidate_Label_Rationale",
    "Candidate_Label_Status",
    "Reviewer_Relevance_Label",
    "Reviewer_Relevant_Article_IDs",
    "Reviewer_Relevance_Rationale",
    "Reviewer_Applicability_Judgment",
    "Reviewer_Applicability_Rationale",
    "Reviewer_Confidence",
    "Review_Date",
    "Reviewer_Name_or_Role",
    "Review_Status",
)


def _build_workbook(
    output: Path,
    prefix: str,
    scenarios: tuple[dict[str, object], ...],
    purpose: str,
) -> None:
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite review workbook: {output}")

    workbook = Workbook()
    cases = workbook.active
    cases.title = "Cases"
    cases.append(_HEADERS)
    case_number = 1
    for scenario in scenarios:
        narratives = scenario["narratives"]
        for language, narrative in zip(LANGUAGES, narratives):
            cases.append(
                (
                    f"{prefix}-{case_number:03d}",
                    narrative,
                    language,
                    scenario["issue_family"],
                    scenario["challenge"],
                    scenario["proposed"],
                    scenario["rationale"],
                    "UNVERIFIED_AI_PROPOSAL",
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    "NEEDS_LEGAL_REVIEW",
                )
            )
            case_number += 1

    cases.freeze_panes = "A2"
    cases.auto_filter.ref = cases.dimensions
    widths = (15, 75, 14, 38, 28, 34, 96, 27, 30, 34, 76, 33, 76, 20, 18, 30, 24)
    for column, width in enumerate(widths, start=1):
        cases.column_dimensions[cases.cell(row=1, column=column).column_letter].width = width
    for cell in cases[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="243B53")
        cell.alignment = Alignment(wrap_text=True, vertical="center")
    cases.row_dimensions[1].height = 42
    for row in cases.iter_rows(min_row=2):
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical="top")

    relevance = DataValidation(
        type="list",
        formula1='"HAS_RELEVANT_ARTICLE,NO_RELEVANT_ARTICLE,UNCERTAIN"',
        allow_blank=True,
    )
    applicability = DataValidation(
        type="list",
        formula1='"APPLIES,POSSIBLY_APPLIES,DOES_NOT_APPLY,INSUFFICIENT_FACTS,NOT_ASSESSED"',
        allow_blank=True,
    )
    confidence = DataValidation(
        type="list",
        formula1='"1,2,3,4,5"',
        allow_blank=True,
    )
    review_status = DataValidation(
        type="list",
        formula1='"NEEDS_LEGAL_REVIEW,REVIEWED"',
        allow_blank=False,
    )
    for validation in (relevance, applicability, confidence, review_status):
        cases.add_data_validation(validation)
    relevance.add(f"I2:I{cases.max_row}")
    applicability.add(f"L2:L{cases.max_row}")
    confidence.add(f"N2:N{cases.max_row}")
    review_status.add(f"Q2:Q{cases.max_row}")

    guide = workbook.create_sheet("Review_Guide")
    guide.append(("Topic", "Instructions"))
    guide_rows = (
        ("Purpose", purpose),
        (
            "Candidate labels",
            "Candidate_Scope_Label and Candidate_Label_Rationale are unverified hypotheses for review only. They are not ground truth and must never be used to train or score the model.",
        ),
        (
            "Relevance label",
            "HAS_RELEVANT_ARTICLE means one or more bundled articles provide a useful legal framework for the concrete question. Enter each relevant corpus article ID and explain why. NO_RELEVANT_ARTICLE means no bundled provision provides a useful answer. Use UNCERTAIN if unresolved.",
        ),
        (
            "Applicability",
            "Judge legal applicability separately from retrieval relevance. An article can be relevant to research while its application to these facts is uncertain. Explain the judgment in Reviewer_Applicability_Rationale.",
        ),
        (
            "Outside-catalogue cases",
            "Do not mark NO_RELEVANT_ARTICLE solely because the primary law is outside CATALYST's catalogue. Consider whether a bundled Civil Code, Family Code, or Consumer Act provision still provides a relevant answer.",
        ),
        (
            "Completion",
            "Set Review_Status to REVIEWED only after entering the relevance decision, rationale, reviewer role, date, confidence, and separate applicability assessment. Mark uncertain cases UNCERTAIN rather than guessing.",
        ),
        (
            "Independent evaluation",
            "The evaluation workbook is reserved for final testing. Do not use its narratives or reviewer labels to train, tune, select thresholds, or revise candidate examples.",
        ),
        (
            "Legal sign-off",
            "These narratives are fictional and the proposed labels were not legally reviewed. A qualified legal professional must validate both the candidate cases and all final labels.",
        ),
    )
    for row in guide_rows:
        guide.append(row)
    guide.column_dimensions["A"].width = 28
    guide.column_dimensions["B"].width = 125
    for row in guide.iter_rows():
        for cell in row:
            cell.alignment = Alignment(wrap_text=True, vertical="top")
    for cell in guide[1]:
        cell.font = Font(bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="243B53")
    guide.freeze_panes = "A2"

    output.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(output)
    print(f"Created {case_number - 1} review cases at {output.relative_to(ROOT)}.")


def build_review_sets() -> None:
    existing = [path for path in (DEV_OUTPUT, EVAL_OUTPUT) if path.exists()]
    if existing:
        raise FileExistsError(
            "Refusing to overwrite review workbooks: "
            + ", ".join(str(path) for path in existing)
        )
    _build_workbook(
        DEV_OUTPUT,
        "DEV2",
        _DEV_SCENARIOS,
        "Development set for training after legal review. Use only its completed reviewer labels.",
    )
    _build_workbook(
        EVAL_OUTPUT,
        "EVAL2",
        _EVAL_SCENARIOS,
        "Independent evaluation set. Keep sealed from development, model training, and threshold selection.",
    )


if __name__ == "__main__":
    build_review_sets()
