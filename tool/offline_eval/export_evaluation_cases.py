"""Export labeled positive query groups for the Flutter offline evaluation."""

import argparse
import json
from pathlib import Path

from openpyxl import load_workbook


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    workbook = load_workbook(args.dataset, read_only=True, data_only=True)
    groups = {}
    try:
        rows = iter(workbook.active.values)
        headers = next(rows)
        required = {
            "Narrative_ID",
            "Sample Narrative",
            "Language",
            "Case_Category",
            "Applicable_Article_ID",
            "Relevance_Label",
        }
        missing = required - set(headers)
        if missing:
            raise ValueError(f"Dataset is missing columns: {sorted(missing)}")
        for row_number, row in enumerate(rows, start=2):
            entry = dict(zip(headers, row))
            query = entry["Sample Narrative"]
            if not isinstance(query, str) or not query.strip():
                raise ValueError(f"Row {row_number} has no narrative.")
            label = entry["Relevance_Label"]
            if label not in (0, 1):
                raise ValueError(f"Row {row_number} has an invalid label.")
            article_ids = entry["Applicable_Article_ID"]
            if not isinstance(article_ids, str) or not article_ids.strip():
                raise ValueError(f"Row {row_number} has no article IDs.")
            query = query.strip()
            group = groups.setdefault(
                query.casefold(),
                {
                    "datasetId": str(entry["Narrative_ID"]),
                    "language": str(entry["Language"]),
                    "domain": str(entry["Case_Category"]),
                    "query": query,
                    "recordedProcessedQuery": query,
                    "recordedOutcome": "unchanged",
                    "labels": {},
                },
            )
            for value in article_ids.split(","):
                article_id = value.strip().casefold()
                if not article_id:
                    raise ValueError(f"Row {row_number} has an empty article ID.")
                previous = group["labels"].get(article_id)
                if previous is not None and previous != label:
                    raise ValueError(f"Row {row_number} has a conflicting label.")
                group["labels"][article_id] = label
    finally:
        workbook.close()

    cases = []
    for group in groups.values():
        labels = group.pop("labels")
        relevant = sorted(article for article, label in labels.items() if label == 1)
        if relevant:
            cases.append({**group, "reviewedRelevantArticleIds": relevant})
    if not cases:
        raise ValueError("Dataset contains no positively labeled queries.")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
    print(
        f"Exported {len(cases)} positive queries; "
        f"excluded {len(groups) - len(cases)} negative-only queries."
    )


if __name__ == "__main__":
    main()
