"""Offline cross-encoder experiment on candidates exported by Flutter.

The local model is never sent query or corpus text over a network.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import math
import os
import statistics
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

HERE = Path(__file__).resolve().parent
COUNTS = (30, 50, 100, 200)
WEIGHTS = (0.25, 0.50, 0.75, 1.0)
MAX_LENGTH = 256
QUERY_LIMIT = 128
OVERLAP = 32
BATCH_SIZE = 8


def windows(query_ids: list[int], document_ids: list[int]) -> list[list[int]]:
    """Cover every document token with overlapping XLM-R pair windows."""
    query_ids = query_ids[:QUERY_LIMIT]
    capacity = MAX_LENGTH - len(query_ids) - 4
    if capacity <= OVERLAP:
        raise ValueError("Query leaves insufficient room for document tokens.")
    if not document_ids:
        return [[0, *query_ids, 2, 2, 2]]
    pairs = []
    for start in range(0, len(document_ids), capacity - OVERLAP):
        pairs.append([0, *query_ids, 2, 2, *document_ids[start : start + capacity], 2])
        if start + capacity >= len(document_ids):
            break
    return pairs


def memory_bytes() -> tuple[int, int]:
    if os.name != "nt":
        raise OSError("Memory measurement requires Windows GetProcessMemoryInfo.")

    class MemoryCounters(ctypes.Structure):
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

    counters = MemoryCounters()
    counters.cb = ctypes.sizeof(counters)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    psapi = ctypes.WinDLL("psapi", use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.c_void_p
    psapi.GetProcessMemoryInfo.argtypes = [
        ctypes.c_void_p,
        ctypes.POINTER(MemoryCounters),
        ctypes.c_ulong,
    ]
    if not psapi.GetProcessMemoryInfo(
        kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb
    ):
        raise ctypes.WinError(ctypes.get_last_error())
    return counters.WorkingSetSize, counters.PeakWorkingSetSize


class CrossEncoder:
    def __init__(self, model: Path, tokenizer_path: Path, threads: int):
        before, _ = memory_bytes()
        start = time.perf_counter()
        self.tokenizer = Tokenizer.from_file(str(tokenizer_path))
        self.tokenizer.no_truncation()
        self.tokenizer.no_padding()
        if [self.tokenizer.token_to_id(t) for t in ("<s>", "</s>", "<pad>")] != [0, 2, 1]:
            raise ValueError("Unexpected XLM-R special token IDs.")
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = threads
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(
            str(model), sess_options=opts, providers=["CPUExecutionProvider"]
        )
        self.load_seconds = time.perf_counter() - start
        current, peak = memory_bytes()
        self.memory = {
            "before_load_working_set_bytes": before,
            "after_load_working_set_bytes": current,
            "after_load_peak_working_set_bytes": peak,
        }

    def score(
        self,
        query: str,
        candidates: list[dict],
        document_cache: dict[str, list[int]] | None = None,
    ) -> tuple[list[float], float, int]:
        start = time.perf_counter()
        query_ids = self.tokenizer.encode(query, add_special_tokens=False).ids
        rows: list[list[int]] = []
        owners: list[int] = []
        for index, candidate in enumerate(candidates):
            if not isinstance(candidate["text"], str):
                raise ValueError(f"Candidate {candidate['id']} has no corpus text.")
            text = candidate["text"]
            if document_cache is not None and text in document_cache:
                doc_ids = document_cache[text]
            else:
                doc_ids = self.tokenizer.encode(text, add_special_tokens=False).ids
                if document_cache is not None:
                    document_cache[text] = doc_ids
            for pair in windows(query_ids, doc_ids):
                rows.append(pair)
                owners.append(index)

        logits = [-math.inf] * len(candidates)
        for offset in range(0, len(rows), BATCH_SIZE):
            batch = rows[offset : offset + BATCH_SIZE]
            width = max(map(len, batch))
            ids = np.full((len(batch), width), 1, dtype=np.int64)
            mask = np.zeros((len(batch), width), dtype=np.int64)
            for row, tokens in enumerate(batch):
                ids[row, : len(tokens)] = tokens
                mask[row, : len(tokens)] = 1
            output = self.session.run(None, {"input_ids": ids, "attention_mask": mask})[0]
            for i, value in enumerate(output.reshape(-1)):
                logit = float(value)
                if not math.isfinite(logit):
                    raise ValueError("Cross-encoder produced a non-finite score.")
                owner = owners[offset + i]
                logits[owner] = max(logits[owner], logit)
        return logits, time.perf_counter() - start, len(rows)


def ranked(candidates: list[dict], logits: list[float], count: int, weight: float) -> list[str]:
    if len(candidates) != len(logits):
        raise ValueError("Candidate and score counts differ.")
    subset = list(zip(candidates[:count], logits[:count]))
    def score(pair: tuple[dict, float]) -> float:
        candidate, logit = pair
        probability = 1 / (1 + math.exp(-max(-80.0, min(80.0, logit))))
        return weight * probability + (1 - weight) * candidate["hybridScore"]
    subset.sort(key=score, reverse=True)
    return [candidate["id"] for candidate, _ in subset]


def metrics(records: list[dict], pool: str, count: int, weight: float) -> dict:
    hits = [0, 0, 0]
    relevant3 = 0
    per_query = []
    for record in records:
        item = record[pool]
        ids = ranked(item["candidates"], item["logits"], count, weight)
        relevant = set(record["relevant"])
        for index, cutoff in enumerate((1, 3, 15)):
            hits[index] += bool(relevant.intersection(ids[:cutoff]))
        relevant3 += sum(article in relevant for article in ids[:3])
        per_query.append({"datasetId": record["datasetId"], "top15": ids[:15]})
    return {
        "hitAt1": hits[0],
        "hitAt3": hits[1],
        "hitAt15": hits[2],
        "precisionAt3": relevant3 / (3 * len(records)),
        "perQuery": per_query,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    source = HERE / "candidates.json"
    payload = json.loads(source.read_text(encoding="utf-8"))
    with args.model.open("rb") as file:
        model_sha = hashlib.file_digest(file, "sha256").hexdigest()
    source_sha = hashlib.sha256(source.read_bytes()).hexdigest()
    with args.tokenizer.open("rb") as file:
        tokenizer_sha = hashlib.file_digest(file, "sha256").hexdigest()
    header = {"modelSha256": model_sha, "tokenizerSha256": tokenizer_sha, "sourceSha256": source_sha}
    checkpoint = HERE / "scores.jsonl"
    saved = {}
    if checkpoint.exists():
        with checkpoint.open(encoding="utf-8") as file:
            for line in file:
                row = json.loads(line)
                if row["header"] != header:
                    raise ValueError("Checkpoint does not match model, tokenizer, or candidate input.")
                saved[row["key"]] = row["record"]
    encoder = CrossEncoder(args.model, args.tokenizer, args.threads)
    cases = payload["cases"]
    all_records = [(row["datasetId"], row) for row in cases]
    all_records += [(f"negative-{i}", row) for i, row in enumerate(payload["negatives"])]
    all_records += [("coownership", payload["coownership"])]
    with checkpoint.open("a", encoding="utf-8") as out:
        for key, record in all_records:
            if key in saved:
                record.update(saved[key])
                continue
            for pool in ("pool50", "pool500"):
                item = record[pool]
                logits, seconds, windows_count = encoder.score(record["query"], item["candidates"])
                item.update({"logits": logits, "rerankSeconds": seconds, "windows": windows_count})
            saved[key] = record
            out.write(json.dumps({"header": header, "key": key, "record": record}, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{key}: {record['pool50']['rerankSeconds']:.1f}s / {record['pool500']['rerankSeconds']:.1f}s", flush=True)

    summaries = []
    for pool in ("pool50", "pool500"):
        for count in COUNTS:
            for weight in WEIGHTS:
                result = metrics(cases, pool, count, weight)
                result.update({"pool": pool, "candidateCount": count, "crossEncoderWeight": weight})
                result["negativeQueriesWithResults"] = sum(
                    bool(ranked(row[pool]["candidates"], row[pool]["logits"], count, weight))
                    for row in payload["negatives"]
                )
                co = payload["coownership"][pool]
                co_ids = ranked(co["candidates"], co["logits"], count, weight)
                result["coownershipTop15"] = co_ids[:15]
                result["coownershipPassed"] = (
                    "civilcode:493" in co_ids[:3]
                    and "civilcode:1623" in co_ids[:5]
                    and "civilcode:491" in co_ids[:15]
                    and "civilcode:1614" in co_ids[:15]
                    and co_ids.index("civilcode:1614") > co_ids.index("civilcode:493")
                    and "civilcode:1607" not in co_ids[:2]
                )
                summaries.append(result)
    current, peak = memory_bytes()
    output = {
        "note": (
            "Preliminary full-pool scores. Run correct_boundaries.py for "
            "candidate-count results that account for quantized batch effects."
        ),
        "modelSha256": model_sha,
        "tokenizerSha256": tokenizer_sha,
        "candidateSha256": source_sha,
        "modelLoadSeconds": encoder.load_seconds,
        "memory": {**encoder.memory, "endWorkingSetBytes": current, "peakWorkingSetBytes": peak},
        "threads": args.threads,
        "batchSize": BATCH_SIZE,
        "maxPairTokens": MAX_LENGTH,
        "queryTokenLimit": QUERY_LIMIT,
        "documentOverlapTokens": OVERLAP,
        "timings": {
            pool: {
                "meanSeconds": statistics.mean(row[pool]["rerankSeconds"] for row in cases),
                "medianSeconds": statistics.median(row[pool]["rerankSeconds"] for row in cases),
                "meanWindows": statistics.mean(row[pool]["windows"] for row in cases),
                "meanCandidates": statistics.mean(len(row[pool]["candidates"]) for row in cases),
            }
            for pool in ("pool50", "pool500")
        },
        "configurations": summaries,
    }
    (HERE / "results.json").write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
