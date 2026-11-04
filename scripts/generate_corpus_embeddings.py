"""Generate multilingual sentence embeddings for the legal corpus."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
from typing import Any


MODEL_NAME = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBEDDING_DIMENSIONS = 384
BATCH_SIZE = 32

# These columns identify and provide the text of each legal provision.
REQUIRED_COLUMNS = ("Law", "Article", "Article Text")

# Headings add useful context when available, but are not present in every corpus.
OPTIONAL_METADATA_COLUMNS = ("Book", "Title", "Chapter", "Chapter Title")


def _is_missing_or_blank(value: Any, pandas: Any) -> bool:
    """Return whether a spreadsheet cell is empty or contains only whitespace."""
    if pandas.isna(value):
        return True
    return isinstance(value, str) and not value.strip()


def _format_cell(value: Any, pandas: Any) -> str | None:
    """Convert a populated metadata cell to readable text, omitting empty cells."""
    if _is_missing_or_blank(value, pandas):
        return None
    return str(value).strip()


def _build_embedding_text(row: Any, pandas: Any, metadata_columns: list[str]) -> str:
    """Build labeled context without changing the source statutory text."""
    fields = [
        f"Law: {str(row['Law']).strip()}",
        f"Article: {str(row['Article']).strip()}",
    ]
    for column in metadata_columns:
        value = _format_cell(row[column], pandas)
        if value is not None:
            fields.append(f"{column}: {value}")

    fields.append(f"Legal provision:\n{str(row['Article Text'])}")
    return "\n".join(fields)


def main() -> None:
    """Validate the source workbook, generate embeddings, and save both outputs."""
    try:
        import numpy as np
        import pandas as pd
        from sentence_transformers import SentenceTransformer
    except ImportError as exc:
        missing_package = exc.name or "a required package"
        raise SystemExit(
            f"Missing Python dependency: {missing_package}. Install pandas, numpy, "
            "and sentence-transformers in this environment, then run this script again."
        ) from exc

    # Resolve paths from this script so it works regardless of the terminal directory.
    project_root = Path(__file__).resolve().parent.parent
    corpus_directory = project_root / "DATA" / "Corpus"
    source_path = corpus_directory / "MasterCorpus.xlsx"
    pickle_path = corpus_directory / "MasterCorpus_Embedded.pkl"
    excel_path = corpus_directory / "MasterCorpus_Embedded.xlsx"

    if not source_path.is_file():
        raise SystemExit(f"Source corpus not found: {source_path}")

    try:
        source = pd.read_excel(source_path)
    except (OSError, ValueError, ImportError) as exc:
        raise SystemExit(f"Could not read the source Excel workbook: {exc}") from exc

    missing_columns = [column for column in REQUIRED_COLUMNS if column not in source.columns]
    if missing_columns:
        available = ", ".join(str(column) for column in source.columns) or "(none)"
        raise SystemExit(
            "The source workbook is missing required column(s): "
            f"{', '.join(missing_columns)}. Columns found: {available}"
        )

    print(f"Source rows: {len(source)}")
    print("Rows by law:")
    law_counts = source["Law"].value_counts(dropna=False)
    for law, count in law_counts.items():
        law_label = "<missing>" if pd.isna(law) else str(law)
        print(f"  {law_label}: {count}")

    optional_columns = [
        column for column in OPTIONAL_METADATA_COLUMNS if column in source.columns
    ]
    missing_optional_columns = [
        column for column in OPTIONAL_METADATA_COLUMNS if column not in source.columns
    ]
    if missing_optional_columns:
        print(
            "Optional metadata heading(s) not found (they will be skipped): "
            + ", ".join(missing_optional_columns)
        )

    if source.empty:
        raise SystemExit("The source workbook contains no article rows to embed.")

    missing_cells: list[str] = []
    for column in REQUIRED_COLUMNS:
        empty_rows = [
            str(index + 2)
            for index, value in enumerate(source[column].tolist())
            if _is_missing_or_blank(value, pd)
        ]
        if empty_rows:
            preview = ", ".join(empty_rows[:10])
            remaining = len(empty_rows) - 10
            suffix = f", and {remaining} more" if remaining > 0 else ""
            missing_cells.append(
                f"{column} is missing or blank in Excel row(s) {preview}{suffix}"
            )
    if missing_cells:
        raise SystemExit(
            "The source workbook has incomplete required values:\n  "
            + "\n  ".join(missing_cells)
        )

    duplicate_counts = (
        source.groupby(["Law", "Article"], dropna=False, sort=False)
        .size()
        .loc[lambda counts: counts > 1]
    )
    if not duplicate_counts.empty:
        print("Duplicate Law + Article combinations (kept as separate rows):")
        for (law, article), count in duplicate_counts.items():
            print(f"  Law={law!s}, Article={article!s}: {count} rows")
    else:
        print("Duplicate Law + Article combinations: none")

    embedded = source.copy()
    embedding_texts = [
        _build_embedding_text(row, pd, optional_columns)
        for _, row in source.iterrows()
    ]
    embedded["Embedding Text"] = embedding_texts

    print(f"Loading embedding model: {MODEL_NAME}")
    model = SentenceTransformer(MODEL_NAME)

    default_max_seq_length = model.max_seq_length
    print(f"Model default max_seq_length: {default_max_seq_length}")

    try:
        underlying_max_position_length = (
            model[0].auto_model.config.max_position_embeddings
        )
    except (AttributeError, IndexError, KeyError, TypeError) as exc:
        raise SystemExit(
            "Could not verify the embedding model's underlying maximum position "
            "length; refusing to change max_seq_length."
        ) from exc

    print(
        "Model underlying maximum position length: "
        f"{underlying_max_position_length}"
    )
    if underlying_max_position_length >= 512:
        model.max_seq_length = 512
    else:
        print(
            f"Warning: this model supports at most {underlying_max_position_length} "
            "positions, so max_seq_length will remain at "
            f"{default_max_seq_length}."
        )

    token_limit = model.max_seq_length
    long_input_count = 0
    for start in range(0, len(embedding_texts), BATCH_SIZE):
        tokenized_batch = model.tokenizer(
            embedding_texts[start : start + BATCH_SIZE],
            add_special_tokens=True,
            padding=False,
            truncation=False,
        )
        long_input_count += sum(
            len(token_ids) > token_limit for token_ids in tokenized_batch["input_ids"]
        )

    print(
        f"Embedding inputs longer than the configured {token_limit}-token limit: "
        f"{long_input_count}/{len(embedding_texts)}"
    )
    if long_input_count:
        print(
            "Warning: model encoding will truncate tokens beyond the configured "
            "limit; not all source text will be represented in those embeddings."
        )

    embedding_batches = []
    total_rows = len(embedding_texts)
    for start in range(0, total_rows, BATCH_SIZE):
        end = min(start + BATCH_SIZE, total_rows)
        batch = model.encode(
            embedding_texts[start:end],
            batch_size=BATCH_SIZE,
            show_progress_bar=False,
            normalize_embeddings=True,
            convert_to_numpy=True,
        )
        embedding_batches.append(np.asarray(batch, dtype=np.float32))
        percentage = end * 100 / total_rows
        ending = "\n" if end == total_rows else "\r"
        print(
            f"Encoding articles: {end}/{total_rows} ({percentage:.1f}%)",
            end=ending,
            flush=True,
        )

    embedding_matrix = np.concatenate(embedding_batches, axis=0)
    if embedding_matrix.shape[0] != len(source):
        raise SystemExit(
            f"Embedding count mismatch: generated {embedding_matrix.shape[0]} "
            f"vectors for {len(source)} source rows."
        )
    if embedding_matrix.ndim != 2 or embedding_matrix.shape[1] != EMBEDDING_DIMENSIONS:
        actual_dimensions = (
            embedding_matrix.shape[1] if embedding_matrix.ndim == 2 else "unknown"
        )
        raise SystemExit(
            f"Unexpected embedding dimensions: expected {EMBEDDING_DIMENSIONS}, "
            f"received {actual_dimensions}."
        )
    if not np.isfinite(embedding_matrix).all():
        raise SystemExit("Generated embeddings contain NaN or infinite values.")

    vectors = [
        np.asarray(vector, dtype=np.float32).copy() for vector in embedding_matrix
    ]
    embedded["Embedding"] = vectors

    if not embedded.loc[:, source.columns].equals(source):
        raise SystemExit(
            "Validation failed: original columns, article text, or source row order "
            "changed while constructing the output."
        )
    if len(vectors) != len(source):
        raise SystemExit(
            f"Embedding count mismatch: generated {len(vectors)} vectors "
            f"for {len(source)} source rows."
        )
    if any(vector.shape != (EMBEDDING_DIMENSIONS,) for vector in vectors):
        raise SystemExit(
            f"Validation failed: every embedding must have {EMBEDDING_DIMENSIONS} "
            "dimensions."
        )
    if not all(np.isfinite(vector).all() for vector in vectors):
        raise SystemExit("Validation failed: an embedding contains NaN or infinity.")

    corpus_directory.mkdir(parents=True, exist_ok=True)
    temporary_paths: list[Path] = []
    try:
        with tempfile.NamedTemporaryFile(
            dir=corpus_directory, prefix=".MasterCorpus_Embedded_", suffix=".pkl",
            delete=False,
        ) as temporary_pickle:
            temporary_pickle_path = Path(temporary_pickle.name)
        temporary_paths.append(temporary_pickle_path)

        with tempfile.NamedTemporaryFile(
            dir=corpus_directory, prefix=".MasterCorpus_Embedded_", suffix=".xlsx",
            delete=False,
        ) as temporary_excel:
            temporary_excel_path = Path(temporary_excel.name)
        temporary_paths.append(temporary_excel_path)

        # Keep numeric float32 vectors in pickle; JSON lists make Excel readable.
        embedded.to_pickle(temporary_pickle_path)
        excel_copy = embedded.copy()
        excel_copy["Embedding"] = [
            json.dumps(vector.tolist(), allow_nan=False) for vector in vectors
        ]
        excel_copy.to_excel(temporary_excel_path, index=False)

        temporary_pickle_path.replace(pickle_path)
        temporary_excel_path.replace(excel_path)
    except (OSError, ValueError, ImportError) as exc:
        raise SystemExit(
            f"Could not write both embedding outputs: {exc}. "
            "The source corpus was not modified."
        ) from exc
    finally:
        for temporary_path in temporary_paths:
            if temporary_path.exists():
                temporary_path.unlink()

    print("\nEmbedding generation complete.")
    print(f"Rows processed: {len(source)}")
    print(f"Vector dimensions: {EMBEDDING_DIMENSIONS}; dtype: float32")
    print("Validation: all vectors are finite; original article text and row order retained.")
    print(f"Pickle output: {pickle_path}")
    print(f"Excel output: {excel_path}")


if __name__ == "__main__":
    main()