"""Export the embedded legal corpus into compact, mobile-readable assets."""

from __future__ import annotations

import json
from pathlib import Path
import tempfile
from typing import Any

import numpy as np
import pandas as pd


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SOURCE_PATH = PROJECT_ROOT / "DATA" / "Corpus" / "MasterCorpus_Embedded.pkl"
OUTPUT_DIRECTORY = PROJECT_ROOT / "assets" / "data"
DIMENSIONS = 384
REQUIRED_COLUMNS = ("Law", "Article", "Article Text", "Embedding")
METADATA_COLUMNS = ("Law", "Article", "Title", "Chapter Title", "Article Text")


def _text(value: Any) -> str:
    if pd.isna(value):
        return ""
    return str(value)


def main() -> None:
    corpus = pd.read_pickle(SOURCE_PATH)
    missing = [column for column in REQUIRED_COLUMNS if column not in corpus]
    if missing:
        raise ValueError(f"Embedded corpus is missing columns: {missing}")
    if corpus.empty:
        raise ValueError("Embedded corpus is empty.")

    vectors = np.stack(
        [np.asarray(value, dtype=np.float32) for value in corpus["Embedding"]]
    )
    if vectors.shape != (len(corpus), DIMENSIONS):
        raise ValueError(f"Unexpected embedding matrix shape: {vectors.shape}")
    if not np.isfinite(vectors).all():
        raise ValueError("Corpus embeddings contain NaN or infinite values.")
    norms = np.linalg.norm(vectors, axis=1)
    if not np.allclose(norms, 1.0, atol=1e-3):
        raise ValueError("Corpus embeddings are not unit-normalized.")

    metadata = [
        {column: _text(row[column]) if column in corpus else "" for column in METADATA_COLUMNS}
        for _, row in corpus.iterrows()
    ]
    OUTPUT_DIRECTORY.mkdir(parents=True, exist_ok=True)
    destinations = (
        OUTPUT_DIRECTORY / "legal_articles.json",
        OUTPUT_DIRECTORY / "article_embeddings.f32",
    )
    temporary_paths: list[Path] = []
    try:
        for destination in destinations:
            with tempfile.NamedTemporaryFile(
                dir=OUTPUT_DIRECTORY,
                prefix=f".{destination.stem}_",
                suffix=destination.suffix,
                delete=False,
            ) as temporary:
                temporary_paths.append(Path(temporary.name))

        temporary_paths[0].write_text(
            json.dumps(metadata, ensure_ascii=False, separators=(",", ":")),
            encoding="utf-8",
        )
        temporary_paths[1].write_bytes(
            np.asarray(vectors, dtype="<f4").tobytes(order="C")
        )
        for temporary_path, destination in zip(temporary_paths, destinations):
            temporary_path.replace(destination)
    finally:
        for temporary_path in temporary_paths:
            if temporary_path.exists():
                temporary_path.unlink()

    print(f"Articles: {len(corpus)}")
    print(f"Embeddings: {vectors.shape[0]} x {vectors.shape[1]} float32")
    for destination in destinations:
        print(f"{destination}: {destination.stat().st_size:,} bytes")


if __name__ == "__main__":
    main()
