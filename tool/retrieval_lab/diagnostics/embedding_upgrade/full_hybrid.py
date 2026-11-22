"""Reproduce the full E5 hybrid and test small BGE-M3 fusion alternatives."""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
import time
from pathlib import Path

import numpy as np
import torch
from huggingface_hub import snapshot_download
from transformers import AutoModel, AutoTokenizer

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tool" / "retrieval_lab"))
import export_training_query_index as training_export  # noqa: E402
from compare import (  # noqa: E402
    BM25_WEIGHT,
    POOL,
    RRF_K,
    digest,
    encode_batch,
    evaluate,
    peak_memory,
)

BGE_DIMENSIONS = 1024
E5_DIMENSIONS = 384
TRAIN_MINIMUM = 0.90
MAX_NEIGHBORS = 3
BGE_GATE = 0.48635439736938474
FINGERPRINT = re.compile(r"[^a-z0-9]+")


def normalize(text: str) -> str:
    return FINGERPRINT.sub("", text.casefold())


def load_training(article_ids: list[str]) -> list[dict]:
    indexes = {FINGERPRINT.sub("", article_id.casefold()): i for i, article_id in enumerate(article_ids)}
    examples = training_export._load_training_examples(indexes)
    if len(examples) != 182:
        raise ValueError(f"Expected 182 training queries, got {len(examples)}.")
    return examples


def bge_training_vectors(
    examples: list[dict], directory: Path, *, int8: bool
) -> tuple[np.ndarray, dict]:
    vector_path = directory / "training_queries.npy"
    meta_path = directory / "training_metadata.json"
    texts = [example["query"] for example in examples]
    revision = Path(
        snapshot_download("BAAI/bge-m3", local_files_only=True)
    ).name
    signature = digest(
        {
            "model": "BAAI/bge-m3",
            "revision": revision,
            "queries": texts,
            "quantization": "dynamic-int8" if int8 else "fp32",
        }
    )
    if vector_path.exists() and meta_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        vectors = np.load(vector_path, allow_pickle=False)
        if (
            meta.get("signature") == signature
            and vectors.shape == (len(examples), BGE_DIMENSIONS)
            and np.isfinite(vectors).all()
            and np.allclose(np.linalg.norm(vectors, axis=1), 1, atol=1e-4)
        ):
            return vectors, meta
    snapshot = Path(snapshot_download("BAAI/bge-m3", local_files_only=True))
    tokenizer = AutoTokenizer.from_pretrained(snapshot, local_files_only=True)
    model = AutoModel.from_pretrained(snapshot, local_files_only=True).eval()
    if int8:
        model = torch.ao.quantization.quantize_dynamic(
            model, {torch.nn.Linear}, dtype=torch.qint8
        )
    vectors = np.empty((len(texts), BGE_DIMENSIONS), dtype=np.float32)
    started = time.perf_counter()
    for offset in range(0, len(texts), 8):
        vectors[offset : offset + 8] = encode_batch(
            model, tokenizer, texts[offset : offset + 8], False
        )
    meta = {
        "signature": signature,
        "model": "BAAI/bge-m3",
        "revision": revision,
        "count": len(texts),
        "encodingSeconds": time.perf_counter() - started,
        "peakRssBytes": peak_memory(),
    }
    np.save(vector_path, vectors, allow_pickle=False)
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return vectors, meta


def query_domain(query: str, analysis: dict) -> str:
    source = (ROOT / "lib" / "services" / "query_analysis.dart").read_text(
        encoding="utf-8"
    )
    from screen_bge_hybrid import _dart_set, _query_domain
    from segmentation_experiment import QueryAnalyzer

    return _query_domain(
        query,
        QueryAnalyzer(),
        _dart_set(source, "familyCues"),
        _dart_set(source, "consumerCues"),
        _dart_set(source, "civilCues"),
    )


def training_vote(
    vector: np.ndarray,
    examples: list[dict],
    training_vectors: np.ndarray,
    threshold: float,
) -> tuple[list[int], dict[int, float], list[tuple[int, float]]]:
    similarities = training_vectors @ vector
    neighbors = sorted(
        ((index, float(score)) for index, score in enumerate(similarities)),
        key=lambda item: (-item[1], item[0]),
    )
    accepted = [item for item in neighbors if item[1] >= threshold][:MAX_NEIGHBORS]
    votes: dict[int, float] = {}
    for rank, (example_index, similarity) in enumerate(accepted):
        weight = max(0.0, similarity) ** 3 / np.sqrt(rank + 1)
        for article_index in examples[example_index]["positive"]:
            votes[article_index] = votes.get(article_index, 0.0) + weight
        for article_index in examples[example_index]["negative"]:
            votes[article_index] = votes.get(article_index, 0.0) - weight
    positive = {index: score for index, score in votes.items() if score > 0}
    if not positive:
        return [], {}, neighbors[:5]
    maximum = max(positive.values())
    ranked = sorted(positive, key=lambda index: (-positive[index], index))[:POOL]
    return ranked, {index: positive[index] / maximum for index in ranked}, neighbors[:5]


def rrf_lists(lists: list[list[int]]) -> tuple[list[int], dict[int, float]]:
    scores: dict[int, float] = {}
    for ranking in lists:
        for rank, index in enumerate(ranking):
            scores[index] = scores.get(index, 0.0) + 1 / (RRF_K + rank + 1)
    return sorted(scores, key=lambda index: (-scores[index], index)), scores


def rank_bge(
    case: dict,
    vector_by_text: dict[str, np.ndarray],
    chunks: np.ndarray,
    owners: np.ndarray,
    ids: list[str],
    lexical: list[dict],
    examples: list[dict],
    training_vectors: np.ndarray,
    *,
    train_threshold: float,
    train_weight: float,
    bm25_weight: float,
    ranking: str,
    gate: float | None,
) -> dict:
    started = time.perf_counter()
    query_vectors = [vector_by_text[text] for text in case["variants"]]
    variant_scores = []
    for query_vector in query_vectors:
        chunk_scores = chunks @ query_vector
        scores = np.full(len(ids), -1.0, dtype=np.float32)
        np.maximum.at(scores, owners, chunk_scores)
        variant_scores.append(scores)
    best_cosine = np.max(variant_scores, axis=0)
    mean_cosine = np.mean(variant_scores, axis=0)
    dense_lists = [
        np.argsort(-scores, kind="stable")[:POOL].tolist()
        for scores in variant_scores
    ]
    train_ids, train_votes, neighbors = training_vote(
        query_vectors[0], examples, training_vectors, train_threshold
    )
    lexical_ids = [item["index"] for item in lexical]
    source_lists = [*dense_lists]
    if bm25_weight > 0:
        source_lists.append(lexical_ids)
    if train_weight > 0:
        source_lists.append(train_ids)
    fused, _ = rrf_lists(source_lists)
    maximum_lexical = max((item["score"] for item in lexical), default=0.0)
    lexical_scores = {item["index"]: item["score"] for item in lexical}
    semantic_rank: dict[int, float] = {}
    for source in dense_lists:
        for rank, index in enumerate(source):
            semantic_rank[index] = semantic_rank.get(index, 0.0) + (
                21 / (RRF_K + rank + 1) / len(dense_lists)
            )
    bm25_rank = {
        index: 21 / (RRF_K + rank + 1)
        for rank, index in enumerate(lexical_ids)
    }
    training_rank = {
        index: 21 / (RRF_K + rank + 1)
        for rank, index in enumerate(train_ids)
    }
    fused_position = {index: rank for rank, index in enumerate(fused)}

    if gate is not None:
        eligible = [index for index in fused if best_cosine[index] >= gate]
    else:
        eligible = fused[:]
    # Match the production early abstention for explicit out-of-scope queries.
    if case["preemptiveAbstention"]:
        eligible = []

    if ranking == "calibrated":
        def score(index: int) -> float:
            dense_score = min(max((float(mean_cosine[index]) - 0.75) / 0.15, 0), 1)
            lexical_score = (
                lexical_scores.get(index, 0) / maximum_lexical if maximum_lexical > 0 else 0
            )
            corpus = (1 - bm25_weight) * dense_score + bm25_weight * lexical_score
            return (1 - train_weight) * corpus + train_weight * train_votes.get(index, 0)

    elif ranking == "rank":
        def score(index: int) -> float:
            corpus = (
                (1 - bm25_weight) * semantic_rank.get(index, 0)
                + bm25_weight * bm25_rank.get(index, 0)
            )
            return (1 - train_weight) * corpus + train_weight * training_rank.get(index, 0)
    else:
        raise ValueError(ranking)

    ordered = sorted(
        eligible,
        key=lambda index: (-score(index), fused_position[index]),
    )
    latency_ms = (time.perf_counter() - started) * 1000
    return {
        "ranked": [ids[index] for index in ordered[:15]],
        "preGate": [ids[index] for index in fused],
        "postGate": [ids[index] for index in eligible],
        "latencyMs": latency_ms,
        "maxCosine": float(best_cosine.max()),
        "nearestTraining": [
            {"index": index, "similarity": similarity}
            for index, similarity in neighbors
        ],
        "acceptedTraining": sum(
            similarity >= train_threshold
            for _, similarity in neighbors[:MAX_NEIGHBORS]
        ),
    }


def metrics(rows: list[dict], field: str) -> dict:
    output = {}
    for name, subset in [
        ("all", [row for row in rows if not row["negative"]]),
        *[
            (
                domain,
                [
                    row
                    for row in rows
                    if not row["negative"] and row["domain"].startswith(domain)
                ],
            )
            for domain in ("Civil", "Family", "Consumer")
        ],
    ]:
        h1 = h3 = h15 = p3 = pre_q = post_q = pre_l = post_l = 0
        for row in subset:
            expected = set(row["expected"])
            result = row[field]
            ranked = result["ranked"]
            h1 += bool(expected.intersection(ranked[:1]))
            h3 += bool(expected.intersection(ranked[:3]))
            h15 += bool(expected.intersection(ranked[:15]))
            p3 += len(expected.intersection(ranked[:3]))
            pre = expected.intersection(result["preGate"])
            post = expected.intersection(result["postGate"])
            pre_q += bool(pre)
            post_q += bool(post)
            pre_l += len(pre)
            post_l += len(post)
        output[name] = {
            "queries": len(subset),
            "hit1": h1,
            "hit3": h3,
            "hit15": h15,
            "precision3": p3 / (3 * len(subset)),
            "preGateQueries": pre_q,
            "postGateQueries": post_q,
            "preGateLabels": pre_l,
            "postGateLabels": post_l,
        }
    output["negativeReturned"] = sum(
        bool(row[field]["ranked"]) for row in rows if row["negative"]
    )
    return output


def audit_overlap(
    rows: list[dict], cases: list[dict], examples: list[dict], article_ids: list[str]
) -> dict:
    entries = []
    exact = []
    high_char = []
    for row, case in zip(rows, cases):
        query = normalize(case["query"])
        scored = []
        for index, example in enumerate(examples):
            candidate = normalize(example["query"])
            similarity = difflib.SequenceMatcher(None, query, candidate).ratio()
            if query == candidate:
                exact.append({"datasetId": case["datasetId"], "trainingIndex": index})
            if similarity >= 0.80:
                high_char.append(
                    {
                        "datasetId": case["datasetId"],
                        "trainingIndex": index,
                        "characterSimilarity": similarity,
                    }
                )
            scored.append((index, similarity))
        top = row["bge_full_rank"]["nearestTraining"]
        training_details = [
            {
                "index": index,
                "similarity": similarity,
                "query": examples[index]["query"],
                "domain": examples[index]["domain"],
                "positiveArticleIds": [
                    article_ids[i] for i in sorted(examples[index]["positive"])
                ],
                "negativeArticleIds": [
                    article_ids[i] for i in sorted(examples[index]["negative"])
                ],
            }
            for index, similarity in [
                (item["index"], item["similarity"]) for item in top
            ]
        ]
        entries.append(
            {
                "datasetId": case["datasetId"],
                "nearestBgeTraining": top,
                "nearestBgeTrainingDetails": training_details,
                "nearestCharacterMatches": [
                    {"index": index, "similarity": similarity}
                    for index, similarity in sorted(scored, key=lambda x: -x[1])[:3]
                ],
            }
        )
    return {
        "trainingExamples": len(examples),
        "exactNormalizedMatches": exact,
        "highCharacterSimilarityAtLeast0.80": high_char,
        "perCaseNearestMatches": entries,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vector-dir", default="bge-m3")
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()
    vector_dir = HERE / args.vector_dir
    torch.set_num_threads(3)
    inputs = json.loads((HERE / "inputs.json").read_text(encoding="utf-8"))
    cases = inputs["cases"]
    ids = inputs["articleIds"]
    articles = json.loads(
        (ROOT / "assets" / "data" / "legal_articles.json").read_text(encoding="utf-8")
    )
    chunks_text = []
    owners = []
    from segmentation_experiment import _word_chunks

    for index, article in enumerate(articles):
        parts = _word_chunks(article["Article Text"])
        chunks_text.extend(parts)
        owners.extend([index] * len(parts))
    bge = np.load(vector_dir / "chunks.npy", mmap_mode="r")
    e5 = np.fromfile(
        ROOT / "assets" / "data" / "chunk_embeddings_e5.f32", dtype="<f4"
    ).reshape(-1, E5_DIMENSIONS)
    if len(chunks_text) != len(owners) or len(owners) != len(bge) or len(owners) != len(e5):
        raise ValueError("BGE/E5 chunk embeddings and corpus ownership disagree.")
    owners_array = np.asarray(owners)

    examples = load_training(ids)
    train_bge, train_meta = bge_training_vectors(
        examples, vector_dir, int8=args.int8
    )
    train_e5 = np.fromfile(
        ROOT / "assets" / "data" / "training_query_embeddings_e5.f32", dtype="<f4"
    ).reshape(-1, E5_DIMENSIONS)
    if train_e5.shape != (len(examples), E5_DIMENSIONS):
        raise ValueError("Packaged E5 training-query embeddings do not align.")

    # Exact current E5 vectors verify that this is the same E5 pipeline.
    input_vector_cache = json.loads(
        (ROOT / "tool" / "retrieval_lab" / "diagnostics" / "stage1_baseline" / "vectors.json").read_text(encoding="utf-8")
    )
    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_file(str(ROOT / "assets" / "models" / "e5_tokenizer.json"))
    tokenizer.enable_truncation(max_length=256)
    e5_queries = {}
    for case in cases:
        for text in case["variants"]:
            key = ",".join(map(str, tokenizer.encode("query: " + text).ids))
            e5_queries[text] = np.asarray(input_vector_cache[key], dtype=np.float32)

    lexical_index = {
        row["datasetId"]: row for row in cases
    }
    queries = list(dict.fromkeys(text for case in cases for text in case["variants"]))
    bge_queries = np.load(vector_dir / "queries.npy", mmap_mode="r")
    previous_queries = json.loads(
        (vector_dir / "metadata.json").read_text(encoding="utf-8")
    )
    if previous_queries["maxQueryTokens"] <= 0 or len(bge_queries) != len(queries):
        raise ValueError("BGE query vectors do not align with the corpus export.")
    bge_query_by_text = {text: bge_queries[i] for i, text in enumerate(queries)}
    bge_gate = json.loads(
        (vector_dir / "results.json").read_text(encoding="utf-8")
    )["gate"]

    fields = {
        "e5_production": [],
        "bge_dense": [],
        "bge_full_calibrated": [],
        "bge_full_rank": [],
        "bge_full_rank_no_cutoff": [],
        "bge_full_rank_low_training": [],
        "bge_full_rank_thr_0_80": [],
        "bge_full_rank_thr_0_85": [],
    }
    audit_rows = []
    for case in cases:
        lexical = case["lexical"]
        e5_vector_by_text = e5_queries
        e5_result = rank_bge(
            case,
            e5_vector_by_text,
            e5,
            owners_array,
            ids,
            lexical,
            examples,
            train_e5,
            train_threshold=TRAIN_MINIMUM,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="calibrated",
            gate=0.80,
        )
        bge_dense = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=1.1,
            train_weight=0,
            bm25_weight=0,
            ranking="rank",
            gate=bge_gate,
        )
        bge_calibrated = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=TRAIN_MINIMUM,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="calibrated",
            gate=bge_gate,
        )
        bge_rank = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=TRAIN_MINIMUM,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="rank",
            gate=bge_gate,
        )
        bge_no_cutoff = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=0.0,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="rank",
            gate=bge_gate,
        )
        bge_low_training = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=TRAIN_MINIMUM,
            train_weight=0.15,
            bm25_weight=0.15,
            ranking="rank",
            gate=bge_gate,
        )
        bge_thr_80 = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=0.80,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="rank",
            gate=bge_gate,
        )
        bge_thr_85 = rank_bge(
            case,
            bge_query_by_text,
            bge,
            owners_array,
            ids,
            lexical,
            examples,
            train_bge,
            train_threshold=0.85,
            train_weight=0.30,
            bm25_weight=0.15,
            ranking="rank",
            gate=bge_gate,
        )
        outputs = {
            "e5_production": e5_result,
            "bge_dense": bge_dense,
            "bge_full_calibrated": bge_calibrated,
            "bge_full_rank": bge_rank,
            "bge_full_rank_no_cutoff": bge_no_cutoff,
            "bge_full_rank_low_training": bge_low_training,
            "bge_full_rank_thr_0_80": bge_thr_80,
            "bge_full_rank_thr_0_85": bge_thr_85,
        }
        row = {
            "datasetId": case["datasetId"],
            "domain": case["domain"],
            "negative": case["negative"],
            "expected": case["expected"],
            "preemptiveAbstention": case["preemptiveAbstention"],
            **outputs,
        }
        for name, value in outputs.items():
            fields[name].append(value)
        audit_rows.append(row)
    report = {
        "models": {
            "E5-small": {
                "trainingVectorCount": int(len(train_e5)),
                "trainingDimensions": E5_DIMENSIONS,
                "productionWeightBytes": int((ROOT / "assets" / "models" / "catalyst_encoder_e5.onnx").stat().st_size),
            },
            "BGE-M3": {
                **train_meta,
                "weightBytes": int(
                    next(
                        path.stat().st_size
                        for path in (
                            Path(snapshot_download("BAAI/bge-m3", local_files_only=True), "model.safetensors"),
                            Path(snapshot_download("BAAI/bge-m3", local_files_only=True), "pytorch_model.bin"),
                        )
                        if path.exists()
                    )
                ),
                "articleChunkWeightBytes": int((vector_dir / "chunks.npy").stat().st_size),
                "indexDirectory": vector_dir.name,
                "quantization": "dynamic-int8" if args.int8 else "fp32",
            },
        },
        "strategies": {
            name: {
                "metrics": metrics(audit_rows, name),
                "meanRankingMilliseconds": float(
                    np.mean([row[name]["latencyMs"] for row in audit_rows if not row["negative"]])
                ),
            }
            for name in fields
        },
        "trainingOverlapAudit": audit_overlap(audit_rows, cases, examples, ids),
        "rows": audit_rows,
        "limits": [
            "No held-out cases or evaluation labels are used as retrieval features.",
            "Training-query vectors are re-encoded with BGE-M3 and are not mixed with E5 vectors.",
            "BGE-M3 gate is the prior fixed negative-probe maximum plus 1e-6; those probes are limited.",
            "The 46 development queries may overlap with training-query examples.",
        ],
    }
    (vector_dir / "full_hybrid_results.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(json.dumps({key: value for key, value in report.items() if key != "rows"}, indent=2), flush=True)


if __name__ == "__main__":
    main()
