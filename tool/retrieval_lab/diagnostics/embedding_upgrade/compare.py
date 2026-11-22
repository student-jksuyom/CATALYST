"""Compare offline multilingual encoders without using training-query labels."""

from __future__ import annotations

import argparse
import ctypes
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
from segmentation_experiment import _word_chunks  # noqa: E402

MODELS = {
    "e5-small": ("intfloat/multilingual-e5-small", 384, True),
    "e5-base": ("intfloat/multilingual-e5-base", 768, True),
    "bge-m3": ("BAAI/bge-m3", 1024, False),
}
POOL = 50
RRF_K = 20
BM25_WEIGHT = 0.15


def peak_memory() -> int:
    if sys.platform != "win32":
        import resource

        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return int(value if sys.platform == "darwin" else value * 1024)

    class Counters(ctypes.Structure):
        _fields_ = [
            ("cb", ctypes.c_ulong),
            ("PageFaultCount", ctypes.c_ulong),
            ("PeakWorkingSetSize", ctypes.c_size_t),
            ("WorkingSetSize", ctypes.c_size_t),
            ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPagedPoolUsage", ctypes.c_size_t),
            ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
            ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
            ("PagefileUsage", ctypes.c_size_t),
            ("PeakPagefileUsage", ctypes.c_size_t),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    psapi.GetProcessMemoryInfo.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(Counters),
        ctypes.c_ulong,
    ]
    counters = Counters()
    counters.cb = ctypes.sizeof(counters)
    if not psapi.GetProcessMemoryInfo(
        kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return counters.PeakWorkingSetSize


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()


def validate_vectors(vectors: np.ndarray, shape: tuple[int, int]) -> None:
    if vectors.shape != shape or not np.isfinite(vectors).all():
        raise ValueError(f"Invalid vectors: expected {shape}, got {vectors.shape}.")
    if not np.allclose(np.linalg.norm(vectors, axis=1), 1.0, atol=1e-4):
        raise ValueError("Vectors are not L2-normalized.")


def encode_batch(model, tokenizer, texts: list[str], is_e5: bool) -> np.ndarray:
    inputs = tokenizer(
        texts, padding=True, truncation=True, max_length=512, return_tensors="pt"
    )
    with torch.inference_mode():
        hidden = model(**inputs).last_hidden_state
        if is_e5:
            mask = inputs["attention_mask"].unsqueeze(-1)
            pooled = (hidden * mask).sum(dim=1) / mask.sum(dim=1)
        else:
            pooled = hidden[:, 0]
        vectors = torch.nn.functional.normalize(pooled, p=2, dim=1)
    return vectors.cpu().numpy().astype(np.float32)


def build_vectors(
    name: str,
    chunks: list[str],
    queries: list[str],
    corpus_digest: str,
    *,
    int8: bool = False,
) -> tuple[np.ndarray, np.ndarray, dict]:
    model_id, dimensions, is_e5 = MODELS[name]
    cache_name = f"{name}-int8" if int8 else name
    directory = HERE / cache_name
    directory.mkdir(parents=True, exist_ok=True)
    chunk_path, query_path, meta_path = (
        directory / "chunks.npy",
        directory / "queries.npy",
        directory / "metadata.json",
    )
    snapshot = Path(snapshot_download(model_id, local_files_only=True))
    weight_bytes = next(
        path.stat().st_size
        for path in (snapshot / "model.safetensors", snapshot / "pytorch_model.bin")
        if path.exists()
    )
    signature = digest(
        {
            "model": model_id,
            "revision": snapshot.name,
            "corpus": corpus_digest,
            "queries": queries,
            "maxLength": 512,
            "quantization": "dynamic-int8" if int8 else "fp32",
        }
    )
    if meta_path.exists() and chunk_path.exists() and query_path.exists():
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        if meta["signature"] == signature:
            if "weightBytes" not in meta:
                meta["weightBytes"] = weight_bytes
                meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
            chunk_vectors = np.load(chunk_path, allow_pickle=False)
            query_vectors = np.load(query_path, allow_pickle=False)
            validate_vectors(chunk_vectors, (len(chunks), dimensions))
            validate_vectors(query_vectors, (len(queries), dimensions))
            print(f"{name}: using validated cache", flush=True)
            return chunk_vectors, query_vectors, meta

    tokenizer = AutoTokenizer.from_pretrained(snapshot, local_files_only=True)
    model = AutoModel.from_pretrained(snapshot, local_files_only=True)
    estimated_quantized_bytes = None
    if int8:
        model = torch.ao.quantization.quantize_dynamic(
            model, {torch.nn.Linear}, dtype=torch.qint8
        )
        estimated_quantized_bytes = sum(
            parameter.numel() * parameter.element_size()
            for parameter in model.parameters()
        ) + sum(
            module.weight().numel()
            + (module.bias().numel() * module.bias().element_size() if module.bias() is not None else 0)
            for module in model.modules()
            if isinstance(module, torch.ao.nn.quantized.dynamic.Linear)
        )
    model.eval()
    revision = snapshot.name
    prefix = "passage: " if is_e5 else ""
    formatted = [prefix + text for text in chunks]
    lengths = [
        len(ids)
        for ids in tokenizer(formatted, truncation=False, padding=False)["input_ids"]
    ]
    if max(lengths) > 512:
        raise ValueError(f"{name}: corpus chunk exceeds 512 tokens.")
    if name == "e5-small" and not int8:
        chunk_vectors = np.fromfile(
            ROOT / "assets" / "data" / "chunk_embeddings_e5.f32", dtype="<f4"
        ).reshape(-1, dimensions)
        sample = [0, 100, 1000, 2000, 3000, 4000]
        encoded = encode_batch(model, tokenizer, [formatted[i] for i in sample], is_e5)
        similarities = (encoded * chunk_vectors[sample]).sum(axis=1)
        if float(similarities.min()) < 0.9999:
            raise ValueError(f"Packaged E5 vectors disagree with the model: {similarities}.")
        indexing_seconds = None
    else:
        order = np.argsort(lengths, kind="stable")
        partial_path = directory / "chunks.partial.npy"
        progress_path = directory / "progress.json"
        if progress_path.exists():
            progress = json.loads(progress_path.read_text(encoding="utf-8"))
            if progress["signature"] != signature or not partial_path.exists():
                raise ValueError(f"{name}: incompatible or incomplete checkpoint.")
            offset_start = progress["offset"]
            chunk_vectors = np.lib.format.open_memmap(partial_path, mode="r+")
            if chunk_vectors.shape != (len(chunks), dimensions):
                raise ValueError(f"{name}: checkpoint shape mismatch.")
        else:
            if partial_path.exists():
                raise ValueError(f"{name}: checkpoint has no progress metadata.")
            offset_start = 0
            chunk_vectors = np.lib.format.open_memmap(
                partial_path, mode="w+", dtype=np.float32, shape=(len(chunks), dimensions)
            )
            progress_path.write_text(
                json.dumps({"signature": signature, "offset": 0}), encoding="utf-8"
            )
        start = time.perf_counter()
        for offset in range(offset_start, len(order), 8):
            indexes = order[offset : offset + 8]
            vectors = encode_batch(
                model, tokenizer, [formatted[int(i)] for i in indexes], is_e5
            )
            chunk_vectors[indexes] = vectors
            if offset % 400 == 0:
                print(f"{name}: {min(offset + 8, len(order))}/{len(order)} chunks", flush=True)
            if (offset + 8) % 400 == 0 or offset + 8 >= len(order):
                chunk_vectors.flush()
                progress_path.write_text(
                    json.dumps({"signature": signature, "offset": min(offset + 8, len(order))}),
                    encoding="utf-8",
                )
        indexing_seconds = time.perf_counter() - start
    validate_vectors(chunk_vectors, (len(chunks), dimensions))

    query_prefix = "query: " if is_e5 else ""
    formatted_queries = [query_prefix + query for query in queries]
    query_lengths = [
        len(ids)
        for ids in tokenizer(formatted_queries, truncation=False, padding=False)["input_ids"]
    ]
    if max(query_lengths) > 512:
        raise ValueError(f"{name}: query exceeds 512 tokens.")
    encode_batch(model, tokenizer, formatted_queries[:1], is_e5)
    query_vectors = np.empty((len(queries), dimensions), dtype=np.float32)
    query_seconds = []
    for index, query in enumerate(formatted_queries):
        started = time.perf_counter()
        query_vectors[index] = encode_batch(model, tokenizer, [query], is_e5)[0]
        query_seconds.append(time.perf_counter() - started)
    validate_vectors(query_vectors, (len(queries), dimensions))
    if name == "e5-small":
        np.save(chunk_path, chunk_vectors, allow_pickle=False)
    else:
        chunk_vectors = np.array(chunk_vectors)
        partial_path.replace(chunk_path)
        progress_path.unlink()
    np.save(query_path, query_vectors, allow_pickle=False)
    meta = {
        "signature": signature,
        "model": model_id,
        "quantization": "dynamic-int8" if int8 else "fp32",
        "revision": revision,
        "dimensions": dimensions,
        "weightBytes": weight_bytes,
        "estimatedQuantizedParameterBytes": estimated_quantized_bytes,
        "corpusDigest": corpus_digest,
        "indexingSeconds": indexing_seconds,
        "meanSingleQuerySeconds": sum(query_seconds) / len(query_seconds),
        "peakRssBytes": peak_memory(),
        "maxChunkTokens": max(lengths),
        "maxQueryTokens": max(query_lengths),
    }
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
    return chunk_vectors, query_vectors, meta


def summarize(rows: list[dict], variant: str) -> dict:
    positive = [row for row in rows if not row["negative"]]
    metrics = {}
    for label, subset in [
        ("all", positive),
        *[
            (law, [row for row in positive if row["domain"].startswith(law)])
            for law in ("Civil", "Family", "Consumer")
        ],
    ]:
        hit1 = hit3 = hit15 = precision = pre_q = post_q = pre_l = post_l = 0
        for row in subset:
            expected = set(row["expected"])
            result = row[variant]
            ranked = result["ranked"]
            hit1 += bool(expected.intersection(ranked[:1]))
            hit3 += bool(expected.intersection(ranked[:3]))
            hit15 += bool(expected.intersection(ranked[:15]))
            precision += len(expected.intersection(ranked[:3]))
            pre = expected.intersection(result["preGate"])
            post = expected.intersection(result["postGate"])
            pre_q += bool(pre)
            post_q += bool(post)
            pre_l += len(pre)
            post_l += len(post)
        metrics[label] = {
            "queries": len(subset),
            "hit1": hit1,
            "hit3": hit3,
            "hit15": hit15,
            "precision3": precision / (3 * len(subset)),
            "preGateQueries": pre_q,
            "postGateQueries": post_q,
            "preGateLabels": pre_l,
            "postGateLabels": post_l,
        }
    metrics["negativeReturned"] = sum(
        bool(row[variant]["ranked"]) for row in rows if row["negative"]
    )
    return metrics


def evaluate(cases, ids, owners, chunks, query_vectors, query_positions) -> dict:
    scores = []
    for case in cases:
        per_variant = []
        for text in case["variants"]:
            chunk_scores = chunks @ query_vectors[query_positions[text]]
            article_scores = np.full(len(ids), -1.0, dtype=np.float32)
            np.maximum.at(article_scores, owners, chunk_scores)
            per_variant.append(article_scores)
        scores.append(np.asarray(per_variant))

    negative_max = max(
        float(score.max()) for case, score in zip(cases, scores) if case["negative"]
    )
    gate = negative_max + 1e-6
    rows = []
    for case, variant_scores in zip(cases, scores):
        cosine = variant_scores.max(axis=0)
        semantic = {}
        for variant in variant_scores:
            for rank, index in enumerate(np.argsort(-variant, kind="stable")[:POOL]):
                semantic[int(index)] = semantic.get(int(index), 0.0) + (
                    1 / (RRF_K + rank + 1) / len(variant_scores)
                )
        lexical = {
            item["index"]: 1 / (RRF_K + rank + 1)
            for rank, item in enumerate(case["lexical"])
        }
        row = {
            "datasetId": case["datasetId"],
            "domain": case["domain"],
            "negative": case["negative"],
            "expected": case["expected"],
            "maxCosine": float(cosine.max()),
        }
        for label, weight in (("dense", 0.0), ("hybrid", BM25_WEIGHT)):
            candidates = set(semantic) | (set(lexical) if weight else set())
            ordered = sorted(
                candidates,
                key=lambda index: (
                    -((1 - weight) * semantic.get(index, 0) + weight * lexical.get(index, 0)),
                    index,
                ),
            )
            for stage, threshold in (("ungated", None), ("gated", gate)):
                eligible = [
                    index for index in ordered
                    if threshold is None or cosine[index] >= threshold
                ]
                if case["preemptiveAbstention"]:
                    eligible = []
                row[f"{label}_{stage}"] = {
                    "preGate": [ids[index] for index in ordered],
                    "postGate": [ids[index] for index in eligible],
                    "ranked": [ids[index] for index in eligible[:15]],
                }
        rows.append(row)
    return {
        "gate": gate,
        "gateRule": "highest negative-probe corpus cosine plus 1e-6",
        "metrics": {
            name: summarize(rows, name)
            for name in ("dense_ungated", "dense_gated", "hybrid_ungated", "hybrid_gated")
        },
        "rows": rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=MODELS, required=True)
    parser.add_argument("--threads", type=int, default=3)
    parser.add_argument("--int8", action="store_true")
    args = parser.parse_args()
    torch.set_num_threads(args.threads)
    inputs = json.loads((HERE / "inputs.json").read_text(encoding="utf-8"))
    articles = json.loads((ROOT / "assets" / "data" / "legal_articles.json").read_text(encoding="utf-8"))
    ids, cases = inputs["articleIds"], inputs["cases"]
    actual_ids = [
        re.sub(r"[^a-z0-9]", "", article["Law"].lower())
        + ":"
        + re.sub(r"[^a-z0-9]", "", article["Article"].lower())
        for article in articles
    ]
    if ids != actual_ids or inputs["articleTexts"] != [
        article["Article Text"] for article in articles
    ]:
        raise ValueError("Corpus changed after the Flutter input export.")
    chunks = []
    owners = []
    for index, article in enumerate(articles):
        parts = _word_chunks(article["Article Text"])
        chunks.extend(parts)
        owners.extend([index] * len(parts))
    expected_owners = json.loads(
        (ROOT / "assets" / "data" / "chunk_owners_e5.json").read_text(encoding="utf-8")
    )
    if owners != expected_owners or len(ids) != len(articles) or len(set(ids)) != len(ids):
        raise ValueError("Corpus chunk ownership or article mapping mismatch.")
    known = set(ids)
    if any(not set(case["expected"]).issubset(known) for case in cases):
        raise ValueError("A development label does not map to the corpus.")
    queries = list(dict.fromkeys(text for case in cases for text in case["variants"]))
    query_positions = {query: index for index, query in enumerate(queries)}
    corpus_digest = digest({"ids": ids, "chunks": chunks, "owners": owners})
    chunk_vectors, query_vectors, metadata = build_vectors(
        args.model, chunks, queries, corpus_digest, int8=args.int8
    )
    result = evaluate(cases, ids, np.asarray(owners), chunk_vectors, query_vectors, query_positions)
    result["metadata"] = metadata
    cache_name = f"{args.model}-int8" if args.int8 else args.model
    output = HERE / cache_name / "results.json"
    output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({"model": cache_name, "gate": result["gate"], "metrics": result["metrics"], "metadata": metadata}, indent=2), flush=True)


if __name__ == "__main__":
    main()
