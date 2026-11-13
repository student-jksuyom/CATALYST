"""Train or independently evaluate the abstention head using reviewer labels only."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
from typing import Any

from openpyxl import load_workbook

import train_abstention_model as experiment


ROOT = Path(__file__).resolve().parents[2]
DEV_DATASET = ROOT / "DATA" / "Datasets" / "Abstention_Development_Review_Set.xlsx"
EVAL_DATASET = ROOT / "DATA" / "Datasets" / "Abstention_Independent_Evaluation_Set.xlsx"
REVIEWED_MODEL_PATH = (
    ROOT / "tool" / "retrieval_lab" / "abstention_model_reviewed.json"
)
DEV_REPORT_PATH = (
    ROOT / "tool" / "retrieval_lab" / "abstention_dev_reviewed_cv.json"
)
EVAL_REPORT_PATH = (
    ROOT / "tool" / "retrieval_lab" / "abstention_independent_reviewed_eval.json"
)
RELEVANCE_LABELS = {
    "HAS_RELEVANT_ARTICLE": "IN_SCOPE",
    "NO_RELEVANT_ARTICLE": "OUT_OF_SCOPE",
    "UNCERTAIN": None,
}
_ARTICLE_ID_PATTERN = re.compile(r"[^a-z0-9]")


def _article_id(value: str) -> str:
    return _ARTICLE_ID_PATTERN.sub("", value.casefold())


def _read_corpus_ids() -> set[str]:
    path = ROOT / "assets" / "data" / "legal_articles.json"
    articles = json.loads(path.read_text(encoding="utf-8"))
    return {
        _article_id(f"{article['Law']}:{article['Article']}")
        for article in articles
    }


def _read_reviewed_cases(path: Path) -> tuple[list[dict[str, str]], int]:
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
            "Issue_Family",
            "Challenge_Type",
            "Reviewer_Relevance_Label",
            "Reviewer_Relevant_Article_IDs",
            "Reviewer_Relevance_Rationale",
            "Reviewer_Applicability_Judgment",
            "Reviewer_Applicability_Rationale",
            "Reviewer_Confidence",
            "Review_Date",
            "Reviewer_Name_or_Role",
            "Review_Status",
        }
        missing = sorted(required - set(headers))
        if missing:
            raise ValueError(f"{path.name} is missing review columns: {missing}")
        columns = {name: headers.index(name) for name in required}
        corpus_ids = _read_corpus_ids()
        cases = []
        seen_ids = set()
        uncertain_count = 0
        pending = []

        for row_number, row in enumerate(rows, start=2):
            case = {
                name: row[index]
                for name, index in columns.items()
            }
            case_id = str(case["Case_ID"] or "").strip()
            if not case_id or case_id in seen_ids:
                raise ValueError(f"Row {row_number} has an empty or duplicate Case_ID.")
            seen_ids.add(case_id)
            if case["Review_Status"] != "REVIEWED":
                pending.append(case_id)
                continue
            required_review_fields = (
                "Reviewer_Relevance_Rationale",
                "Reviewer_Applicability_Judgment",
                "Reviewer_Applicability_Rationale",
                "Reviewer_Confidence",
                "Review_Date",
                "Reviewer_Name_or_Role",
            )
            if any(not str(case[field] or "").strip() for field in required_review_fields):
                raise ValueError(
                    f"{case_id} is marked REVIEWED but has incomplete reviewer fields."
                )
            label = str(case["Reviewer_Relevance_Label"] or "").strip()
            if label not in RELEVANCE_LABELS:
                raise ValueError(f"{case_id} has an invalid reviewer relevance label.")
            article_value = str(case["Reviewer_Relevant_Article_IDs"] or "").strip()
            article_ids = (
                [value.strip() for value in article_value.split(",") if value.strip()]
                if article_value
                else []
            )
            if label == "HAS_RELEVANT_ARTICLE" and not article_ids:
                raise ValueError(f"{case_id} needs at least one relevant article ID.")
            if label == "NO_RELEVANT_ARTICLE" and article_ids:
                raise ValueError(
                    f"{case_id} is labeled NO_RELEVANT_ARTICLE but lists article IDs."
                )
            unknown_ids = [
                value for value in article_ids if _article_id(value) not in corpus_ids
            ]
            if unknown_ids:
                raise ValueError(
                    f"{case_id} references article IDs outside the corpus: {unknown_ids}"
                )
            confidence = float(case["Reviewer_Confidence"])
            if confidence < 1 or confidence > 5:
                raise ValueError(f"{case_id} reviewer confidence must be from 1 to 5.")
            if label == "UNCERTAIN":
                uncertain_count += 1
                continue
            scope_label = RELEVANCE_LABELS[label]
            cases.append(
                {
                    "Case_ID": case_id,
                    "Narrative": str(case["Narrative"] or "").strip(),
                    "Language": str(case["Language"] or "").strip(),
                    "Issue_Family": str(case["Issue_Family"] or "").strip(),
                    "Challenge_Type": str(case["Challenge_Type"] or "").strip(),
                    "Scope_Label": scope_label,
                }
            )
        if pending:
            preview = ", ".join(pending[:5])
            raise ValueError(
                f"{len(pending)} cases are not legally reviewed in {path.name} "
                f"(for example: {preview})."
            )
    finally:
        workbook.close()

    if not cases:
        raise ValueError(f"{path.name} has no decisive reviewed labels.")
    return cases, uncertain_count


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _train(dataset: Path, model_output: Path, report_output: Path) -> None:
    cases, uncertain_count = _read_reviewed_cases(dataset)
    features = experiment._encode_cases(cases)
    targets = [
        experiment.LABEL_TO_TARGET[case["Scope_Label"]]
        for case in cases
    ]
    all_indexes = experiment.np.arange(len(cases), dtype=experiment.np.int64)
    out_of_fold = experiment.np.full(len(cases), experiment.np.nan)
    outer_folds = experiment._group_folds(
        cases,
        all_indexes,
        experiment.FOLD_COUNT,
        experiment.SEED,
    )
    selected_l2_by_fold: dict[str, float] = {}
    for fold_number, (train, test) in enumerate(outer_folds):
        l2, _ = experiment._select_l2(
            features,
            experiment.np.asarray(targets),
            cases,
            train,
            fold_count=3,
            seed=experiment.SEED + fold_number + 1,
        )
        weights = experiment._fit_logistic(
            features[train],
            experiment.np.asarray(targets)[train],
            l2,
        )
        out_of_fold[test] = experiment._probabilities(features[test], weights)
        selected_l2_by_fold[str(fold_number)] = l2

    final_l2, selection_losses = experiment._select_l2(
        features,
        experiment.np.asarray(targets),
        cases,
        all_indexes,
        fold_count=experiment.FOLD_COUNT,
        seed=experiment.SEED,
    )
    final_weights = experiment._fit_logistic(
        features,
        experiment.np.asarray(targets),
        final_l2,
    )
    dataset_hash = _sha256(dataset)
    family_names = sorted({case["Issue_Family"] for case in cases})
    report = {
        "status": "REVIEWER_MARKED_LABELS_NOT_INDEPENDENT_VALIDATION",
        "productionIntegrated": False,
        "heldoutWorkbookUsed": False,
        "labelsReadFrom": "Reviewer_Relevance_Label",
        "candidateLabelsUsed": False,
        "dataset": dataset.relative_to(ROOT).as_posix(),
        "datasetSha256": dataset_hash,
        "reviewedCaseCount": len(cases),
        "uncertainCasesExcluded": uncertain_count,
        "issueFamilyCount": len(family_names),
        "groupedOutOfFoldMetrics": experiment._metrics(
            cases,
            experiment.np.asarray(targets),
            out_of_fold,
        ),
        "outerFoldSelectedL2": selected_l2_by_fold,
        "finalModelL2": final_l2,
        "finalModelSelectionLogLoss": selection_losses,
        "reviewerCredentialsIndependentlyVerified": False,
        "independentEvaluationRequired": True,
    }
    model = {
        "formatVersion": 1,
        "modelType": "frozen_e5_logistic_scope_head",
        "status": "REVIEWER_MARKED_NOT_FOR_PRODUCTION",
        "productionIntegrated": False,
        "heldoutWorkbookUsed": False,
        "encoderRetrained": False,
        "encoder": "assets/models/catalyst_encoder_e5.onnx",
        "tokenizer": "assets/models/e5_tokenizer.json",
        "dimensions": experiment.DIMENSIONS,
        "queryPrefix": "query: ",
        "decisionThreshold": experiment.PROBABILITY_THRESHOLD,
        "l2": final_l2,
        "intercept": float(final_weights[-1]),
        "weights": final_weights[:-1].tolist(),
        "trainingDataset": dataset.relative_to(ROOT).as_posix(),
        "trainingDatasetSha256": dataset_hash,
        "trainingIssueFamilies": family_names,
        "trainingCaseCount": len(cases),
        "labelSource": "Reviewer_Relevance_Label",
        "reviewerCredentialsIndependentlyVerified": False,
        "independentEvaluationRequired": True,
    }
    model_output.write_text(
        json.dumps(model, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    report_output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report["groupedOutOfFoldMetrics"], indent=2))
    print(f"Model: {model_output.relative_to(ROOT)}")
    print(f"Development report: {report_output.relative_to(ROOT)}")


def _evaluate(model_path: Path, dataset: Path, report_output: Path) -> None:
    model = json.loads(model_path.read_text(encoding="utf-8"))
    if model.get("productionIntegrated") is not False:
        raise ValueError("This workflow only accepts a separately stored model.")
    if model.get("heldoutWorkbookUsed") is not False:
        raise ValueError("The model must not be trained with the held-out workbook.")
    if model.get("dimensions") != experiment.DIMENSIONS:
        raise ValueError("The model embedding dimensions do not match the encoder.")
    if not model.get("trainingIssueFamilies"):
        raise ValueError("The model is missing training issue-family provenance.")
    cases, uncertain_count = _read_reviewed_cases(dataset)
    if model.get("trainingDatasetSha256") == _sha256(dataset):
        raise ValueError("The evaluation workbook is the model's training workbook.")
    training_families = set(model.get("trainingIssueFamilies", []))
    evaluation_families = {case["Issue_Family"] for case in cases}
    overlap = training_families & evaluation_families
    if overlap:
        raise ValueError(
            f"Evaluation issue families overlap training: {sorted(overlap)}"
        )

    features = experiment._encode_cases(cases)
    weights = experiment.np.asarray(
        [*model["weights"], model["intercept"]],
        dtype=experiment.np.float64,
    )
    if weights.shape != (experiment.DIMENSIONS + 1,):
        raise ValueError("The model weight vector has an invalid length.")
    targets = experiment.np.asarray(
        [
            experiment.LABEL_TO_TARGET[case["Scope_Label"]]
            for case in cases
        ],
        dtype=experiment.np.float64,
    )
    probabilities = experiment._probabilities(features, weights)
    report = {
        "status": "INDEPENDENT_REVIEWED_EVALUATION",
        "productionIntegrated": False,
        "heldoutWorkbookUsed": False,
        "model": model_path.relative_to(ROOT).as_posix(),
        "modelDatasetSha256": model.get("trainingDatasetSha256"),
        "evaluationDataset": dataset.relative_to(ROOT).as_posix(),
        "evaluationDatasetSha256": _sha256(dataset),
        "trainingAndEvaluationIssueFamiliesOverlap": False,
        "reviewedCaseCount": len(cases),
        "uncertainCasesExcluded": uncertain_count,
        "labelsReadFrom": "Reviewer_Relevance_Label",
        "candidateLabelsUsed": False,
        "reviewerCredentialsIndependentlyVerified": False,
        "metrics": experiment._metrics(cases, targets, probabilities),
        "predictions": [
            {
                "caseId": case["Case_ID"],
                "issueFamily": case["Issue_Family"],
                "language": case["Language"],
                "expected": case["Scope_Label"],
                "predicted": (
                    "IN_SCOPE"
                    if probabilities[index] >= model["decisionThreshold"]
                    else "OUT_OF_SCOPE"
                ),
                "inScopeProbability": float(probabilities[index]),
            }
            for index, case in enumerate(cases)
        ],
    }
    report_output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(report["metrics"], indent=2))
    print(f"Independent evaluation report: {report_output.relative_to(ROOT)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    train_parser = subparsers.add_parser("train")
    train_parser.add_argument("--dataset", type=Path, default=DEV_DATASET)
    train_parser.add_argument("--model-output", type=Path, default=REVIEWED_MODEL_PATH)
    train_parser.add_argument("--report-output", type=Path, default=DEV_REPORT_PATH)
    evaluate_parser = subparsers.add_parser("evaluate")
    evaluate_parser.add_argument("--model", type=Path, required=True)
    evaluate_parser.add_argument("--dataset", type=Path, default=EVAL_DATASET)
    evaluate_parser.add_argument("--report-output", type=Path, default=EVAL_REPORT_PATH)
    args = parser.parse_args()
    if args.command == "train":
        _train(args.dataset, args.model_output, args.report_output)
    else:
        _evaluate(args.model, args.dataset, args.report_output)


if __name__ == "__main__":
    main()
