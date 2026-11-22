"""Grouped LTR experiment on cached production candidates.

No held-out dataset is read. Candidates and hybrid scores include the existing
training-query signal, so this is not a fully leakage-free pipeline evaluation.
"""

from __future__ import annotations

import json
import re
import time
from difflib import SequenceMatcher
from pathlib import Path

import numpy as np
from openpyxl import load_workbook
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import GroupKFold
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler

ROOT = Path(__file__).resolve().parents[4]
HERE = Path(__file__).resolve().parent
CASES = ROOT / "tool" / "retrieval_lab" / "diagnostics" / "stage1_baseline" / "cases.json"
CANDIDATES = ROOT / "tool" / "retrieval_lab" / "diagnostics" / "reranking" / "candidates.json"
TRAINING = ROOT / "DATA" / "Datasets" / "Trainingdataset.xlsx"


def terms(text: str) -> set[str]:
    return set(re.findall(r"[a-z0-9]+", text.casefold()))


def features(query: str, candidates: list[dict]) -> np.ndarray:
    query_terms = terms(query)
    rows = []
    for rank, candidate in enumerate(candidates, 1):
        document_terms = terms(candidate["text"])
        overlap = len(query_terms & document_terms)
        rows.append([
            candidate["hybridScore"],
            1.0 / rank,
            overlap / max(len(query_terms), 1),
            overlap / max(len(document_terms), 1),
        ])
    return np.asarray(rows, dtype=np.float64).reshape(-1, 4)


def summarize(records: list[dict]) -> dict:
    hit1 = hit3 = hit15 = labels3 = 0
    for item in records:
        labels = set(item["relevant"])
        ids = item["ranked"]
        hit1 += bool(labels.intersection(ids[:1]))
        hit3 += bool(labels.intersection(ids[:3]))
        hit15 += bool(labels.intersection(ids[:15]))
        labels3 += len(labels.intersection(ids[:3]))
    return {
        "queries": len(records),
        "hitAt1": hit1,
        "hitAt3": hit3,
        "hitAt15": hit15,
        "precisionAt3": labels3 / (3 * len(records)),
    }


def training_queries() -> list[str]:
    workbook = load_workbook(TRAINING, read_only=True, data_only=True)
    try:
        rows = workbook.active.iter_rows(values_only=True)
        headers = [str(value).strip() if value is not None else "" for value in next(rows)]
        column = headers.index("Sample Narrative")
        return list(dict.fromkeys(
            row[column].strip() for row in rows
            if isinstance(row[column], str) and row[column].strip()
        ))
    finally:
        workbook.close()


def main() -> None:
    metadata = json.loads(CASES.read_text(encoding="utf-8"))
    payload = json.loads(CANDIDATES.read_text(encoding="utf-8"))
    cases = payload["cases"]
    by_id = {row["datasetId"]: row for row in metadata}
    if len(cases) != 46 or set(by_id) != {row["datasetId"] for row in cases}:
        raise ValueError("Candidate export and development cases do not match.")

    domains = {row["datasetId"]: by_id[row["datasetId"]]["domain"].split("-")[0] for row in cases}
    parents = list(range(len(cases)))

    def find(index: int) -> int:
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    def union(first: int, second: int) -> None:
        parents[find(first)] = find(second)

    related = []
    for i, a in enumerate(cases):
        for j in range(i + 1, len(cases)):
            b = cases[j]
            ratio = SequenceMatcher(None, a["query"].casefold(), b["query"].casefold()).ratio()
            same_subdomain = by_id[a["datasetId"]]["domain"] == by_id[b["datasetId"]]["domain"]
            if same_subdomain or ratio >= 0.60 or set(a["relevant"]) & set(b["relevant"]):
                union(i, j)
            if ratio >= 0.60 or set(a["relevant"]) & set(b["relevant"]):
                related.append({"first": a["datasetId"], "second": b["datasetId"], "similarity": ratio})
    groups = [find(i) for i in range(len(cases))]

    train_queries = training_queries()
    nearest = []
    for case in cases:
        similarity = max(
            SequenceMatcher(None, case["query"].casefold(), query.casefold()).ratio()
            for query in train_queries
        )
        if similarity >= 0.80:
            nearest.append({"datasetId": case["datasetId"], "similarity": similarity})

    baseline = []
    for case in cases:
        candidates = case["pool50"]["candidates"]
        ids = [candidate["id"] for candidate in candidates]
        original = [candidate["id"] for candidate in case["baseline"]["candidates"]]
        if ids[:len(original)] != original:
            raise ValueError(f"Cached baseline order differs: {case['datasetId']}")
        baseline.append({"relevant": case["relevant"], "ranked": ids})
    if [summarize(baseline)[k] for k in ("hitAt1", "hitAt3", "hitAt15")] != [13, 17, 21]:
        raise ValueError("Cached candidate export does not reproduce the production baseline.")

    predictions, folds = [], []
    ranking_seconds = []
    for fold_number, (train_indices, valid_indices) in enumerate(
        GroupKFold(n_splits=5).split(cases, groups=groups), 1
    ):
        train = [cases[i] for i in train_indices]
        validation = [cases[i] for i in valid_indices]
        x_parts, y_parts, weights = [], [], []
        for row in train:
            candidates = row["pool50"]["candidates"]
            x_parts.append(features(row["query"], candidates))
            y_parts.extend(int(c["id"] in row["relevant"]) for c in candidates)
            weights.extend([1 / len(candidates)] * len(candidates))
        y = np.asarray(y_parts)
        if len(set(y)) != 2:
            raise ValueError(f"Training fold {fold_number} has no positive or negative labels.")
        model = make_pipeline(
            StandardScaler(),
            LogisticRegression(C=1.0, class_weight="balanced", max_iter=1000),
        )
        model.fit(np.vstack(x_parts), y, logisticregression__sample_weight=np.asarray(weights))

        def rank(rows: list[dict], *, measure: bool) -> list[dict]:
            output = []
            for row in rows:
                candidates = row["pool50"]["candidates"]
                started = time.perf_counter()
                scores = model.decision_function(features(row["query"], candidates))
                order = sorted(range(len(candidates)), key=lambda index: (-scores[index], index))
                if measure:
                    ranking_seconds.append(time.perf_counter() - started)
                output.append({
                    "datasetId": row["datasetId"],
                    "relevant": row["relevant"],
                    "ranked": [candidates[index]["id"] for index in order],
                })
            return output

        train_predictions = rank(train, measure=False)
        valid_predictions = rank(validation, measure=True)
        predictions.extend(valid_predictions)
        folds.append({
            "fold": fold_number,
            "validationCaseIds": [row["datasetId"] for row in validation],
            "trainingQueries": len(train),
            "trainingPositiveCandidateLabels": int(y.sum()),
            "train": summarize(train_predictions),
            "validation": summarize(valid_predictions),
            "coefficients": model.named_steps["logisticregression"].coef_[0].tolist(),
        })

    negatives = sum(bool(row["pool50"]["candidates"]) for row in payload["negatives"])
    result = {
        "protocol": "Fixed L2 logistic regression; five folds grouped by legal subdomain, shared label and near-duplicate query; scaler and weights fit only on training folds.",
        "limitations": [
            "Candidates and hybrid scores are from the existing training-query index, which is not rebuilt per fold.",
            "Unlabeled candidates are treated as negatives although relevance labels may be incomplete.",
            "A character-similarity check cannot establish absence of semantic paraphrase leakage.",
            "Only three legal domains and 46 development queries; this is not an independent held-out test.",
        ],
        "relatedDevelopmentPairs": related,
        "nearestTrainingQueryAtLeastPoint8": nearest,
        "candidateQueriesCovered": sum(bool(set(row["relevant"]) & {c["id"] for c in row["pool50"]["candidates"]}) for row in cases),
        "candidateLabelsCovered": sum(len(set(row["relevant"]) & {c["id"] for c in row["pool50"]["candidates"]}) for row in cases),
        "baseline": summarize(baseline),
        "baselineByDomain": {
            domain: summarize([
                base for base, row in zip(baseline, cases)
                if domains[row["datasetId"]] == domain
            ])
            for domain in sorted(set(domains.values()))
        },
        "outOfFold": summarize(predictions),
        "outOfFoldByDomain": {
            domain: summarize([row for row in predictions if domains[row["datasetId"]] == domain])
            for domain in sorted(set(domains.values()))
        },
        "folds": folds,
        "groupCount": len(set(groups)),
        "negativeProbesWithCandidates": negatives,
        "meanFeatureAndRankingMilliseconds": 1000 * sum(ranking_seconds) / len(ranking_seconds),
        "predictions": predictions,
    }
    (HERE / "grouped_ltr_results.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "predictions"}, indent=2))


if __name__ == "__main__":
    main()
