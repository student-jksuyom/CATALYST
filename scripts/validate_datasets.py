"""Validate the prepared CATALYST retrieval splits and article references."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
import re
from typing import Any


DATASET_COLUMNS = (
    "Narrative_ID",
    "Sample Narrative",
    "Language",
    "Case_Category",
    "Law_Applied",
    "Applicable_Article_ID",
    "Relevance_Label",
)
CORPUS_COLUMNS = ("Article_ID", "Law", "Article_Number", "Article Text")
SPLITS = ("Training", "Evaluation", "Testing")
ARTICLE_ID_SEPARATOR = re.compile(r"\s*,\s*")


def _read_workbook(path: Path) -> tuple[list[str], list[dict[str, Any]]]:
    try:
        from openpyxl import load_workbook
    except ImportError as exc:
        raise SystemExit(
            "Missing Python dependency: openpyxl. Install openpyxl and retry."
        ) from exc

    try:
        workbook = load_workbook(path, read_only=True, data_only=True)
    except (OSError, ValueError) as exc:
        raise SystemExit(f"Could not read workbook {path}: {exc}") from exc

    worksheet = workbook.active
    iterator = worksheet.iter_rows(values_only=True)
    try:
        header_values = next(iterator)
    except StopIteration:
        raise SystemExit(f"Workbook is empty: {path}") from None

    headers = [
        str(value).strip() if value is not None else ""
        for value in header_values
    ]
    if len(set(header for header in headers if header)) != len(
        [header for header in headers if header]
    ):
        raise SystemExit(f"Workbook has duplicate column names: {path}")

    records = [
        {
            header: row[index] if index < len(row) else None
            for index, header in enumerate(headers)
            if header
        }
        for row in iterator
        if any(value is not None for value in row)
    ]
    workbook.close()
    return headers, records


def _is_blank(value: Any) -> bool:
    return value is None or (isinstance(value, str) and not value.strip())


def _article_ids(value: Any) -> list[str]:
    if _is_blank(value):
        return []
    return [
        item.strip().casefold()
        for item in ARTICLE_ID_SEPARATOR.split(str(value))
        if item.strip()
    ]


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    dataset_directory = project_root / "DATA" / "Datasets"
    corpus_path = project_root / "DATA" / "Corpus" / "MasterCorpus.xlsx"

    frames: dict[str, list[dict[str, Any]]] = {}
    for split in SPLITS:
        path = dataset_directory / f"{split}dataset.xlsx"
        if not path.is_file():
            raise SystemExit(f"{split} workbook is missing: {path}")
        headers, rows = _read_workbook(path)
        missing = [column for column in DATASET_COLUMNS if column not in headers]
        if missing:
            raise SystemExit(
                f"{split} workbook is missing required columns: {', '.join(missing)}"
            )
        if not rows:
            raise SystemExit(f"{split} workbook contains no data rows.")
        frames[split] = rows

    if not corpus_path.is_file():
        raise SystemExit(f"Master corpus workbook is missing: {corpus_path}")
    corpus_headers, corpus_rows = _read_workbook(corpus_path)
    missing_corpus_columns = [
        column for column in CORPUS_COLUMNS if column not in corpus_headers
    ]
    if missing_corpus_columns:
        raise SystemExit(
            "Master corpus is missing required columns: "
            + ", ".join(missing_corpus_columns)
        )
    if not corpus_rows:
        raise SystemExit("Master corpus contains no article rows.")

    article_ids: set[str] = set()
    duplicate_ids: list[str] = []
    for row_number, row in enumerate(corpus_rows, start=2):
        article_id = str(row["Article_ID"]).strip().casefold()
        if not article_id:
            raise SystemExit(f"Master corpus Excel row {row_number} has no Article_ID.")
        if article_id in article_ids:
            duplicate_ids.append(article_id)
        article_ids.add(article_id)
        for column in ("Law", "Article_Number", "Article Text"):
            if _is_blank(row[column]):
                raise SystemExit(
                    f"Master corpus Excel row {row_number} has a blank {column!r}."
                )
    if duplicate_ids:
        raise SystemExit(
            "Master corpus contains duplicate Article_ID values: "
            + ", ".join(sorted(set(duplicate_ids))[:10])
        )

    narrative_sets: dict[str, set[str]] = {}
    for split, rows in frames.items():
        narrative_sets[split] = set()
        invalid_labels: list[str] = []
        missing_references: list[str] = []
        for row_number, row in enumerate(rows, start=2):
            for column in DATASET_COLUMNS:
                if _is_blank(row[column]):
                    raise SystemExit(
                        f"{split} Excel row {row_number} has a blank {column!r}."
                    )

            narrative = str(row["Sample Narrative"]).strip().casefold()
            narrative_sets[split].add(narrative)

            label = row["Relevance_Label"]
            if label not in (0, 0.0, 1, 1.0):
                invalid_labels.append(f"row {row_number}: {label!r}")

            for article_id in _article_ids(row["Applicable_Article_ID"]):
                if article_id not in article_ids:
                    missing_references.append(
                        f"row {row_number}: {article_id}"
                    )

        if invalid_labels:
            raise SystemExit(
                f"{split} has invalid relevance labels: "
                + ", ".join(invalid_labels[:10])
            )
        if missing_references:
            raise SystemExit(
                f"{split} references unknown corpus article IDs: "
                + ", ".join(missing_references[:10])
            )

    for index, first in enumerate(SPLITS):
        for second in SPLITS[index + 1 :]:
            overlap = narrative_sets[first] & narrative_sets[second]
            if overlap:
                raise SystemExit(
                    f"Narrative leakage between {first} and {second}: "
                    f"{len(overlap)} exact normalized narrative(s)."
                )

    print("Prepared retrieval data validation passed.")
    for split in SPLITS:
        rows = frames[split]
        label_counts = Counter(int(row["Relevance_Label"]) for row in rows)
        print(
            f"  {split}: {len(rows)} rows, {len(narrative_sets[split])} unique "
            f"narratives, {label_counts[1]} relevant / {label_counts[0]} "
            "non-relevant pairs"
        )
    print(f"  Corpus: {len(corpus_rows)} articles, {len(article_ids)} unique IDs")


if __name__ == "__main__":
    main()
