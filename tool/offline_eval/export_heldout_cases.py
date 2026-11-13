"""Export the independent held-out workbook for the production ranking harness."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

from openpyxl import load_workbook


ROOT = Path(__file__).resolve().parents[2]
ARTICLES_PATH = ROOT / "assets" / "data" / "legal_articles.json"
REQUIRED_COLUMNS = {
    "Narrative_ID",
    "Sample Narrative",
    "Language",
    "Case_Category",
    "Applicable_Article_ID",
    "Relevance_Label",
    "Intended_Corpus_Scope",
    "Reviewer_Catalogue_Coverage",
    "Applicability_Judgment",
    "Review_Status",
}


def _article_id(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def _article_ids(value: Any, row_number: int) -> list[str]:
    if value is None or not str(value).strip():
        return []
    ids = [part.strip().casefold() for part in str(value).split(",")]
    if any(not article_id for article_id in ids):
        raise ValueError(f"Row {row_number} has an empty article ID.")
    if len(set(ids)) != len(ids):
        raise ValueError(f"Row {row_number} repeats an article ID.")
    return ids


def export_cases(dataset: Path) -> list[dict[str, Any]]:
    corpus = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))
    corpus_ids = {
        f"{_article_id(article['Law'])}:{_article_id(str(article['Article']))}"
        for article in corpus
    }
    dataset_hash = hashlib.sha256(dataset.read_bytes()).hexdigest()
    workbook = load_workbook(dataset, read_only=True, data_only=True)
    groups: dict[str, dict[str, Any]] = {}
    try:
        worksheet = workbook["Cases"] if "Cases" in workbook.sheetnames else workbook.active
        rows = iter(worksheet.values)
        raw_headers = next(rows, None)
        if raw_headers is None:
            raise ValueError("The held-out workbook has no header row.")
        headers = [str(value).strip() if value is not None else "" for value in raw_headers]
        missing = REQUIRED_COLUMNS - set(headers)
        if missing:
            raise ValueError(f"The held-out workbook is missing columns: {sorted(missing)}")
        for row_number, row in enumerate(rows, start=2):
            entry = dict(zip(headers, row))
            case_id = entry["Narrative_ID"]
            query = entry["Sample Narrative"]
            if not isinstance(case_id, str) or not case_id.strip():
                raise ValueError(f"Row {row_number} has no Narrative_ID.")
            if not isinstance(query, str) or not query.strip():
                raise ValueError(f"Row {row_number} has no narrative.")
            language = entry["Language"]
            if language not in {"English", "Tagalog", "Taglish"}:
                raise ValueError(f"Row {row_number} has an unsupported language.")

            scope = entry["Intended_Corpus_Scope"]
            if scope not in {"IN_CATALOGUE_SCOPE", "OUTSIDE_CATALOGUE"}:
                raise ValueError(f"Row {row_number} has an invalid corpus-scope stratum.")
            coverage = entry["Reviewer_Catalogue_Coverage"]
            if coverage not in {"MATCH", "PARTIAL_MATCH", "NO_MATCH", "UNCERTAIN"}:
                raise ValueError(f"Row {row_number} has an invalid catalogue-coverage label.")
            review_status = str(entry["Review_Status"] or "").strip().upper()
            if review_status in {"", "PENDING"}:
                raise ValueError(f"Row {row_number} has not been reviewed.")

            label = entry["Relevance_Label"]
            if label not in (0, 0.0, 1, 1.0):
                raise ValueError(f"Row {row_number} has an invalid Relevance_Label.")
            label = int(label)
            article_ids = _article_ids(entry["Applicable_Article_ID"], row_number)
            unknown = [article_id for article_id in article_ids if article_id not in corpus_ids]
            if unknown:
                raise ValueError(
                    f"Row {row_number} references articles outside the bundled corpus: "
                    f"{unknown}"
                )

            verification = str(
                entry.get("Hard_Negative_Verification_Status") or ""
            ).strip().upper()
            if label == 1 and not article_ids:
                raise ValueError(
                    f"Row {row_number} has a positive label but no relevant article IDs."
                )
            if label == 0 and article_ids and (
                review_status != "REVIEWED"
                or verification not in {"PARTIALLY_VERIFIED", "COMPLETE"}
            ):
                raise ValueError(
                    f"Row {row_number} has article-level negative labels that are not "
                    "confirmed by a completed review. Set the verification status "
                    "and keep unreviewed candidates in Hard_Negative_Article_IDs."
                )
            if label == 0 and not article_ids and coverage != "NO_MATCH":
                raise ValueError(
                    f"Row {row_number} has a negative label without article IDs; "
                    "this is valid only for a reviewed NO_MATCH case."
                )

            key = case_id.strip()
            group = groups.get(key)
            metadata = {
                "datasetId": key,
                "query": query.strip(),
                "language": language,
                "domain": str(entry["Case_Category"] or ""),
                "intendedCorpusScope": scope,
                "catalogueCoverage": coverage,
                "applicabilityJudgment": str(entry["Applicability_Judgment"] or ""),
                "reviewStatus": review_status,
                "datasetHash": dataset_hash,
            }
            if group is None:
                group = {
                    **metadata,
                    "reviewedRelevantArticleIds": [],
                    "confirmedIrrelevantArticleIds": [],
                    "recordedProcessedQuery": query.strip(),
                    "recordedOutcome": "unchanged",
                }
                groups[key] = group
            elif any(group[field] != value for field, value in metadata.items()):
                raise ValueError(
                    f"Rows for {key} disagree on narrative or case-level annotations."
                )

            target = (
                "reviewedRelevantArticleIds"
                if label == 1
                else "confirmedIrrelevantArticleIds"
            )
            for article_id in article_ids:
                if article_id in group[target]:
                    raise ValueError(f"{key} repeats article label {article_id}.")
                group[target].append(article_id)

            if label == 0 and not article_ids:
                group["noCatalogueMatch"] = True
            else:
                group.setdefault("noCatalogueMatch", False)
    finally:
        workbook.close()

    if not groups:
        raise ValueError("The held-out workbook contains no cases.")
    cases = sorted(groups.values(), key=lambda case: case["datasetId"])
    for case in cases:
        if set(case["reviewedRelevantArticleIds"]) & set(
            case["confirmedIrrelevantArticleIds"]
        ):
            raise ValueError(
                f"{case['datasetId']} labels an article both relevant and irrelevant."
            )
        if case["catalogueCoverage"] == "NO_MATCH" and case["reviewedRelevantArticleIds"]:
            raise ValueError(
                f"{case['datasetId']} is marked NO_MATCH but has relevant article IDs."
            )
        if case["catalogueCoverage"] != "NO_MATCH" and not case[
            "reviewedRelevantArticleIds"
        ]:
            raise ValueError(
                f"{case['datasetId']} has no positive labels but is not marked NO_MATCH."
            )
    return cases


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    cases = export_cases(args.dataset)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(cases, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    provisional = sorted({case["reviewStatus"] for case in cases} - {"REVIEWED"})
    print(
        f"Exported {len(cases)} cases: "
        f"{sum(bool(case['reviewedRelevantArticleIds']) for case in cases)} "
        f"retrieval-positive, "
        f"{sum(case['noCatalogueMatch'] for case in cases)} no-match, "
        f"{sum(len(case['confirmedIrrelevantArticleIds']) for case in cases)} "
        "confirmed article-level negatives."
    )
    print("Hard_Negative_Article_IDs were not imported or scored.")
    if provisional:
        print(
            "PROVISIONAL review status: "
            + ", ".join(provisional)
            + ". Use results as a provisional regression baseline pending final review."
        )


if __name__ == "__main__":
    main()
