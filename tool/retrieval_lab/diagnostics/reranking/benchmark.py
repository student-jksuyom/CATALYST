"""Measure individual candidate-count reranking latency on three development cases."""
import argparse
import json
import statistics
import time
from pathlib import Path

from rerank import COUNTS, HERE, CrossEncoder, memory_bytes


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tokenizer", type=Path, required=True)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    cases = json.loads((HERE / "candidates.json").read_text(encoding="utf-8"))["cases"]
    selected_ids = ("CC-EV-001", "FC-EV-001", "CA-EV-001")
    selected = [next(row for row in cases if row["datasetId"] == key) for key in selected_ids]
    encoder = CrossEncoder(args.model, args.tokenizer, args.threads)
    encoder.score(selected[0]["query"], selected[0]["pool50"]["candidates"][:1])
    measurements = []
    for row in selected:
        for pool in ("pool50", "pool500"):
            for count in COUNTS:
                item = row[pool]
                candidates = item["candidates"][:count]
                _, seconds, window_count = encoder.score(row["query"], candidates)
                measurements.append({
                    "datasetId": row["datasetId"],
                    "pool": pool,
                    "requestedCandidates": count,
                    "actualCandidates": len(candidates),
                    "windows": window_count,
                    "seconds": seconds,
                    "retrievalMilliseconds": item["milliseconds"],
                })
                print(f"{row['datasetId']} {pool} {count}: {seconds:.2f}s", flush=True)
    summary = []
    for pool in ("pool50", "pool500"):
        for count in COUNTS:
            sample = [m for m in measurements if m["pool"] == pool and m["requestedCandidates"] == count]
            summary.append({
                "pool": pool,
                "requestedCandidates": count,
                "meanRerankSeconds": statistics.mean(m["seconds"] for m in sample),
                "minRerankSeconds": min(m["seconds"] for m in sample),
                "maxRerankSeconds": max(m["seconds"] for m in sample),
                "meanActualCandidates": statistics.mean(m["actualCandidates"] for m in sample),
                "meanRetrievalMilliseconds": statistics.mean(m["retrievalMilliseconds"] for m in sample),
            })
    current, peak = memory_bytes()
    result = {
        "sampleCaseIds": selected_ids,
        "note": "Three warm CPU samples, not a mobile or ONNX-embedding latency benchmark.",
        "modelLoadSeconds": encoder.load_seconds,
        "threads": args.threads,
        "memory": {**encoder.memory, "endWorkingSetBytes": current, "peakWorkingSetBytes": peak},
        "summary": summary,
        "measurements": measurements,
        "finishedUnixTime": time.time(),
    }
    (HERE / "latency_samples.json").write_text(json.dumps(result, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
