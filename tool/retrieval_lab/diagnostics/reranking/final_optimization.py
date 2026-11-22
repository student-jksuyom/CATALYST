"""Evaluate only 10/20/30-candidate cutoffs and benchmark document-token caching."""

import argparse
import hashlib
import json
import statistics
from pathlib import Path

from correct_boundaries import coownership_passes, corrected_logits
from rerank import HERE, CrossEncoder, memory_bytes, ranked

COUNTS = (10, 20, 30)
WEIGHT = 0.5


def load_records(model, tokenizer):
    rows = [json.loads(line) for line in (HERE / "scores.jsonl").read_text(encoding="utf-8").splitlines()]
    source = json.loads((HERE / "results.json").read_text(encoding="utf-8"))
    expected = {
        "modelSha256": source["modelSha256"],
        "tokenizerSha256": source["tokenizerSha256"],
        "sourceSha256": source["candidateSha256"],
    }
    if any(row["header"] != expected for row in rows):
        raise ValueError("Scores checkpoint does not match the recorded experiment.")
    for path, key in ((model, "modelSha256"), (tokenizer, "tokenizerSha256")):
        with path.open("rb") as file:
            if hashlib.file_digest(file, "sha256").hexdigest() != expected[key]:
                raise ValueError(f"{path} does not match the scored checkpoint.")
    records = {row["key"]: row["record"] for row in rows}
    cases = [row["record"] for row in rows if not row["key"].startswith("negative-") and row["key"] != "coownership"]
    negatives = [row["record"] for row in rows if row["key"].startswith("negative-")]
    if len(cases) != 46 or len(negatives) != 6 or "coownership" not in records:
        raise ValueError("Expected 46 development queries, six probes and co-ownership.")
    return cases, negatives, records["coownership"]


def final_ids(item, logits, count):
    candidates = item["candidates"]
    prefix = candidates[:count]
    ids = ranked(prefix, logits, count, WEIGHT)
    if count < 15:
        ids.extend(candidate["id"] for candidate in candidates[count:15])
    return ids[:15]


def summary(cases, lists):
    hit1 = hit3 = hit15 = relevant3 = 0
    for case in cases:
        ids = lists[case["datasetId"]]
        relevant = set(case["relevant"])
        hit1 += bool(relevant.intersection(ids[:1]))
        hit3 += bool(relevant.intersection(ids[:3]))
        hit15 += bool(relevant.intersection(ids[:15]))
        relevant3 += sum(article in relevant for article in ids[:3])
    return {
        "hitAt1": hit1,
        "hitAt3": hit3,
        "hitAt15": hit15,
        "precisionAt3": relevant3 / (3 * len(cases)),
    }


def accuracy(encoder, cases, negatives, coownership):
    output = []
    for count in COUNTS:
        lists = {}
        for case in cases:
            item = case["pool50"]
            logits = corrected_logits(encoder, case["query"], item, count)
            lists[case["datasetId"]] = final_ids(item, logits, count)
        co_item = coownership["pool50"]
        co_logits = corrected_logits(encoder, coownership["query"], co_item, count)
        co_ids = final_ids(co_item, co_logits, count)
        negative_count = 0
        for row in negatives:
            item = row["pool50"]
            logits = corrected_logits(encoder, row["query"], item, count)
            negative_count += bool(final_ids(item, logits, count))
        record = {
            "candidateCount": count,
            **summary(cases, lists),
            "negativeQueriesWithResults": negative_count,
            "coownershipPassed": coownership_passes(co_ids),
            "coownershipTop15": co_ids,
            "perQueryTop15": lists,
        }
        output.append(record)
        print(f"Cutoff {count}: {record['hitAt1']}/{record['hitAt3']}/{record['hitAt15']}, coownership={record['coownershipPassed']}", flush=True)
    safe = [
        row for row in output
        if row["hitAt3"] > 17
        and row["hitAt1"] >= 13
        and row["hitAt15"] >= 21
        and row["negativeQueriesWithResults"] == 0
        and row["coownershipPassed"]
    ]
    safe.sort(key=lambda row: (-row["hitAt3"], -row["hitAt1"], -row["hitAt15"], -row["precisionAt3"], row["candidateCount"]))
    result = {
        "sourcePool": 50,
        "crossEncoderWeight": WEIGHT,
        "baseline": {"hitAt1": 13, "hitAt3": 17, "hitAt15": 21, "precisionAt3": 17 / 138},
        "method": "Cached full-pool logits with exact quantized batch-boundary correction. For top 10, original ranks 11-15 are retained.",
        "configurations": output,
        "selectedCandidateCount": safe[0]["candidateCount"] if safe else None,
    }
    (HERE / "final_cutoffs.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


def benchmark(encoder, cases, negatives, coownership, count, use_cache, sample):
    cutoff_results = json.loads((HERE / "final_cutoffs.json").read_text(encoding="utf-8"))
    expected = next(row for row in cutoff_results["configurations"] if row["candidateCount"] == count)
    if sample:
        selected_ids = ("CC-EV-001", "FC-EV-001", "CA-EV-001")
        cases = [next(case for case in cases if case["datasetId"] == key) for key in selected_ids]
    cache = {} if use_cache else None
    encoder.score(cases[0]["query"], cases[0]["pool50"]["candidates"][:1])
    lists = {}
    durations = []
    windows_total = 0
    for case in cases:
        item = case["pool50"]
        candidates = item["candidates"][:count]
        logits, seconds, windows = encoder.score(case["query"], candidates, cache)
        ids = final_ids(item, logits, count)
        if ids != expected["perQueryTop15"][case["datasetId"]]:
            raise ValueError(f"Cached cutoff result differs for {case['datasetId']}.")
        lists[case["datasetId"]] = ids
        durations.append(seconds)
        windows_total += windows
        print(f"{case['datasetId']}: {seconds:.3f}s", flush=True)
    negative_count = 0
    for row in negatives:
        item = row["pool50"]
        candidates = item["candidates"][:count]
        logits = encoder.score(row["query"], candidates, cache)[0] if candidates else []
        negative_count += bool(final_ids(item, logits, count))
    co_item = coownership["pool50"]
    co_logits = encoder.score(coownership["query"], co_item["candidates"][:count], cache)[0]
    co_ids = final_ids(co_item, co_logits, count)
    if negative_count != expected["negativeQueriesWithResults"] or co_ids != expected["coownershipTop15"]:
        raise ValueError("Negative probe or co-ownership parity failed.")
    current, peak = memory_bytes()
    result = {
        "candidateCount": count,
        "documentTokenCache": use_cache,
        "cacheEntries": len(cache) if cache is not None else 0,
        "metrics": summary(cases, lists),
        "negativeQueriesWithResults": negative_count,
        "coownershipPassed": coownership_passes(co_ids),
        "exactTop15Matches": len(lists),
        "meanRerankSeconds": statistics.mean(durations),
        "medianRerankSeconds": statistics.median(durations),
        "p95RerankSeconds": sorted(durations)[math_ceil_95(len(durations)) - 1],
        "minRerankSeconds": min(durations),
        "maxRerankSeconds": max(durations),
        "totalRerankSeconds": sum(durations),
        "meanWindows": windows_total / len(cases),
        "modelLoadSeconds": encoder.load_seconds,
        "memory": {**encoder.memory, "endWorkingSetBytes": current, "peakWorkingSetBytes": peak},
        "secondsPerQuery": dict(zip((case["datasetId"] for case in cases), durations)),
        "note": "Windows CPU, 4 threads by default, cached E5 queries; excludes E5 inference and mobile overhead.",
    }
    prefix = f"final_sample_{count}" if sample else "final_benchmark"
    path = HERE / f"{prefix}_{'cache' if use_cache else 'no_cache'}.json"
    path.write_text(json.dumps(result, indent=2), encoding="utf-8")


def math_ceil_95(size):
    return (size * 95 + 99) // 100


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--mode", choices=("accuracy", "benchmark"), required=True)
    parser.add_argument("--count", type=int, choices=COUNTS)
    parser.add_argument("--cache", action="store_true")
    parser.add_argument("--sample", action="store_true")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    cases, negatives, coownership = load_records(args.model, args.tokenizer)
    encoder = CrossEncoder(args.model, args.tokenizer, args.threads)
    if args.mode == "accuracy":
        accuracy(encoder, cases, negatives, coownership)
    elif args.count is None:
        parser.error("--count is required for benchmarking")
    else:
        benchmark(encoder, cases, negatives, coownership, args.count, args.cache, args.sample)


if __name__ == "__main__":
    main()
