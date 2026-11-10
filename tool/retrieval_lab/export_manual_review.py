"""Export per-model retrieval results into a manual relevance review workbook."""

from __future__ import annotations

import argparse
from collections import OrderedDict
from copy import copy
import json
from pathlib import Path
from typing import Any

from openpyxl import load_workbook
from openpyxl.styles import Alignment

try:
    from . import sbert_console
except ImportError:
    import sbert_console


HEADERS = (
    "Narrative-ID",
    "Sample Narrative",
    "Case Category",
    "Retrieval Model",
    "Rank",
    "Article-ID",
    "Cosine Score",
    "Article Text",
    "Relevance Label",
    "Reason",
)

BASE_MODEL_NAME = "Base MiniLM cosine"
FINE_TUNED_MODEL_NAME = "Fine-tuned SBERT cosine"
E5_MODEL_NAME = "Current CATALYST E5 hybrid (raw-query approximation)"
E5_MODEL_ALIASES = {
    "e5 hybrid (raw-query approximation)": E5_MODEL_NAME,
    "current catalyst e5 hybrid (raw-query approximation)": E5_MODEL_NAME,
}


def _normalized_model_name(value: Any) -> str:
    normalized = str(value or "").strip()
    return E5_MODEL_ALIASES.get(normalized.casefold(), normalized)


def _read_narratives(sheet: Any) -> list[dict[str, str]]:
    headers = [cell.value for cell in sheet[1]]
    missing = [header for header in HEADERS[:3] if header not in headers]
    if missing:
        raise ValueError(
            "The review workbook is missing required input columns: "
            + ", ".join(missing)
        )
    positions = {header: headers.index(header) + 1 for header in HEADERS[:3]}
    narratives: OrderedDict[str, dict[str, str]] = OrderedDict()
    for row_number in range(2, sheet.max_row + 1):
        narrative_id = sheet.cell(row_number, positions["Narrative-ID"]).value
        narrative = sheet.cell(row_number, positions["Sample Narrative"]).value
        category = sheet.cell(row_number, positions["Case Category"]).value
        if narrative_id is None and narrative is None and category is None:
            continue
        if not str(narrative_id or "").strip() or not str(narrative or "").strip():
            raise ValueError(
                f"Row {row_number} must have both Narrative-ID and Sample Narrative."
            )
        key = str(narrative_id).strip()
        item = {
            "narrative_id": key,
            "query": str(narrative).strip(),
            "case_category": str(category).strip() if category is not None else "",
        }
        existing = narratives.get(key)
        if existing is not None and existing != item:
            raise ValueError(
                f"Narrative-ID {key!r} has inconsistent narrative/category values."
            )
        narratives.setdefault(key, item)
    if not narratives:
        raise ValueError("The workbook contains no narrative rows to review.")
    return list(narratives.values())


def _existing_annotations(sheet: Any, headers: list[Any]) -> dict[tuple[str, str, str], tuple[Any, Any]]:
    positions = {header: headers.index(header) + 1 for header in HEADERS}
    annotations: dict[tuple[str, str, str], tuple[Any, Any]] = {}
    for row_number in range(2, sheet.max_row + 1):
        label = sheet.cell(row_number, positions["Relevance Label"]).value
        reason = sheet.cell(row_number, positions["Reason"]).value
        if label is None and reason is None:
            continue
        narrative_id = sheet.cell(row_number, positions["Narrative-ID"]).value
        model = _normalized_model_name(
            sheet.cell(row_number, positions["Retrieval Model"]).value
        )
        article_id = sheet.cell(row_number, positions["Article-ID"]).value
        if not narrative_id or not model or not article_id:
            raise ValueError(
                f"Row {row_number} has manual review data but no narrative, "
                "model, or article ID to preserve."
            )
        key = (str(narrative_id).strip(), model, str(article_id).strip().casefold())
        annotation = (label, reason)
        if key in annotations and annotations[key] != annotation:
            raise ValueError(
                f"Conflicting manual labels exist for narrative/model/article {key!r}."
            )
        annotations[key] = annotation
    return annotations


def _load_run(run_directory: Path | None) -> tuple[Path, dict[str, Any]]:
    if run_directory is None:
        runs = sorted(
            (
                path
                for path in sbert_console.OUTPUT_ROOT.iterdir()
                if path.is_dir() and (path / "evaluation_report.json").is_file()
            ),
            key=lambda path: path.stat().st_mtime,
        ) if sbert_console.OUTPUT_ROOT.is_dir() else []
        if not runs:
            raise FileNotFoundError(
                f"No completed fine-tuning run found under "
                f"{sbert_console.OUTPUT_ROOT}."
            )
        run_directory = runs[-1]
    report_path = run_directory / "evaluation_report.json"
    if not report_path.is_file():
        raise FileNotFoundError(f"Fine-tuning report not found: {report_path}")
    report = json.loads(report_path.read_text(encoding="utf-8"))
    candidate_path = Path(report["candidate_model_path"])
    if not candidate_path.is_dir():
        raise FileNotFoundError(f"Fine-tuned model not found: {candidate_path}")
    return run_directory, report


def _style_output_rows(sheet: Any, template_styles: list[Any], row_count: int) -> None:
    for row_number in range(2, row_count + 2):
        for column, style in enumerate(template_styles, start=1):
            cell = sheet.cell(row_number, column)
            if style is not None:
                cell._style = copy(style)
            if column in (2, 8, 10):
                cell.alignment = copy(cell.alignment)
                cell.alignment = Alignment(
                    horizontal=cell.alignment.horizontal,
                    vertical="top",
                    text_rotation=cell.alignment.text_rotation,
                    wrap_text=True,
                    shrink_to_fit=cell.alignment.shrink_to_fit,
                    indent=cell.alignment.indent,
                    relativeIndent=cell.alignment.relativeIndent,
                    justifyLastLine=cell.alignment.justifyLastLine,
                    readingOrder=cell.alignment.readingOrder,
                )


def export_review_workbook(
    input_path: Path,
    output_path: Path,
    run_directory: Path | None = None,
    top: int = 10,
) -> dict[str, Any]:
    if top < 1:
        raise ValueError("The number of results to export must be positive.")
    if not input_path.is_file():
        raise FileNotFoundError(f"Input workbook not found: {input_path}")
    if input_path.resolve() == output_path.resolve():
        raise ValueError("Output must be a separate file so the input is preserved.")
    output_path.parent.mkdir(parents=True, exist_ok=True)

    workbook = load_workbook(input_path)
    if not workbook.worksheets:
        raise ValueError("The review workbook has no worksheets.")
    sheet = workbook.active
    headers = [cell.value for cell in sheet[1]]
    if tuple(headers[: len(HEADERS)]) != HEADERS:
        raise ValueError(
            "The active worksheet must start with these columns in order: "
            + ", ".join(HEADERS)
        )

    narratives = _read_narratives(sheet)
    annotations = _existing_annotations(sheet, headers)
    template_styles = [
        copy(sheet.cell(2, column)._style) if sheet.max_row >= 2 else None
        for column in range(1, len(HEADERS) + 1)
    ]

    run_directory, training_report = _load_run(run_directory)
    from sentence_transformers import SentenceTransformer

    base_model_path = Path(
        training_report.get("base_model_path") or sbert_console._cached_model_path()
    )
    candidate_path = Path(training_report["candidate_model_path"])
    base_model = SentenceTransformer(str(base_model_path), device="cpu")
    candidate_model = SentenceTransformer(str(candidate_path), device="cpu")
    article_ids, article_texts = sbert_console._load_corpus()
    if len(article_ids) != int(training_report["corpus_articles"]):
        raise ValueError(
            "Current corpus size differs from the fine-tuned model report."
        )
    article_index = {article_id: index for index, article_id in enumerate(article_ids)}
    bundled_articles = json.loads(
        sbert_console.ARTICLES_PATH.read_text(encoding="utf-8")
    )
    fingerprint = sbert_console.hashlib.sha256(
        "\n".join(
            f"{article_id}\t{text}"
            for article_id, text in zip(article_ids, article_texts)
        ).encode("utf-8")
    ).hexdigest()[:16]
    base_vectors = sbert_console._prepare_sbert_vectors(
        base_model,
        article_texts,
        run_directory / f"console_base_corpus_{fingerprint}.npy",
    )
    candidate_vectors = sbert_console._prepare_sbert_vectors(
        candidate_model,
        article_texts,
        run_directory / f"console_candidate_corpus_{fingerprint}.npy",
    )
    e5 = sbert_console.ActiveE5Hybrid(article_ids, article_texts, bundled_articles)

    rows: list[list[Any]] = []
    model_counts = {BASE_MODEL_NAME: 0, FINE_TUNED_MODEL_NAME: 0, E5_MODEL_NAME: 0}
    for narrative in narratives:
        query = narrative["query"]
        base_ranking, base_scores = sbert_console._rank_sbert(
            base_model, query, base_vectors
        )
        candidate_ranking, candidate_scores = sbert_console._rank_sbert(
            candidate_model, query, candidate_vectors
        )
        e5_ranking, e5_scores = e5.rank(query)
        systems = (
            (BASE_MODEL_NAME, base_ranking[:top], base_scores),
            (FINE_TUNED_MODEL_NAME, candidate_ranking[:top], candidate_scores),
            (E5_MODEL_NAME, e5_ranking[:top], e5_scores),
        )
        for model_name, ranking, scores in systems:
            for rank, article_position in enumerate(ranking, start=1):
                article_id = article_ids[article_position]
                annotation_key = (
                    narrative["narrative_id"],
                    model_name,
                    article_id.casefold(),
                )
                label, reason = annotations.get(annotation_key, (None, None))
                article = bundled_articles[article_position]
                rows.append(
                    [
                        narrative["narrative_id"],
                        query,
                        narrative["case_category"],
                        model_name,
                        rank,
                        article_id,
                        float(scores[article_position]),
                        str(article["Article Text"]),
                        label,
                        reason,
                    ]
                )
                model_counts[model_name] += 1

    if sheet.max_row > 1:
        sheet.delete_rows(2, sheet.max_row - 1)
    _style_output_rows(sheet, template_styles, len(rows))
    for row_number, values in enumerate(rows, start=2):
        for column, value in enumerate(values, start=1):
            sheet.cell(row_number, column).value = value
    sheet.auto_filter.ref = f"A1:J{len(rows) + 1}"
    sheet.freeze_panes = "A2"

    for table in sheet.tables.values():
        table.ref = f"A1:J{len(rows) + 1}"
    workbook.save(output_path)
    workbook.close()
    return {
        "narrative_count": len(narratives),
        "row_count": len(rows),
        "model_counts": model_counts,
        "preserved_annotations": len(annotations),
        "output_path": output_path,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="Narrative review workbook.")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output workbook (defaults to INPUT-Completed.xlsx).",
    )
    parser.add_argument(
        "--run",
        type=Path,
        default=None,
        help="Fine-tuning run directory (defaults to latest completed run).",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Maximum results per model and narrative (default: 10).",
    )
    args = parser.parse_args()
    output_path = args.output or args.input.with_name(
        f"{args.input.stem}-Completed{args.input.suffix}"
    )
    try:
        summary = export_review_workbook(args.input, output_path, args.run, args.top)
    except (FileNotFoundError, ValueError, KeyError) as exc:
        raise SystemExit(str(exc)) from exc
    print(f"Review workbook saved: {summary['output_path']}")
    print(f"Narratives: {summary['narrative_count']}")
    print(f"Review rows: {summary['row_count']}")
    for model_name, count in summary["model_counts"].items():
        print(f"  {model_name}: {count}")
    print(f"Preserved existing manual annotations: {summary['preserved_annotations']}")


if __name__ == "__main__":
    main()
