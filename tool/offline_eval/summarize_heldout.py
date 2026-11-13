"""Summarize and regression-check the independent held-out retrieval run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


POSITIVE_METRICS = ("hit1", "hit3", "hit15", "mrr15")
MAX_NO_MATCH_FALSE_POSITIVES = 0


def _positive_metrics(cases: list[dict[str, Any]]) -> dict[str, Any]:
    if not cases:
        return {
            "count": 0,
            "hit1": 0,
            "hit3": 0,
            "hit15": 0,
            "mrr15": 0.0,
        }
    return {
        "count": len(cases),
        "hit1": sum(case["hit1"] for case in cases),
        "hit3": sum(case["hit3"] for case in cases),
        "hit15": sum(case["hit15"] for case in cases),
        "mrr15": sum(case["reciprocalRank"] or 0.0 for case in cases) / len(cases),
    }


def summarize(report_path: Path) -> dict[str, Any]:
    report = json.loads(report_path.read_text(encoding="utf-8"))
    cases = [
        case
        for case in report
        if case["strategy"] == "hybrid" and case["mode"] == "baseline"
    ]
    if not cases:
        raise ValueError("The report contains no production hybrid held-out results.")
    ids = [str(case["datasetId"]) for case in cases]
    if len(set(ids)) != len(ids):
        raise ValueError("The report contains duplicate held-out case results.")
    dataset_hashes = {case["datasetHash"] for case in cases}
    if len(dataset_hashes) != 1:
        raise ValueError("The report combines multiple dataset versions.")

    positive = [case for case in cases if case["relevant"]]
    no_match = [case for case in cases if case["noCatalogueMatch"]]
    confirmed_negative_labels = sum(
        len(case["confirmedIrrelevantArticleIds"]) for case in cases
    )
    confirmed_negative_hits_at_3 = sum(
        article_id in case["all"][:3]
        for case in cases
        for article_id in case["confirmedIrrelevantArticleIds"]
    )
    confirmed_negative_hits_at_15 = sum(
        article_id in case["all"][:15]
        for case in cases
        for article_id in case["confirmedIrrelevantArticleIds"]
    )

    def positive_group(group: list[dict[str, Any]]) -> dict[str, Any]:
        return _positive_metrics([case for case in group if case["relevant"]])

    cohorts: dict[str, Any] = {}
    for field in ("language", "domain"):
        values = sorted(
            {
                str(case[field])
                for case in cases
                if field != "domain" or case["relevant"]
            }
        )
        cohorts[field] = {
            value: positive_group(
                [
                    case
                    for case in cases
                    if case["relevant"] and str(case[field]) == value
                ]
            )
            for value in values
        }

    review_statuses = sorted({str(case["reviewStatus"]) for case in cases})
    applicability = {
        value: sum(case["applicabilityJudgment"] == value for case in cases)
        for value in sorted({str(case["applicabilityJudgment"]) for case in cases})
    }
    return {
        "datasetHash": next(iter(dataset_hashes)),
        "caseIds": sorted(ids),
        "provisional": any(status != "REVIEWED" for status in review_statuses),
        "reviewStatuses": review_statuses,
        "counts": {
            "total": len(cases),
            "retrievalPositive": len(positive),
            "noCatalogueMatch": len(no_match),
            "confirmedNegativeArticleLabels": confirmed_negative_labels,
            "applicabilityJudgments": applicability,
        },
        "retrieval": _positive_metrics(positive),
        "noCatalogueMatch": {
            "count": len(no_match),
            "falsePositiveCases": sum(case["falsePositiveNoMatch"] for case in no_match),
            "returnedAnyRate": (
                sum(case["falsePositiveNoMatch"] for case in no_match) / len(no_match)
                if no_match
                else 0.0
            ),
            "maximumAllowedFalsePositiveCases": MAX_NO_MATCH_FALSE_POSITIVES,
        },
        "confirmedNegatives": {
            "labels": confirmed_negative_labels,
            "retrievedAt3": confirmed_negative_hits_at_3,
            "retrievedAt15": confirmed_negative_hits_at_15,
        },
        "cohorts": cohorts,
        "note": (
            "Precision is not reported: unjudged articles are not treated as "
            "irrelevant. Unverified Hard_Negative_Article_IDs are excluded."
        ),
    }


def _check_not_regressed(current: dict[str, Any], baseline: dict[str, Any]) -> list[str]:
    failures = []
    if current["datasetHash"] != baseline["datasetHash"]:
        failures.append("dataset hash changed; establish a deliberately reviewed baseline")
    if current["caseIds"] != baseline["caseIds"]:
        failures.append("case IDs changed")
    if current["counts"] != baseline["counts"]:
        failures.append("label counts changed")

    for metric in POSITIVE_METRICS:
        if current["retrieval"][metric] + 1e-12 < baseline["retrieval"][metric]:
            failures.append(f"retrieval {metric} regressed")
    if (
        current["noCatalogueMatch"]["falsePositiveCases"]
        > baseline["noCatalogueMatch"]["falsePositiveCases"]
    ):
        failures.append("out-of-catalogue false-positive cases increased")
    if (
        current["noCatalogueMatch"]["falsePositiveCases"]
        > MAX_NO_MATCH_FALSE_POSITIVES
    ):
        failures.append(
            "out-of-catalogue false-positive cases exceed the allowed maximum "
            f"({MAX_NO_MATCH_FALSE_POSITIVES})"
        )
    for metric in ("retrievedAt3", "retrievedAt15"):
        if (
            current["confirmedNegatives"][metric]
            > baseline["confirmedNegatives"][metric]
        ):
            failures.append(f"confirmed negative-article hits increased: {metric}")

    for field in ("language", "domain"):
        current_groups = current["cohorts"][field]
        baseline_groups = baseline["cohorts"][field]
        if current_groups.keys() != baseline_groups.keys():
            failures.append(f"{field} cohorts changed")
            continue
        for group, metrics in current_groups.items():
            for metric in POSITIVE_METRICS:
                if metrics[metric] + 1e-12 < baseline_groups[group][metric]:
                    failures.append(f"{field} cohort {group} regressed on {metric}")
    return failures


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--write-baseline", type=Path)
    parser.add_argument("--check-baseline", type=Path)
    parser.add_argument("--allow-provisional", action="store_true")
    args = parser.parse_args()
    if args.write_baseline and args.check_baseline:
        parser.error("Choose either --write-baseline or --check-baseline.")

    summary = summarize(args.report)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if summary["provisional"]:
        print(
            "PROVISIONAL: review status is not REVIEWED. This is a regression "
            "guard, not a final legal-quality or release-acceptance gate."
        )
        if not args.allow_provisional:
            raise SystemExit(
                "Use --allow-provisional only for the current preliminary baseline."
            )

    if args.write_baseline:
        if args.write_baseline.exists():
            raise SystemExit(
                f"Refusing to overwrite baseline: {args.write_baseline}"
            )
        args.write_baseline.parent.mkdir(parents=True, exist_ok=True)
        stored_baseline = {
            **summary,
            "qualityGateStatus": (
                "FAIL"
                if summary["noCatalogueMatch"]["falsePositiveCases"]
                > MAX_NO_MATCH_FALSE_POSITIVES
                else "PASS"
            ),
        }
        args.write_baseline.write_text(
            json.dumps(stored_baseline, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(
            f"Wrote observed baseline to {args.write_baseline}; current "
            f"quality-gate status is {stored_baseline['qualityGateStatus']}."
        )
    elif args.check_baseline:
        baseline = json.loads(args.check_baseline.read_text(encoding="utf-8"))
        if baseline.get("provisional") and not args.allow_provisional:
            raise SystemExit(
                "The saved baseline is provisional; pass --allow-provisional "
                "until a final legal review replaces it."
            )
        failures = _check_not_regressed(summary, baseline)
        if failures:
            raise SystemExit("QUALITY GATE FAILED: " + "; ".join(failures))
        print("QUALITY GATE PASSED: no measured regression from the locked baseline.")


if __name__ == "__main__":
    main()
