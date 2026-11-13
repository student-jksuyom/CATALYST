"""Train and evaluate a separate provisional E5-based scope classifier."""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

import numpy as np
import onnxruntime as ort
from openpyxl import load_workbook
from tokenizers import Tokenizer


ROOT = Path(__file__).resolve().parents[2]
DATASET_PATH = ROOT / "DATA" / "Datasets" / "Abstention_Development_Dataset.xlsx"
MODEL_PATH = ROOT / "assets" / "models" / "catalyst_encoder_e5.onnx"
TOKENIZER_PATH = ROOT / "assets" / "models" / "e5_tokenizer.json"
OUTPUT_MODEL_PATH = ROOT / "tool" / "retrieval_lab" / "abstention_model_provisional.json"
OUTPUT_REPORT_PATH = (
    ROOT / "tool" / "retrieval_lab" / "abstention_evaluation_provisional.json"
)

DIMENSIONS = 384
MAX_LENGTH = 128
FOLD_COUNT = 4
SEED = 20261112
PROBABILITY_THRESHOLD = 0.5
L2_CANDIDATES = (0.01, 0.1, 1.0, 10.0)
ITERATIONS = 3000
LEARNING_RATE = 0.5
LABEL_TO_TARGET = {"OUT_OF_SCOPE": 0.0, "IN_SCOPE": 1.0}

_WORD_PATTERN = re.compile(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*")
_INFORMAL_SPELLINGS = {
    "di": "hindi",
    "ndi": "hindi",
    "nde": "hindi",
    "hnd": "hindi",
    "wla": "wala",
    "walang": "wala",
    "sya": "siya",
    "nya": "niya",
    "pano": "paano",
    "pls": "please",
    "tlga": "talaga",
    "kc": "kasi",
    "kse": "kasi",
    "nirereturn": "nirere-return",
}


def _read_dataset(path: Path) -> list[dict[str, str]]:
    workbook = load_workbook(path, read_only=True, data_only=True)
    try:
        worksheet = workbook["Cases"]
        rows = worksheet.iter_rows(values_only=True)
        headers = [
            str(value).strip() if value is not None else "" for value in next(rows)
        ]
        required = {
            "Case_ID",
            "Narrative",
            "Language",
            "Scope_Label",
            "Issue_Family",
            "Challenge_Type",
            "Label_Status",
        }
        missing = sorted(required - set(headers))
        if missing:
            raise ValueError(f"Development workbook is missing columns: {missing}")
        column = {name: headers.index(name) for name in required}
        cases = []
        seen_ids = set()
        for row_number, row in enumerate(rows, start=2):
            case = {
                name: str(row[index]).strip() if row[index] is not None else ""
                for name, index in column.items()
            }
            if not case["Case_ID"] or case["Case_ID"] in seen_ids:
                raise ValueError(f"Row {row_number} has an empty or duplicate Case_ID.")
            if not case["Narrative"]:
                raise ValueError(f"Row {row_number} has no narrative.")
            if case["Scope_Label"] not in LABEL_TO_TARGET:
                raise ValueError(f"Row {row_number} has an invalid Scope_Label.")
            if case["Language"] not in {"English", "Tagalog", "Taglish"}:
                raise ValueError(f"Row {row_number} has an unsupported language.")
            if case["Label_Status"] != "PROVISIONAL_SYNTHETIC":
                raise ValueError(
                    f"Row {row_number} is not marked PROVISIONAL_SYNTHETIC."
                )
            seen_ids.add(case["Case_ID"])
            cases.append(case)
    finally:
        workbook.close()

    labels_by_group: dict[str, set[str]] = {}
    languages_by_group: dict[str, set[str]] = {}
    for case in cases:
        labels_by_group.setdefault(case["Issue_Family"], set()).add(
            case["Scope_Label"]
        )
        languages_by_group.setdefault(case["Issue_Family"], set()).add(
            case["Language"]
        )
    if any(len(labels) != 1 for labels in labels_by_group.values()):
        raise ValueError("An Issue_Family has conflicting scope labels.")
    if any(
        languages != {"English", "Tagalog", "Taglish"}
        for languages in languages_by_group.values()
    ):
        raise ValueError("Every Issue_Family must include all three languages.")
    if not cases:
        raise ValueError("The development workbook contains no cases.")
    return cases


def _normalize_query(text: str) -> str:
    collapsed = re.sub(r"\s+", " ", text)
    collapsed = re.sub(
        r"([A-Za-z])\1{2,}",
        lambda match: match.group(1),
        collapsed,
    ).strip()

    def replace(match: re.Match[str]) -> str:
        word = match.group(0)
        replacement = _INFORMAL_SPELLINGS.get(word.casefold())
        return word if replacement is None or "-" in replacement else replacement

    return _WORD_PATTERN.sub(replace, collapsed)


def _encode_cases(cases: list[dict[str, str]]) -> np.ndarray:
    tokenizer = Tokenizer.from_file(str(TOKENIZER_PATH))
    tokenizer.enable_truncation(max_length=MAX_LENGTH)
    session = ort.InferenceSession(
        str(MODEL_PATH),
        providers=["CPUExecutionProvider"],
    )
    input_names = {item.name for item in session.get_inputs()}
    vectors = []

    for case in cases:
        encoded = tokenizer.encode(f"query: {_normalize_query(case['Narrative'])}")
        input_ids = np.asarray([encoded.ids], dtype=np.int64)
        attention_mask = np.asarray([encoded.attention_mask], dtype=np.int64)
        inputs = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }
        if "token_type_ids" in input_names:
            inputs["token_type_ids"] = np.zeros_like(input_ids)
        vector = np.asarray(session.run(None, inputs)[0][0], dtype=np.float64)
        norm = float(np.linalg.norm(vector))
        if vector.shape != (DIMENSIONS,) or not math.isfinite(norm) or norm == 0:
            raise ValueError(
                f"Encoder returned an invalid embedding for {case['Case_ID']}."
            )
        vectors.append(vector / norm)
    return np.asarray(vectors, dtype=np.float64)


def _sigmoid(logits: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(logits, -40, 40)))


def _fit_logistic(features: np.ndarray, targets: np.ndarray, l2: float) -> np.ndarray:
    design = np.column_stack((features, np.ones(len(features))))
    weights = np.zeros(design.shape[1], dtype=np.float64)
    penalty = np.ones_like(weights)
    penalty[-1] = 0.0
    learning_rate = LEARNING_RATE / (1 + l2)
    for _ in range(ITERATIONS):
        probabilities = _sigmoid(design @ weights)
        gradient = design.T @ (probabilities - targets) / len(targets)
        gradient += l2 * penalty * weights
        weights -= learning_rate * gradient
    if not np.all(np.isfinite(weights)):
        raise ValueError("Classifier training produced non-finite weights.")
    return weights


def _probabilities(features: np.ndarray, weights: np.ndarray) -> np.ndarray:
    design = np.column_stack((features, np.ones(len(features))))
    return _sigmoid(design @ weights)


def _group_folds(
    cases: list[dict[str, str]],
    indexes: np.ndarray,
    fold_count: int,
    seed: int,
) -> list[tuple[np.ndarray, np.ndarray]]:
    groups_by_label: dict[str, list[str]] = {"IN_SCOPE": [], "OUT_OF_SCOPE": []}
    for index in indexes:
        group = cases[int(index)]["Issue_Family"]
        label = cases[int(index)]["Scope_Label"]
        if group not in groups_by_label[label]:
            groups_by_label[label].append(group)
    if min(map(len, groups_by_label.values())) < fold_count:
        raise ValueError("Not enough distinct issue families for grouped folds.")

    random = np.random.default_rng(seed)
    group_fold: dict[str, int] = {}
    for label, groups in groups_by_label.items():
        ordered = [groups[i] for i in random.permutation(len(groups))]
        for position, group in enumerate(ordered):
            group_fold[group] = position % fold_count

    folds = []
    for fold in range(fold_count):
        test = np.asarray(
            [
                index
                for index in indexes
                if group_fold[cases[int(index)]["Issue_Family"]] == fold
            ],
            dtype=np.int64,
        )
        test_indexes = set(test.tolist())
        train = np.asarray(
            [index for index in indexes if index not in test_indexes],
            dtype=np.int64,
        )
        folds.append((train, test))
    return folds


def _log_loss(targets: np.ndarray, probabilities: np.ndarray) -> float:
    clipped = np.clip(probabilities, 1e-12, 1 - 1e-12)
    return float(
        -np.mean(targets * np.log(clipped) + (1 - targets) * np.log(1 - clipped))
    )


def _select_l2(
    features: np.ndarray,
    targets: np.ndarray,
    cases: list[dict[str, str]],
    indexes: np.ndarray,
    fold_count: int,
    seed: int,
) -> tuple[float, dict[str, float]]:
    fold_metrics: dict[float, list[float]] = {
        candidate: [] for candidate in L2_CANDIDATES
    }
    for train, validation in _group_folds(cases, indexes, fold_count, seed):
        for candidate in L2_CANDIDATES:
            weights = _fit_logistic(features[train], targets[train], candidate)
            fold_metrics[candidate].append(
                _log_loss(
                    targets[validation],
                    _probabilities(features[validation], weights),
                )
            )
    mean_losses = {
        candidate: float(np.mean(losses))
        for candidate, losses in fold_metrics.items()
    }
    selected = min(L2_CANDIDATES, key=lambda candidate: mean_losses[candidate])
    return selected, {str(key): value for key, value in mean_losses.items()}


def _rate(numerator: int, denominator: int) -> float | None:
    return numerator / denominator if denominator else None


def _metrics(
    cases: list[dict[str, str]],
    targets: np.ndarray,
    probabilities: np.ndarray,
) -> dict[str, Any]:
    predicted_in_scope = probabilities >= PROBABILITY_THRESHOLD
    in_scope = targets == 1
    out_of_scope = ~in_scope
    false_abstentions = int(np.sum(in_scope & ~predicted_in_scope))
    missed_abstentions = int(np.sum(out_of_scope & predicted_in_scope))
    metrics: dict[str, Any] = {
        "threshold": PROBABILITY_THRESHOLD,
        "inScopeCount": int(np.sum(in_scope)),
        "outOfScopeCount": int(np.sum(out_of_scope)),
        "falseAbstentions": false_abstentions,
        "falseAbstentionRate": _rate(false_abstentions, int(np.sum(in_scope))),
        "missedAbstentions": missed_abstentions,
        "missedAbstentionRate": _rate(missed_abstentions, int(np.sum(out_of_scope))),
        "accuracy": float(np.mean(predicted_in_scope == in_scope)),
        "balancedAccuracy": float(
            (
                1
                - _rate(false_abstentions, int(np.sum(in_scope)))
                + 1
                - _rate(missed_abstentions, int(np.sum(out_of_scope)))
            )
            / 2
        ),
    }

    per_language: dict[str, Any] = {}
    for language in ("English", "Tagalog", "Taglish"):
        selected = np.asarray(
            [case["Language"] == language for case in cases], dtype=bool
        )
        local_in = int(np.sum(in_scope & selected))
        local_out = int(np.sum(out_of_scope & selected))
        local_false = int(np.sum(in_scope & selected & ~predicted_in_scope))
        local_missed = int(np.sum(out_of_scope & selected & predicted_in_scope))
        per_language[language] = {
            "inScopeCount": local_in,
            "falseAbstentions": local_false,
            "falseAbstentionRate": _rate(local_false, local_in),
            "outOfScopeCount": local_out,
            "missedAbstentions": local_missed,
            "missedAbstentionRate": _rate(local_missed, local_out),
        }
    metrics["byLanguage"] = per_language

    challenge_results: dict[str, Any] = {}
    for challenge in sorted({case["Challenge_Type"] for case in cases}):
        selected = np.asarray(
            [case["Challenge_Type"] == challenge for case in cases], dtype=bool
        )
        local_in = int(np.sum(in_scope & selected))
        local_out = int(np.sum(out_of_scope & selected))
        local_false = int(np.sum(in_scope & selected & ~predicted_in_scope))
        local_missed = int(np.sum(out_of_scope & selected & predicted_in_scope))
        challenge_results[challenge] = {
            "inScopeCount": local_in,
            "falseAbstentions": local_false,
            "falseAbstentionRate": _rate(local_false, local_in),
            "outOfScopeCount": local_out,
            "missedAbstentions": local_missed,
            "missedAbstentionRate": _rate(local_missed, local_out),
        }
    metrics["byChallengeType"] = challenge_results
    return metrics


def _dataset_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def train_and_evaluate() -> None:
    cases = _read_dataset(DATASET_PATH)
    features = _encode_cases(cases)
    targets = np.asarray(
        [LABEL_TO_TARGET[case["Scope_Label"]] for case in cases],
        dtype=np.float64,
    )
    all_indexes = np.arange(len(cases), dtype=np.int64)

    out_of_fold = np.full(len(cases), np.nan, dtype=np.float64)
    outer_l2: dict[str, float] = {}
    outer_inner_losses: dict[str, dict[str, float]] = {}
    outer_folds = _group_folds(cases, all_indexes, FOLD_COUNT, SEED)
    for fold_number, (train, test) in enumerate(outer_folds):
        selected_l2, inner_losses = _select_l2(
            features,
            targets,
            cases,
            train,
            fold_count=3,
            seed=SEED + fold_number + 1,
        )
        weights = _fit_logistic(features[train], targets[train], selected_l2)
        out_of_fold[test] = _probabilities(features[test], weights)
        outer_l2[str(fold_number)] = selected_l2
        outer_inner_losses[str(fold_number)] = inner_losses
    if not np.all(np.isfinite(out_of_fold)):
        raise ValueError("Grouped cross-validation did not predict every case.")

    final_l2, final_cv_losses = _select_l2(
        features,
        targets,
        cases,
        all_indexes,
        fold_count=FOLD_COUNT,
        seed=SEED,
    )
    final_weights = _fit_logistic(features, targets, final_l2)
    dataset_hash = _dataset_sha256(DATASET_PATH)
    evaluation = {
        "status": "PROVISIONAL_SYNTHETIC_LABELS",
        "productionIntegrated": False,
        "heldoutWorkbookUsed": False,
        "encoderRetrained": False,
        "protocol": (
            "Nested grouped cross-validation. All English, Tagalog, and Taglish "
            "variants from an Issue_Family stay in the same outer fold. The "
            "0.5 decision threshold is fixed before evaluation."
        ),
        "dataset": DATASET_PATH.relative_to(ROOT).as_posix(),
        "datasetSha256": dataset_hash,
        "caseCount": len(cases),
        "issueFamilyCount": len({case["Issue_Family"] for case in cases}),
        "outerFoldCount": FOLD_COUNT,
        "outOfFoldMetrics": _metrics(cases, targets, out_of_fold),
        "outerFoldSelectedL2": outer_l2,
        "innerFoldLogLossByOuterFold": outer_inner_losses,
        "finalModelL2": final_l2,
        "finalModelSelectionLogLoss": final_cv_losses,
        "predictions": [
            {
                "caseId": case["Case_ID"],
                "issueFamily": case["Issue_Family"],
                "language": case["Language"],
                "challengeType": case["Challenge_Type"],
                "expected": case["Scope_Label"],
                "predicted": (
                    "IN_SCOPE"
                    if out_of_fold[index] >= PROBABILITY_THRESHOLD
                    else "OUT_OF_SCOPE"
                ),
                "inScopeProbability": float(out_of_fold[index]),
                "outerFold": next(
                    str(fold)
                    for fold, (_, test) in enumerate(outer_folds)
                    if index in test
                ),
            }
            for index, case in enumerate(cases)
        ],
        "limitations": [
            "All scope labels are synthetic and unverified; rates are not estimates of real-world legal accuracy.",
            "Small development set; grouped cross-validation reduces language-variant leakage but does not establish generalization to all legal topics.",
            "The classifier is a separate experiment and is not connected to production retrieval or result suppression.",
        ],
    }
    model = {
        "formatVersion": 1,
        "modelType": "frozen_e5_logistic_scope_head",
        "status": "PROVISIONAL_NOT_FOR_PRODUCTION",
        "productionIntegrated": False,
        "heldoutWorkbookUsed": False,
        "encoderRetrained": False,
        "encoder": "assets/models/catalyst_encoder_e5.onnx",
        "tokenizer": "assets/models/e5_tokenizer.json",
        "dimensions": DIMENSIONS,
        "queryPrefix": "query: ",
        "decisionThreshold": PROBABILITY_THRESHOLD,
        "l2": final_l2,
        "intercept": float(final_weights[-1]),
        "weights": final_weights[:-1].tolist(),
        "trainingDataset": DATASET_PATH.relative_to(ROOT).as_posix(),
        "trainingDatasetSha256": dataset_hash,
        "trainingCaseCount": len(cases),
        "trainingIssueFamilies": sorted(
            {case["Issue_Family"] for case in cases}
        ),
        "labelStatus": "PROVISIONAL_SYNTHETIC_UNVERIFIED",
        "legalReviewRequired": True,
    }
    OUTPUT_MODEL_PATH.write_text(
        json.dumps(model, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    OUTPUT_REPORT_PATH.write_text(
        json.dumps(evaluation, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(evaluation["outOfFoldMetrics"], ensure_ascii=False, indent=2))
    print(f"Model: {OUTPUT_MODEL_PATH.relative_to(ROOT)}")
    print(f"Evaluation: {OUTPUT_REPORT_PATH.relative_to(ROOT)}")


if __name__ == "__main__":
    train_and_evaluate()
