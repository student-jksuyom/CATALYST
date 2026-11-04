
"""Temporary API for the CATALYST adviser demonstration."""

from pathlib import Path

import numpy as np
import pandas as pd
from flask import Flask, jsonify, request
from sentence_transformers import SentenceTransformer

MODEL_NAME = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
DIMENSIONS = 384

PROJECT_ROOT = Path(__file__).resolve().parent.parent
CORPUS_PATH = PROJECT_ROOT / "DATA" / "Corpus" / "MasterCorpus_Embedded.pkl"

app = Flask(__name__)


def load_resources():
    if not CORPUS_PATH.is_file():
        raise FileNotFoundError(f"Embedded corpus not found: {CORPUS_PATH}")

    corpus = pd.read_pickle(CORPUS_PATH)
    required = {"Law", "Article", "Article Text", "Embedding"}
    missing = required - set(corpus.columns)
    if missing:
        raise ValueError(f"Corpus missing columns: {sorted(missing)}")
    if corpus.empty:
        raise ValueError("Embedded corpus is empty.")

    vectors = np.stack([
        np.asarray(value, dtype=np.float32)
        for value in corpus["Embedding"]
    ])

    if vectors.shape != (len(corpus), DIMENSIONS):
        raise ValueError(f"Unexpected embedding matrix shape: {vectors.shape}")
    if not np.isfinite(vectors).all():
        raise ValueError("Corpus embeddings contain invalid values.")

    norms = np.linalg.norm(vectors, axis=1)
    if not np.allclose(norms, 1.0, atol=1e-3):
        raise ValueError("Corpus embeddings are not normalized.")

    print("Loading embedding model...")
    model = SentenceTransformer(MODEL_NAME)
    print(f"Loaded {len(corpus)} legal articles.")
    return corpus, vectors, model


corpus, corpus_vectors, model = load_resources()


@app.get("/health")
def health():
    return jsonify({"status": "ok", "articles": len(corpus)})


@app.post("/match")
def match():
    body = request.get_json(silent=True) or {}
    concern = body.get("concern")

    if not isinstance(concern, str) or not concern.strip():
        return jsonify({"error": "Please provide a legal concern."}), 400

    concern = concern.strip()
    if len(concern) > 5000:
        return jsonify({"error": "Concern is too long (maximum 5000 characters)."}), 400

    query_vector = model.encode(
        concern,
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    query_vector = np.asarray(query_vector, dtype=np.float32).reshape(-1)

    if query_vector.shape != (DIMENSIONS,) or not np.isfinite(query_vector).all():
        return jsonify({"error": "Could not encode the concern correctly."}), 500

    scores = corpus_vectors @ query_vector
    top_indices = np.argsort(-scores, kind="stable")[:3]

    results = []
    for rank, index in enumerate(top_indices, start=1):
        row = corpus.iloc[int(index)]
        results.append({
            "rank": rank,
            "law": str(row["Law"]),
            "article": str(row["Article"]),
            "title": str(row["Title"]) if "Title" in corpus.columns and pd.notna(row["Title"]) else "",
            "chapterTitle": str(row["Chapter Title"]) if "Chapter Title" in corpus.columns and pd.notna(row["Chapter Title"]) else "",
            "similarity": round(float(scores[index]), 4),
            "articleText": str(row["Article Text"]),
        })

    return jsonify({
        "concern": concern,
        "warning": "Similarity is a retrieval signal, not a probability or legal conclusion.",
        "results": results,
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
