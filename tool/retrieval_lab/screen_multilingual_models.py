"""Screen multilingual encoders on the development evaluation set only."""

from __future__ import annotations

import gc
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np
from openpyxl import load_workbook


ROOT = Path(__file__).resolve().parents[2]
ARTICLES_PATH = ROOT / "assets" / "data" / "legal_articles.json"
EVALUATION_PATH = ROOT / "DATA" / "Datasets" / "Evaluationdataset.xlsx"
OUTPUT_ROOT = ROOT / "tool" / "retrieval_lab" / "out" / "model_screening"
WORD_LIMIT = 75
WINDOW_WORDS = 60
WINDOW_STRIDE = 40
MAX_CHUNKS_PER_ARTICLE = 12
MODEL_SPECS = (
    ("intfloat/multilingual-e5-small", "e5"),
    ("intfloat/multilingual-e5-base", "e5"),
    ("BAAI/bge-m3", "bge"),
)


def _article_id(law: str, number: str) -> str:
    normalized_law = re.sub(r"[^a-z0-9]", "", law.casefold())
    normalized_number = re.sub(r"\s+", "", number).casefold()
    return f"{normalized_law}:{normalized_number}"


def _current_word_chunks(text: str) -> list[str]:
    words = text.split()
    if len(words) <= WORD_LIMIT:
        return [" ".join(words)]
    chunks = []
    for start in range(0, min(len(words), WINDOW_STRIDE * MAX_CHUNKS_PER_ARTICLE), WINDOW_STRIDE):
        chunks.append(" ".join(words[start : start + WINDOW_WORDS]))
        if start + WINDOW_WORDS >= len(words):
            break
    return chunks


def _load_evaluation_groups(
    article_ids: set[str],
) -> list[dict[str, Any]]:
    workbook = load_workbook(EVALUATION_PATH, read_only=True, data_only=True)
    groups: dict[str, dict[str, Any]] = {}
    try:
        rows = iter(workbook.active.values)
        try:
            headers = next(rows)
        except StopIteration:
            raise ValueError(f"Evaluation workbook is empty: {EVALUATION_PATH}") from None
        columns = {
            str(name).strip(): index
            for index, name in enumerate(headers)
            if name is not None
        }
        required = ("Sample Narrative", "Applicable_Article_ID", "Relevance_Label")
        missing = [name for name in required if name not in columns]
        if missing:
            raise ValueError(f"Evaluation workbook is missing columns: {missing}")

        for row_number, row in enumerate(rows, start=2):
            query_value = row[columns["Sample Narrative"]]
            if not isinstance(query_value, str) or not query_value.strip():
                raise ValueError(f"Evaluation row {row_number} has no narrative.")
            query = query_value.strip()
            label = row[columns["Relevance_Label"]]
            if label not in (0, 1, 0.0, 1.0):
                raise ValueError(f"Evaluation row {row_number} has invalid label {label!r}.")
            raw_ids = row[columns["Applicable_Article_ID"]]
            if not isinstance(raw_ids, str) or not raw_ids.strip():
                raise ValueError(f"Evaluation row {row_number} has no article IDs.")
            group = groups.setdefault(
                query.casefold(),
                {"query": query, "relevant": set(), "labeled": set()},
            )
            for raw_id in raw_ids.split(","):
                article_id = raw_id.strip().casefold()
                if article_id not in article_ids:
                    raise ValueError(
                        f"Evaluation row {row_number} references unknown article "
                        f"{article_id!r}."
                    )
                group["labeled"].add(article_id)
                if int(label) == 1:
                    group["relevant"].add(article_id)
    finally:
        workbook.close()
    return list(groups.values())


def _encode(
    model_id: str,
    model_kind: str,
    texts: list[str],
    *,
    role: str,
    device: str,
) -> np.ndarray:
    import torch
    from transformers import AutoModel, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_id)
    model = AutoModel.from_pretrained(model_id).to(device)
    model.eval()
    max_length = min(512, int(getattr(tokenizer, "model_max_length", 512)))
    vectors = np.empty((len(texts), int(model.config.hidden_size)), dtype=np.float32)
    batch_size = 8 if model_id == "BAAI/bge-m3" else 16

    with torch.inference_mode():
        for start in range(0, len(texts), batch_size):
            batch = texts[start : start + batch_size]
            if model_kind == "e5":
                prefix = "query: " if role == "query" else "passage: "
                batch = [prefix + text for text in batch]
            encoded = tokenizer(
                batch,
                padding=True,
                truncation=True,
                max_length=max_length,
                return_tensors="pt",
            )
            encoded = {name: value.to(device) for name, value in encoded.items()}
            hidden = model(**encoded).last_hidden_state
            if model_kind == "e5":
                mask = encoded["attention_mask"].unsqueeze(-1).to(hidden.dtype)
                pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1).clamp(min=1)
            else:
                pooled = hidden[:, 0]
            pooled = torch.nn.functional.normalize(pooled, p=2, dim=1)
            vectors[start : start + len(batch)] = pooled.cpu().numpy()
            if start == 0 or start + batch_size >= len(texts):
                print(f"  encoded {min(start + batch_size, len(texts))}/{len(texts)}")

    del model, tokenizer
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
    return vectors


def _evaluate(
    query_vectors: np.ndarray,
    chunk_vectors: np.ndarray,
    owners: np.ndarray,
    groups: list[dict[str, Any]],
    article_ids: list[str],
) -> dict[str, Any]:
    unique_article_ids = list(dict.fromkeys(article_ids))
    unique_positions = {
        article_id: index for index, article_id in enumerate(unique_article_ids)
    }
    article_to_unique = np.asarray(
        [unique_positions[article_id] for article_id in article_ids],
        dtype=np.int32,
    )
    positive = [group for group in groups if group["relevant"]]
    metrics = {"top1": 0, "hit3": 0, "hit15": 0}
    reciprocal_rank_sum = 0.0
    per_case = []

    for query_vector, group in zip(query_vectors, groups):
        chunk_scores = chunk_vectors @ query_vector
        article_scores = np.full(len(article_ids), -np.inf, dtype=np.float32)
        np.maximum.at(article_scores, owners, chunk_scores)
        unique_scores = np.full(len(unique_article_ids), -np.inf, dtype=np.float32)
        np.maximum.at(unique_scores, article_to_unique, article_scores)
        ranking = np.argsort(-unique_scores, kind="stable")
        ranked_ids = [unique_article_ids[index] for index in ranking]
        relevant = group["relevant"]
        first_rank = next(
            (rank for rank, article_id in enumerate(ranked_ids, start=1) if article_id in relevant),
            None,
        )
        if relevant:
            metrics["top1"] += first_rank == 1
            metrics["hit3"] += first_rank is not None and first_rank <= 3
            metrics["hit15"] += first_rank is not None and first_rank <= 15
            reciprocal_rank_sum += (
                1 / first_rank if first_rank is not None and first_rank <= 15 else 0
            )
        per_case.append(
            {
                "query": group["query"],
                "relevantArticleIds": sorted(relevant),
                "firstRelevantRank": first_rank,
                "top3": ranked_ids[:3],
            }
        )

    count = len(positive)
    return {
        "positiveQueryGroups": count,
        "top1": metrics["top1"],
        "hit3": metrics["hit3"],
        "hit15": metrics["hit15"],
        "mrr15": reciprocal_rank_sum / count if count else 0,
        "cases": per_case,
    }


def main() -> None:
    articles = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))
    article_ids = [_article_id(article["Law"], article["Article"]) for article in articles]
    groups = _load_evaluation_groups(set(article_ids))
    if not any(group["relevant"] for group in groups):
        raise ValueError("The evaluation set contains no positive query groups.")

    chunk_texts: list[str] = []
    owners: list[int] = []
    for article_index, article in enumerate(articles):
        chunks = _current_word_chunks(article["Article Text"])
        chunk_texts.extend(chunks)
        owners.extend([article_index] * len(chunks))
    owner_array = np.asarray(owners, dtype=np.int32)
    query_texts = [group["query"] for group in groups]
    device = "cuda" if __import__("torch").cuda.is_available() else "cpu"

    report: dict[str, Any] = {
        "createdAt": datetime.now().astimezone().isoformat(),
        "dataset": "DATA/Datasets/Evaluationdataset.xlsx",
        "datasetStatus": "development-only; labels are not independent legal ground truth",
        "heldoutUsed": False,
        "method": (
            "Dense encoder screening only: same current article word chunks, "
            "best chunk cosine per article, original query wording, no BM25, "
            "training-query vote, or abstention. E5 uses query:/passage: prefixes; "
            "BGE-M3 uses normalized CLS vectors."
        ),
        "device": device,
        "articleCount": len(articles),
        "distinctArticleIds": len(set(article_ids)),
        "chunkCount": len(chunk_texts),
        "queryGroupCount": len(groups),
        "positiveQueryGroupCount": sum(bool(group["relevant"]) for group in groups),
        "models": {},
    }

    for model_id, model_kind in MODEL_SPECS:
        print(f"Loading {model_id} on {device}")
        chunk_vectors = _encode(
            model_id, model_kind, chunk_texts, role="passage", device=device
        )
        query_vectors = _encode(
            model_id, model_kind, query_texts, role="query", device=device
        )
        report["models"][model_id] = _evaluate(
            query_vectors, chunk_vectors, owner_array, groups, article_ids
        )
        print(
            f"  Hit@1={report['models'][model_id]['top1']}/"
            f"{report['models'][model_id]['positiveQueryGroups']}, "
            f"Hit@3={report['models'][model_id]['hit3']}/"
            f"{report['models'][model_id]['positiveQueryGroups']}, "
            f"Hit@15={report['models'][model_id]['hit15']}/"
            f"{report['models'][model_id]['positiveQueryGroups']}"
        )
        del chunk_vectors, query_vectors
        gc.collect()

    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_ROOT / f"{datetime.now():%Y%m%d_%H%M%S}_report.json"
    output_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Saved screening report: {output_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
