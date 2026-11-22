"""Recompute quantized scores affected by candidate-count batch boundaries."""
import argparse
import hashlib
import json
import math
import time
from pathlib import Path

import numpy as np

from rerank import BATCH_SIZE, COUNTS, HERE, WEIGHTS, CrossEncoder, metrics, ranked, windows


def corrected_logits(encoder, query, item, count):
    candidates = item["candidates"][:count]
    original = item["logits"][: len(candidates)]
    if not candidates or len(candidates) == len(item["candidates"]):
        return original
    query_ids = encoder.tokenizer.encode(query, add_special_tokens=False).ids
    rows = []
    owners = []
    for owner, candidate in enumerate(candidates):
        document = encoder.tokenizer.encode(candidate["text"], add_special_tokens=False).ids
        parts = windows(query_ids, document)
        rows.extend(parts)
        owners.extend([owner] * len(parts))
    remainder = len(rows) % BATCH_SIZE
    if not remainder:
        return original

    affected = set(owners[-remainder:])
    batch_starts = sorted({
        (index // BATCH_SIZE) * BATCH_SIZE
        for index, owner in enumerate(owners)
        if owner in affected
    })
    new_scores = {owner: -math.inf for owner in affected}
    for offset in batch_starts:
        batch = rows[offset : offset + BATCH_SIZE]
        width = max(map(len, batch))
        ids = np.full((len(batch), width), 1, dtype=np.int64)
        mask = np.zeros((len(batch), width), dtype=np.int64)
        for index, tokens in enumerate(batch):
            ids[index, :len(tokens)] = tokens
            mask[index, :len(tokens)] = 1
        output = encoder.session.run(None, {"input_ids": ids, "attention_mask": mask})[0]
        for i, value in enumerate(output.reshape(-1)):
            owner = owners[offset + i]
            if owner in affected:
                new_scores[owner] = max(new_scores[owner], float(value))
    result = list(original)
    for owner, score in new_scores.items():
        if not math.isfinite(score):
            raise ValueError("Non-finite corrected reranker score.")
        result[owner] = score
    return result


def coownership_passes(ids):
    return (
        "civilcode:493" in ids[:3]
        and "civilcode:1623" in ids[:5]
        and "civilcode:491" in ids[:15]
        and "civilcode:1614" in ids[:15]
        and ids.index("civilcode:1614") > ids.index("civilcode:493")
        and "civilcode:1607" not in ids[:2]
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    rows = [json.loads(line) for line in (HERE / "scores.jsonl").read_text(encoding="utf-8").splitlines()]
    source = json.loads((HERE / "results.json").read_text(encoding="utf-8"))
    expected_header = {
        "modelSha256": source["modelSha256"],
        "tokenizerSha256": source["tokenizerSha256"],
        "sourceSha256": source["candidateSha256"],
    }
    if any(row["header"] != expected_header for row in rows):
        raise ValueError("Scores checkpoint does not match the recorded experiment.")
    for path, key in ((args.model, "modelSha256"), (args.tokenizer, "tokenizerSha256")):
        with path.open("rb") as file:
            if hashlib.file_digest(file, "sha256").hexdigest() != expected_header[key]:
                raise ValueError(f"{path} does not match the scored checkpoint.")
    records = {row["key"]: row["record"] for row in rows}
    cases = [row["record"] for row in rows if not row["key"].startswith("negative-") and row["key"] != "coownership"]
    negatives = [row["record"] for row in rows if row["key"].startswith("negative-")]
    if len(cases) != 46 or len(negatives) != 6 or "coownership" not in records:
        raise ValueError("Expected 46 development cases, six probes, and the regression fixture.")
    encoder = CrossEncoder(args.model, args.tokenizer, args.threads)
    start = time.perf_counter()
    corrections = {}
    changed_scores = 0
    max_difference = 0.0
    for key, record in records.items():
        for pool in ("pool50", "pool500"):
            item = record[pool]
            for count in COUNTS:
                fixed = corrected_logits(encoder, record["query"], item, count)
                previous = item["logits"][:len(fixed)]
                changed_scores += sum(abs(a - b) > 1e-6 for a, b in zip(fixed, previous))
                max_difference = max(max_difference, max((abs(a - b) for a, b in zip(fixed, previous)), default=0))
                corrections[(key, pool, count)] = fixed
        print(f"Corrected {key}", flush=True)

    configurations = []
    for pool in ("pool50", "pool500"):
        for count in COUNTS:
            scored_cases = []
            for case in cases:
                copy = dict(case)
                copy[pool] = {**case[pool], "logits": corrections[(case["datasetId"], pool, count)]}
                copy[pool]["candidates"] = copy[pool]["candidates"][:count]
                scored_cases.append(copy)
            for weight in WEIGHTS:
                result = metrics(scored_cases, pool, count, weight)
                co = records["coownership"][pool]
                co_candidates = co["candidates"][:count]
                co_logits = corrections[("coownership", pool, count)]
                co_ids = ranked(co_candidates, co_logits, count, weight)
                result.update({
                    "pool": pool,
                    "candidateCount": count,
                    "crossEncoderWeight": weight,
                    "negativeQueriesWithResults": sum(
                        bool(row[pool]["candidates"][:count]) for row in negatives
                    ),
                    "coownershipTop15": co_ids[:15],
                    "coownershipPassed": coownership_passes(co_ids),
                })
                configurations.append(result)
    result = {
        "note": "Each candidate-count cutoff uses the exact final batch produced by scoring only that cutoff.",
        "sourceModelSha256": source["modelSha256"],
        "changedCandidateScores": changed_scores,
        "maximumAbsoluteLogitDifference": max_difference,
        "correctionSeconds": time.perf_counter() - start,
        "configurations": configurations,
    }
    (HERE / "corrected_results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
