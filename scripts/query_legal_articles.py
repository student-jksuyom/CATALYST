"""Find legal articles most similar to a user's concern."""

from __future__ import annotations

from pathlib import Path
from typing import Any


MODEL_NAME = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
EMBEDDING_DIMENSIONS = 384
REQUIRED_COLUMNS = (
    "Law",
    "Article",
    "Article Text",
    "Embedding Text",
    "Embedding",
)


def _display_value(value: Any, pandas: Any) -> str | None:
    """Return a nonblank display value, or None for an absent heading value."""
    if pandas.isna(value):
        return None
    text = str(value)
    return text if text.strip() else None


def main() -> None:
    """Load the embedded corpus and show the three closest legal articles."""
    try:
        import numpy as np
        import pandas as pd
        from sentence_transformers import SentenceTransformer
    except ImportError as exc:
        missing_package = exc.name or "a required package"
        raise SystemExit(
            f"Missing Python dependency: {missing_package}. Install pandas, numpy, "
            "and sentence-transformers in this environment, then try again."
        ) from exc

    project_root = Path(__file__).resolve().parent.parent
    corpus_path = project_root / "DATA" / "Corpus" / "MasterCorpus_Embedded.pkl"
    if not corpus_path.is_file():
        raise SystemExit(f"Embedded corpus file not found: {corpus_path}")

    try:
        corpus = pd.read_pickle(corpus_path)
    except Exception as exc:
        raise SystemExit(f"Could not read the embedded corpus pickle: {exc}") from exc

    if not isinstance(corpus, pd.DataFrame):
        raise SystemExit("Invalid corpus: the pickle does not contain a pandas DataFrame.")

    missing_columns = [
        column for column in REQUIRED_COLUMNS if column not in corpus.columns
    ]
    if missing_columns:
        raise SystemExit(
            "Embedded corpus is missing required column(s): "
            + ", ".join(missing_columns)
        )
    if corpus.empty:
        raise SystemExit("The embedded corpus contains no legal articles.")

    corpus_vectors = []
    for row_number, value in enumerate(corpus["Embedding"], start=1):
        try:
            vector = np.asarray(value)
        except (TypeError, ValueError) as exc:
            raise SystemExit(
                f"Invalid embedding at corpus row {row_number}: it is not a valid vector."
            ) from exc

        if vector.shape != (EMBEDDING_DIMENSIONS,):
            raise SystemExit(
                f"Invalid embedding at corpus row {row_number}: expected "
                f"{EMBEDDING_DIMENSIONS} dimensions, got {vector.shape}."
            )
        if not np.issubdtype(vector.dtype, np.number):
            raise SystemExit(
                f"Invalid embedding at corpus row {row_number}: values must be numeric."
            )
        if not np.isfinite(vector).all():
            raise SystemExit(
                f"Invalid embedding at corpus row {row_number}: it contains "
                "NaN or infinite values."
            )
        corpus_vectors.append(vector)

    try:
        corpus_matrix = np.stack(corpus_vectors)
    except (TypeError, ValueError) as exc:
        raise SystemExit(f"Could not assemble the corpus embeddings: {exc}") from exc

    corpus_norms = np.linalg.norm(corpus_matrix, axis=1)
    unnormalized_rows = np.flatnonzero(~np.isclose(corpus_norms, 1.0, atol=1e-3))
    if unnormalized_rows.size:
        row_index = int(unnormalized_rows[0])
        raise SystemExit(
            f"Invalid embedding at corpus row {row_index + 1}: expected a "
            f"unit-normalized vector (Euclidean norm approximately 1), got "
            f"{corpus_norms[row_index]:.6f}."
        )

    try:
        concern = input("Enter your legal concern (English, Filipino, or Taglish): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nNo concern was entered.")
        return
    if not concern:
        print("Concern cannot be empty. Please run the script again and enter a concern.")
        return

    print(f"Loading embedding model: {MODEL_NAME}")
    try:
        model = SentenceTransformer(MODEL_NAME)
    except Exception as exc:
        raise SystemExit(f"Could not load the sentence embedding model: {exc}") from exc

    try:
        query_vector = np.asarray(
            model.encode(
                concern,
                normalize_embeddings=True,
                convert_to_numpy=True,
            )
        )
    except Exception as exc:
        raise SystemExit(f"Could not encode the concern: {exc}") from exc

    if query_vector.shape == (1, EMBEDDING_DIMENSIONS):
        query_vector = query_vector[0]
    if query_vector.shape != (EMBEDDING_DIMENSIONS,):
        raise SystemExit(
            f"Invalid query embedding: expected {EMBEDDING_DIMENSIONS} dimensions, "
            f"got {query_vector.shape}."
        )
    if not np.issubdtype(query_vector.dtype, np.number):
        raise SystemExit("Invalid query embedding: values must be numeric.")
    if not np.isfinite(query_vector).all():
        raise SystemExit("Invalid query embedding: it contains NaN or infinite values.")

    scores = corpus_matrix @ query_vector
    top_indices = np.argsort(-scores, kind="stable")[: min(3, len(corpus))]

    print("\nMost similar legal articles")
    print("Similarity is a retrieval signal; it does not establish that a law applies.")
    for rank, row_index in enumerate(top_indices, start=1):
        article = corpus.iloc[int(row_index)]
        print(f"\nRank: {rank}")
        print(f"Law: {article['Law']}")
        print(f"Article: {article['Article']}")
        for heading in ("Title", "Chapter Title"):
            if heading in corpus.columns:
                value = _display_value(article[heading], pd)
                if value is not None:
                    print(f"{heading}: {value}")
        print(f"Cosine similarity (not a probability): {scores[row_index]:.4f}")
        print("Article Text:")
        print(article["Article Text"])
        print("-" * 72)


if __name__ == "__main__":
    main()
