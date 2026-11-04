"""Read-only structural checks for the CATALYST legal datasets."""

from __future__ import annotations

import re
from collections import defaultdict
from pathlib import Path
from typing import Any


TRAINING_COLUMNS = (
    "ID",
    "Case Title",
    "Narrative",
    "Category",
    "Law",
    "Applicable Article",
    "Source",
)
TESTING_COLUMNS = (
    "ID",
    "Narratives",
    "Category",
    "Law",
    "Applicable Article",
)
CORPUS_COLUMNS = ("Law", "Article", "Article Text")
ARTICLE_CLAUSE_SEPARATOR = re.compile(r"[;\r\n]+")
ARTICLE_LIST_SEPARATOR = re.compile(r"\s*(?:,|\band\b|&)\s*", flags=re.IGNORECASE)
ARTICLE_PREFIX = re.compile(r"^\s*(?:articles?|arts?)\.?\s*", flags=re.IGNORECASE)
ARTICLE_IDENTIFIER = re.compile(
    r"\d+(?:\.\d+)*(?:[a-z])?(?:[-–]\d+(?:\.\d+)*(?:[a-z])?)?",
    flags=re.IGNORECASE,
)


def _is_blank(value: Any, pandas: Any) -> bool:
    """Return True for an empty cell or a string containing only whitespace."""
    if pandas.isna(value):
        return True
    return isinstance(value, str) and not value.strip()


def _show(value: Any, pandas: Any) -> str:
    """Show an original cell value clearly, including blanks."""
    return "<blank>" if _is_blank(value, pandas) else repr(value)


def _normalise_label(value: Any, pandas: Any) -> str:
    """Build a comparison key without changing the values in the workbooks."""
    if _is_blank(value, pandas):
        return ""
    return re.sub(r"[^a-z0-9]+", "", str(value).casefold())


def _normalise_article(value: Any, pandas: Any) -> str:
    """Ignore common Article/Art. prefixes and punctuation for comparison."""
    if _is_blank(value, pandas):
        return ""
    without_prefix = ARTICLE_PREFIX.sub("", str(value), count=1)
    return _normalise_label(without_prefix, pandas)


def _parse_article_references(value: Any) -> list[str] | None:
    """Parse simple article identifiers; return None when the format is uncertain."""
    references = []
    clauses = ARTICLE_CLAUSE_SEPARATOR.split(str(value))
    if not clauses or any(not clause.strip() for clause in clauses):
        return None

    for clause in clauses:
        without_prefix = ARTICLE_PREFIX.sub("", clause, count=1).strip()
        parts = ARTICLE_LIST_SEPARATOR.split(without_prefix)
        if not parts or any(not part.strip() for part in parts):
            return None
        for part in parts:
            reference = ARTICLE_PREFIX.sub("", part, count=1).strip()
            if not ARTICLE_IDENTIFIER.fullmatch(reference):
                return None
            references.append(reference)

    return references or None


def _row_numbers(indices: list[int]) -> str:
    """Convert zero-based dataframe positions to Excel row numbers."""
    return ", ".join(str(index + 2) for index in indices)


def _report_value_counts(title: str, series: Any, pandas: Any) -> None:
    print(title)
    if series.empty:
        print("  (no rows)")
        return
    for value, count in series.value_counts(dropna=False, sort=False).items():
        print(f"  {_show(value, pandas)}: {count}")


def _find_duplicate_values(series: Any, pandas: Any) -> dict[Any, list[int]]:
    """Return nonblank exact values mapped to their zero-based row positions."""
    positions: dict[Any, list[int]] = defaultdict(list)
    for index, value in enumerate(series.tolist()):
        if not _is_blank(value, pandas):
            try:
                positions[value].append(index)
            except TypeError:
                # Excel cells are normally scalar; unhashable values cannot be
                # meaningfully compared as exact narrative duplicates.
                continue
    return {value: rows for value, rows in positions.items() if len(rows) > 1}


def main() -> None:
    """Read the three workbooks, report structural issues, and write nothing."""
    try:
        import pandas as pd
    except ImportError as exc:
        raise SystemExit(
            f"Missing Python dependency: {exc.name or 'pandas'}. "
            "Install pandas and openpyxl, then run this validator again."
        ) from exc

    project_root = Path(__file__).resolve().parent.parent
    file_paths = {
        "Training": project_root / "DATA" / "Datasets" / "Trainingdataset.xlsx",
        "Testing": project_root / "DATA" / "Datasets" / "Testingdataset.xlsx",
        "Corpus": project_root / "DATA" / "Corpus" / "MasterCorpus.xlsx",
    }
    required_columns = {
        "Training": TRAINING_COLUMNS,
        "Testing": TESTING_COLUMNS,
        "Corpus": CORPUS_COLUMNS,
    }

    load_errors: list[str] = []
    for name, path in file_paths.items():
        if not path.is_file():
            load_errors.append(f"{name} file is missing: {path}")
    if load_errors:
        raise SystemExit("Cannot validate all datasets:\n  " + "\n  ".join(load_errors))

    frames: dict[str, Any] = {}
    for name, path in file_paths.items():
        try:
            frames[name] = pd.read_excel(path, engine="openpyxl")
        except Exception as exc:
            load_errors.append(f"{name} file is unreadable ({path}): {exc}")
    if load_errors:
        raise SystemExit("Cannot validate all datasets:\n  " + "\n  ".join(load_errors))

    column_errors = []
    for name, frame in frames.items():
        if name == "Testing":
            print(f"Testing workbook path: {file_paths[name].resolve()}")
            print(f"Loaded Testing columns: {[repr(column) for column in frame.columns]}")
            print(f"TESTING_COLUMNS entries: {[repr(column) for column in TESTING_COLUMNS]}")
        missing = [column for column in required_columns[name] if column not in frame.columns]
        if name == "Testing":
            print(f"Testing missing required columns: {missing!r}")
        if missing:
            column_errors.append(
                f"{name} is missing required column(s): {', '.join(missing)}"
            )
    if column_errors:
        raise SystemExit("Cannot validate all datasets:\n  " + "\n  ".join(column_errors))

    training = frames["Training"]
    testing = frames["Testing"]
    corpus = frames["Corpus"]
    warnings: list[str] = []

    print("Dataset validation summary")
    print(f"  Training rows: {len(training)}")
    print(f"  Testing rows: {len(testing)}")
    print(f"  Master corpus rows: {len(corpus)}")
    _report_value_counts("Training counts by Law:", training["Law"], pd)
    _report_value_counts("Training counts by Category:", training["Category"], pd)
    _report_value_counts("Testing counts by Law:", testing["Law"], pd)
    _report_value_counts("Testing counts by Category:", testing["Category"], pd)
    _report_value_counts("Corpus counts by Law:", corpus["Law"], pd)

    for name, frame in frames.items():
        for column in required_columns[name]:
            for index, value in enumerate(frame[column].tolist()):
                if _is_blank(value, pd):
                    warnings.append(
                        f"{name} Excel row {index + 2}: required column "
                        f"{column!r} is blank (original value: {_show(value, pd)})."
                    )

    narrative_columns = (
        ("Training", training, "Narrative"),
        ("Testing", testing, "Narratives"),
    )
    for name, frame, narrative_column in narrative_columns:
        for narrative, indices in _find_duplicate_values(
            frame[narrative_column], pd
        ).items():
            warnings.append(
                f"{name} has an exact duplicate {narrative_column} in Excel rows "
                f"{_row_numbers(indices)} (original value: {narrative!r})."
            )

    training_narratives: dict[Any, list[int]] = defaultdict(list)
    testing_narratives: dict[Any, list[int]] = defaultdict(list)
    for index, value in enumerate(training["Narrative"].tolist()):
        if not _is_blank(value, pd):
            try:
                training_narratives[value].append(index)
            except TypeError:
                continue
    for index, value in enumerate(testing["Narratives"].tolist()):
        if not _is_blank(value, pd):
            try:
                testing_narratives[value].append(index)
            except TypeError:
                continue
    for narrative, training_rows in training_narratives.items():
        testing_rows = testing_narratives.get(narrative)
        if testing_rows:
            warnings.append(
                "An exact narrative appears in both datasets: "
                f"Training Excel row(s) {_row_numbers(training_rows)}; "
                f"Testing Excel row(s) {_row_numbers(testing_rows)} "
                f"(original value: {narrative!r})."
            )

    corpus_combinations: dict[tuple[str, str], set[tuple[str, str]]] = defaultdict(set)
    raw_combinations: dict[tuple[Any, Any], list[int]] = defaultdict(list)
    normalized_combinations: dict[
        tuple[str, str], list[tuple[int, str, str]]
    ] = defaultdict(list)
    for index, row in corpus.iterrows():
        law = row["Law"]
        article = row["Article"]
        key = (_normalise_label(law, pd), _normalise_article(article, pd))
        if key[0] and key[1]:
            corpus_combinations[key].add((str(law), str(article)))
            normalized_combinations[key].append(
                (int(index), str(law), str(article))
            )
        try:
            raw_combinations[(law, article)].append(int(index))
        except TypeError:
            # Unhashable identifiers still participate in normalized matching.
            pass

    for (law, article), indices in raw_combinations.items():
        if len(indices) > 1:
            warnings.append(
                "Corpus contains a duplicate Law + Article combination in Excel "
                f"rows {_row_numbers(indices)} "
                f"(original values: Law={law!r}, Article={article!r}); "
                "all rows are retained."
            )

    for (law_key, article_key), entries in normalized_combinations.items():
        original_pairs = {(law, article) for _, law, article in entries}
        if len(original_pairs) > 1:
            indices = [index for index, _, _ in entries]
            originals = ", ".join(
                f"Law={law!r}, Article={article!r}"
                for law, article in sorted(original_pairs)
            )
            warnings.append(
                "Corpus contains a normalized duplicate Law + Article combination "
                f"in Excel rows {_row_numbers(indices)} "
                f"(original values: {originals}); all rows are retained."
            )

    for name, frame in (("Training", training), ("Testing", testing)):
        for index, row in frame.iterrows():
            law_value = row["Law"]
            article_value = row["Applicable Article"]
            if _is_blank(law_value, pd) or _is_blank(article_value, pd):
                continue

            law_key = _normalise_label(law_value, pd)
            article_references = _parse_article_references(article_value)
            row_number = int(index) + 2
            if article_references is None:
                warnings.append(
                    f"{name} Excel row {row_number}: could not confidently parse "
                    f"Applicable Article {_show(article_value, pd)} with original "
                    f"Law {_show(law_value, pd)}; manual review needed."
                )
                continue

            for reference in article_references:
                reference_key = (law_key, _normalise_article(reference, pd))
                matches = corpus_combinations.get(reference_key, set())
                if len(matches) > 1:
                    candidates = ", ".join(
                        f"Law={matched_law!r}, Article={matched_article!r}"
                        for matched_law, matched_article in sorted(matches)
                    )
                    warnings.append(
                        f"{name} Excel row {row_number}: article reference "
                        f"{reference!r} with original Law {_show(law_value, pd)} "
                        f"has multiple normalized corpus matches ({candidates}); "
                        "manual review needed."
                    )
                elif not matches:
                    warnings.append(
                        f"{name} Excel row {row_number}: article reference "
                        f"{reference!r} from original Applicable Article "
                        f"{_show(article_value, pd)} and Law "
                        f"{_show(law_value, pd)} has no normalized Law + Article "
                        "match in the corpus; manual review needed, not assumed invalid."
                    )

    print(f"\nActionable warnings: {len(warnings)}")
    if warnings:
        for warning in warnings:
            print(f"  - {warning}")
    else:
        print("  None found.")
    print(
        "\nThese checks assess structure and references only; they do not determine "
        "whether an article is legally relevant."
    )


if __name__ == "__main__":
    main()