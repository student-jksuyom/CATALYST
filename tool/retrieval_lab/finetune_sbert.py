"""Fine-tune MiniLM SBERT with training pairs and optional reviewed judgments."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime
import json
import random
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[2]
BASE_MODEL_ID = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
OUTPUT_ROOT = PROJECT_ROOT / "tool" / "retrieval_lab" / "out" / "sbert_finetune"


def _read_rows(path: Path) -> list[dict[str, Any]]:
    from openpyxl import load_workbook

    workbook = load_workbook(path, read_only=True, data_only=True)
    worksheet = workbook.active
    iterator = worksheet.iter_rows(values_only=True)
    try:
        headers = next(iterator)
    except StopIteration:
        raise ValueError(f"Workbook is empty: {path}") from None
    names = [str(value).strip() if value is not None else "" for value in headers]
    rows = [
        {
            name: row[index] if index < len(row) else None
            for index, name in enumerate(names)
            if name
        }
        for row in iterator
        if any(value is not None for value in row)
    ]
    workbook.close()
    return rows


def _article_embedding_text(row: dict[str, Any]) -> str:
    fields = [
        f"Law: {str(row['Law']).strip()}",
        f"Article: {str(row['Article_Number']).strip()}",
    ]
    for column in ("Book", "Title", "Chapter", "Chapter Title"):
        value = row.get(column)
        if value is not None and str(value).strip():
            fields.append(f"{column}: {str(value).strip()}")
    fields.append(f"Legal provision:\n{row['Article Text']}")
    return "\n".join(fields)


def _required_columns(
    rows: list[dict[str, Any]], required: tuple[str, ...], source: Path
) -> None:
    if not rows:
        raise ValueError(f"Workbook contains no data rows: {source}")
    missing = [column for column in required if column not in rows[0]]
    if missing:
        raise ValueError(
            f"{source.name} is missing required columns: {', '.join(missing)}"
        )


def _article_references(value: Any) -> list[str]:
    return [
        item.strip().casefold()
        for item in str(value).split(",")
        if item.strip()
    ]


def _load_training_pairs(
    rows: list[dict[str, Any]], articles: dict[str, str], source: Path
) -> list[tuple[str, str, float]]:
    pairs: list[tuple[str, str, float]] = []
    for row_number, row in enumerate(rows, start=2):
        query = str(row["Sample Narrative"]).strip()
        if not query:
            raise ValueError(f"{source.name} row {row_number} has a blank narrative.")
        label = row["Relevance_Label"]
        if label not in (0, 0.0, 1, 1.0):
            raise ValueError(f"{source.name} row {row_number} has invalid label {label!r}.")
        references = _article_references(row["Applicable_Article_ID"])
        if not references:
            raise ValueError(
                f"{source.name} row {row_number} has no article references."
            )
        for article_id in references:
            if article_id not in articles:
                raise ValueError(
                    f"{source.name} row {row_number} references unknown article "
                    f"{article_id!r}."
                )
            pairs.append((query, articles[article_id], float(label)))
    return pairs


def _parse_manual_label_overrides(values: list[str]) -> dict[tuple[str, str], float]:
    overrides: dict[tuple[str, str], float] = {}
    for value in values:
        parts = value.split("|")
        if len(parts) != 3:
            raise ValueError(
                "Manual label overrides must use NARRATIVE-ID|ARTICLE-ID|0-or-1."
            )
        narrative_id, article_id, raw_label = (part.strip() for part in parts)
        if not narrative_id or not article_id or raw_label not in {"0", "1"}:
            raise ValueError(
                "Manual label overrides must use NARRATIVE-ID|ARTICLE-ID|0-or-1."
            )
        key = (narrative_id.casefold(), article_id.casefold())
        label = float(raw_label)
        if key in overrides and overrides[key] != label:
            raise ValueError(f"Conflicting manual label overrides for {value!r}.")
        overrides[key] = label
    return overrides


def _starting_model_retired_test(model_path: Path) -> bool:
    report_path = model_path.parent / "evaluation_report.json"
    if not report_path.is_file():
        return False
    report = json.loads(report_path.read_text(encoding="utf-8"))
    return bool(report.get("previous_testing_split_retired", False))


def _load_manual_review_pairs(
    path: Path,
    articles: dict[str, str],
    overrides: dict[tuple[str, str], float],
) -> tuple[list[tuple[str, str, float]], dict[str, Any]]:
    rows = _read_rows(path)
    _required_columns(
        rows,
        (
            "Narrative-ID",
            "Sample Narrative",
            "Article-ID",
            "Relevance Label",
        ),
        path,
    )
    grouped: dict[tuple[str, str], dict[str, Any]] = {}
    uncertain_rows = 0
    unlabeled_rows = 0
    for row_number, row in enumerate(rows, start=2):
        narrative_id = str(row["Narrative-ID"]).strip()
        query = str(row["Sample Narrative"]).strip()
        article_id = str(row["Article-ID"]).strip().casefold()
        raw_label = row["Relevance Label"]
        if not narrative_id or not query or not article_id:
            raise ValueError(
                f"{path.name} row {row_number} needs Narrative-ID, "
                "Sample Narrative, and Article-ID."
            )
        if article_id not in articles:
            raise ValueError(
                f"{path.name} row {row_number} references unknown article "
                f"{article_id!r}."
            )
        key = (narrative_id.casefold(), article_id)
        pair = grouped.setdefault(
            key,
            {
                "narrative_id": narrative_id,
                "query": query,
                "article_id": article_id,
                "labels": set(),
            },
        )
        if pair["query"].casefold() != query.casefold():
            raise ValueError(
                f"{path.name} uses Narrative-ID {narrative_id!r} for multiple "
                "narratives."
            )
        if raw_label is None or (
            isinstance(raw_label, str) and not raw_label.strip()
        ):
            unlabeled_rows += 1
            continue
        if isinstance(raw_label, (int, float)) and raw_label in (0, 1):
            label_text = str(int(raw_label))
        else:
            label_text = str(raw_label).strip().upper()
        if label_text in {"U", "UNCERTAIN"}:
            uncertain_rows += 1
            continue
        if label_text == "IRRELEVANT":
            label_text = "0"
        if label_text not in {"0", "1"}:
            if key in overrides:
                continue
            raise ValueError(
                f"{path.name} row {row_number} has unsupported relevance "
                f"label {raw_label!r}; use 0, 1, or U."
            )
        pair["labels"].add(float(label_text))

    unknown_overrides = set(overrides) - set(grouped)
    if unknown_overrides:
        formatted = [
            f"{narrative_id}|{article_id}"
            for narrative_id, article_id in sorted(unknown_overrides)
        ]
        raise ValueError(
            "Manual label overrides do not match a reviewed narrative/article: "
            + ", ".join(formatted)
        )

    pairs: list[tuple[str, str, float]] = []
    positive_count = 0
    negative_count = 0
    for key, pair in grouped.items():
        label_set = pair["labels"]
        if key in overrides:
            label = overrides[key]
        elif len(label_set) > 1:
            raise ValueError(
                "Conflicting manual judgments for "
                f"{pair['narrative_id']}|{pair['article_id']}; pass an explicit "
                "override with --manual-review-label-override."
            )
        elif label_set:
            label = next(iter(label_set))
        else:
            continue

        pairs.append((pair["query"], articles[pair["article_id"]], label))
        if label == 1.0:
            positive_count += 1
        else:
            negative_count += 1

    if not pairs:
        raise ValueError(f"{path.name} contains no usable 0/1 judgments.")
    return pairs, {
        "review_rows": len(rows),
        "unique_query_article_pairs": len(grouped),
        "labeled_unique_pairs": len(pairs),
        "positive_unique_pairs": positive_count,
        "negative_unique_pairs": negative_count,
        "unique_queries": len(
            {pair["query"].casefold() for pair in grouped.values()}
        ),
        "uncertain_rows_excluded": uncertain_rows,
        "unlabeled_rows_excluded": unlabeled_rows,
        "label_overrides": [
            f"{narrative_id}|{article_id}|{int(label)}"
            for (narrative_id, article_id), label in sorted(overrides.items())
        ],
    }


def _load_relevance_groups(
    rows: list[dict[str, Any]], articles: dict[str, str], source: Path
) -> list[dict[str, Any]]:
    groups: dict[str, dict[str, Any]] = {}
    for row_number, row in enumerate(rows, start=2):
        query = str(row["Sample Narrative"]).strip()
        if not query:
            raise ValueError(f"{source.name} row {row_number} has a blank narrative.")
        label = row["Relevance_Label"]
        if label not in (0, 0.0, 1, 1.0):
            raise ValueError(f"{source.name} row {row_number} has invalid label {label!r}.")
        key = query.casefold()
        group = groups.setdefault(
            key, {"query": query, "relevant": set(), "non_relevant": set()}
        )
        references = _article_references(row["Applicable_Article_ID"])
        if not references:
            raise ValueError(
                f"{source.name} row {row_number} has no article references."
            )
        destination = "relevant" if int(label) == 1 else "non_relevant"
        for article_id in references:
            if article_id not in articles:
                raise ValueError(
                    f"{source.name} row {row_number} references unknown article "
                    f"{article_id!r}."
                )
            group[destination].add(article_id)
    return list(groups.values())


def _retrieval_metrics(
    model: Any,
    groups: list[dict[str, Any]],
    article_ids: list[str],
    article_texts: list[str],
    corpus_vectors: Any | None = None,
) -> dict[str, Any]:
    import numpy as np

    queries = [group["query"] for group in groups]
    query_vectors = model.encode(
        queries,
        batch_size=32,
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=False,
    )
    query_vectors = np.asarray(query_vectors, dtype=np.float32)
    article_vectors = corpus_vectors
    if article_vectors is None:
        article_vectors = model.encode(
            article_texts,
            batch_size=32,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=True,
        )
    article_vectors = np.asarray(article_vectors, dtype=np.float32)
    if query_vectors.shape != (len(groups), 384):
        raise ValueError(f"Query embedding matrix has unexpected shape {query_vectors.shape}.")
    if article_vectors.shape != (len(article_ids), 384):
        raise ValueError(
            f"Article embedding matrix has unexpected shape {article_vectors.shape}."
        )
    if not np.isfinite(query_vectors).all() or not np.isfinite(article_vectors).all():
        raise ValueError("Query or article embeddings contain NaN or infinite values.")
    article_positions = {article_id: i for i, article_id in enumerate(article_ids)}
    positive_groups = [group for group in groups if group["relevant"]]
    hits = {1: 0, 3: 0, 5: 0, 10: 0}
    precision_sums = {1: 0.0, 3: 0.0}
    recall_sums = {1: 0.0, 3: 0.0}
    reciprocal_rank_sum = 0.0
    reciprocal_rank_sum_at_15 = 0.0
    for query_vector, group in zip(query_vectors, groups):
        scores = article_vectors @ query_vector
        ranking = np.argsort(-scores, kind="stable")
        relevant = {
            article_positions[article_id] for article_id in group["relevant"]
        }
        if not relevant:
            continue
        for cutoff in precision_sums:
            found = len(set(ranking[:cutoff]) & relevant)
            precision_sums[cutoff] += found / cutoff
            recall_sums[cutoff] += found / len(relevant)
        first_rank = next(
            (rank for rank, position in enumerate(ranking, start=1) if position in relevant),
            None,
        )
        if first_rank is not None:
            for cutoff in hits:
                hits[cutoff] += first_rank <= cutoff
            if first_rank <= 10:
                reciprocal_rank_sum += 1.0 / first_rank
            if first_rank <= 15:
                reciprocal_rank_sum_at_15 += 1.0 / first_rank

    denominator = len(positive_groups)
    metrics: dict[str, Any] = {
        "positive_query_count": denominator,
        "negative_only_query_count": len(groups) - denominator,
        "top1_accuracy": hits[1] / denominator if denominator else 0.0,
        "top3_accuracy": hits[3] / denominator if denominator else 0.0,
        "hit_at_1": hits[1] / denominator if denominator else 0.0,
        "hit_at_3": hits[3] / denominator if denominator else 0.0,
        "hit_at_5": hits[5] / denominator if denominator else 0.0,
        "hit_at_10": hits[10] / denominator if denominator else 0.0,
        "precision_at_1": precision_sums[1] / denominator if denominator else 0.0,
        "precision_at_3": precision_sums[3] / denominator if denominator else 0.0,
        "recall_at_1": recall_sums[1] / denominator if denominator else 0.0,
        "recall_at_3": recall_sums[3] / denominator if denominator else 0.0,
        "mrr_at_10": reciprocal_rank_sum / denominator if denominator else 0.0,
        "mrr_at_15": (
            reciprocal_rank_sum_at_15 / denominator if denominator else 0.0
        ),
    }

    positive_scores: list[float] = []
    negative_scores: list[float] = []
    for query_vector, group in zip(query_vectors, groups):
        scores = article_vectors @ query_vector
        positive_scores.extend(
            float(scores[article_positions[article_id]])
            for article_id in group["relevant"]
        )
        negative_scores.extend(
            float(scores[article_positions[article_id]])
            for article_id in group["non_relevant"]
        )
    metrics["positive_pair_count"] = len(positive_scores)
    metrics["negative_pair_count"] = len(negative_scores)
    metrics["mean_positive_pair_cosine"] = (
        float(np.mean(positive_scores)) if positive_scores else None
    )
    metrics["mean_negative_pair_cosine"] = (
        float(np.mean(negative_scores)) if negative_scores else None
    )
    return metrics


def _pair_loss(
    model: Any,
    loss: Any,
    pairs: list[tuple[str, str, float]],
    batch_size: int,
) -> float:
    import torch
    from sentence_transformers import InputExample
    from torch.utils.data import DataLoader

    examples = [
        InputExample(texts=[query, article], label=label)
        for query, article, label in pairs
    ]
    loader = DataLoader(
        examples,
        shuffle=False,
        batch_size=batch_size,
        collate_fn=model.smart_batching_collate,
    )
    was_training = model.training
    model.eval()
    total_loss = 0.0
    total_examples = 0
    try:
        with torch.no_grad():
            for features, labels in loader:
                labels = labels.to(model.device)
                batch_count = labels.shape[0]
                total_loss += float(loss(features, labels).detach().cpu()) * batch_count
                total_examples += batch_count
    finally:
        if was_training:
            model.train()
    return total_loss / total_examples


def _score_key(metrics: dict[str, Any]) -> tuple[float, float, float, float]:
    return (
        metrics["hit_at_3"],
        metrics["mrr_at_10"],
        metrics["hit_at_1"],
        metrics["hit_at_10"],
    )


def _cached_model_path() -> Path:
    snapshots = (
        Path.home()
        / ".cache"
        / "huggingface"
        / "hub"
        / "models--sentence-transformers--paraphrase-multilingual-MiniLM-L12-v2"
        / "snapshots"
    )
    if not snapshots.is_dir():
        raise FileNotFoundError(
            f"The cached {BASE_MODEL_ID} model was not found at {snapshots}."
        )
    candidates = [path for path in snapshots.iterdir() if path.is_dir()]
    if not candidates:
        raise FileNotFoundError(f"No cached model snapshots were found at {snapshots}.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config-file", type=Path, default=None)
    parser.add_argument("--experiment-name", type=str, default="sbert-finetune")
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--validation-retrieval-every", type=int, default=1)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--model-path", type=Path, default=None)
    parser.add_argument("--output-root", type=Path, default=OUTPUT_ROOT)
    parser.add_argument(
        "--manual-review",
        type=Path,
        default=None,
        help="Add reviewed relevance labels from a manual review workbook.",
    )
    parser.add_argument(
        "--manual-review-label-override",
        action="append",
        default=[],
        metavar="NARRATIVE-ID|ARTICLE-ID|0-or-1",
        help="Resolve repeated conflicting judgments in the manual workbook.",
    )
    parser.add_argument(
        "--retire-existing-test",
        action="store_true",
        help="Required when manual review narratives came from the prior test split.",
    )
    args = parser.parse_args()
    if args.config_file is not None:
        config = json.loads(args.config_file.read_text(encoding="utf-8"))
        if not isinstance(config, dict):
            parser.error("The experiment config must contain a JSON object.")
        allowed_config_keys = {
            "experiment_name",
            "epochs",
            "validation_retrieval_every",
            "batch_size",
            "learning_rate",
            "seed",
            "output_root",
        }
        unknown_config_keys = set(config) - allowed_config_keys
        if unknown_config_keys:
            parser.error(
                "Unsupported experiment config key(s): "
                + ", ".join(sorted(unknown_config_keys))
            )
        for key, value in config.items():
            setattr(args, key, Path(value) if key == "output_root" else value)
    if args.epochs < 1 or args.batch_size < 1 or args.learning_rate <= 0:
        parser.error("epochs, batch-size, and learning-rate must be positive.")
    if args.validation_retrieval_every < 1:
        parser.error("validation-retrieval-every must be positive.")
    if not args.experiment_name.strip() or Path(args.experiment_name).name != args.experiment_name:
        parser.error("experiment-name must be a non-empty directory name.")
    if args.manual_review is None and args.manual_review_label_override:
        parser.error("--manual-review-label-override requires --manual-review.")

    try:
        import numpy as np
        import torch
        from sentence_transformers import InputExample, SentenceTransformer
        from sentence_transformers.sentence_transformer import losses
        from torch.utils.data import DataLoader, WeightedRandomSampler
        from transformers import get_linear_schedule_with_warmup
    except ImportError as exc:
        raise SystemExit(
            f"Missing training dependency: {exc.name or 'a required package'}. "
            "Install torch, sentence-transformers, and openpyxl in the project "
            "Python environment, then retry."
        ) from exc

    dataset_directory = PROJECT_ROOT / "DATA" / "Datasets"
    corpus_path = PROJECT_ROOT / "DATA" / "Corpus" / "MasterCorpus.xlsx"
    training_path = dataset_directory / "Trainingdataset.xlsx"
    evaluation_path = dataset_directory / "Evaluationdataset.xlsx"
    for path in (training_path, evaluation_path, corpus_path):
        if not path.is_file():
            raise SystemExit(f"Required experiment input is missing: {path}")

    training_rows = _read_rows(training_path)
    evaluation_rows = _read_rows(evaluation_path)
    corpus_rows = _read_rows(corpus_path)
    _required_columns(
        training_rows,
        ("Sample Narrative", "Applicable_Article_ID", "Relevance_Label"),
        training_path,
    )
    _required_columns(
        evaluation_rows,
        ("Sample Narrative", "Applicable_Article_ID", "Relevance_Label"),
        evaluation_path,
    )
    _required_columns(
        corpus_rows,
        ("Article_ID", "Law", "Article_Number", "Article Text"),
        corpus_path,
    )

    articles: dict[str, str] = {}
    article_ids: list[str] = []
    article_texts: list[str] = []
    for row_number, row in enumerate(corpus_rows, start=2):
        article_id = str(row["Article_ID"]).strip().casefold()
        text = _article_embedding_text(row)
        if not article_id or not text:
            raise SystemExit(
                f"Corpus row {row_number} has a blank Article_ID or Article Text."
            )
        if article_id in articles:
            raise SystemExit(f"Corpus contains duplicate Article_ID {article_id!r}.")
        articles[article_id] = text
        article_ids.append(article_id)
        article_texts.append(text)

    pairs = _load_training_pairs(training_rows, articles, training_path)
    evaluation_pairs = _load_training_pairs(
        evaluation_rows, articles, evaluation_path
    )
    training_groups = _load_relevance_groups(
        training_rows, articles, training_path
    )
    evaluation_groups = _load_relevance_groups(
        evaluation_rows, articles, evaluation_path
    )
    manual_review_metadata: dict[str, Any] | None = None
    manual_test_overlap_count = 0
    if args.manual_review is not None:
        overrides = _parse_manual_label_overrides(
            args.manual_review_label_override
        )
        manual_pairs, manual_review_metadata = _load_manual_review_pairs(
            args.manual_review, articles, overrides
        )
        evaluation_queries = {
            group["query"].casefold() for group in evaluation_groups
        }
        manual_queries = {
            str(row["Sample Narrative"]).strip().casefold()
            for row in _read_rows(args.manual_review)
        }
        overlap = evaluation_queries & manual_queries
        if overlap:
            raise SystemExit(
                "Manual review queries overlap the Evaluation split; these "
                "judgments cannot be used for training and evaluation together."
            )
        test_queries = {
            str(row["Sample Narrative"]).strip().casefold()
            for row in _read_rows(dataset_directory / "Testingdataset.xlsx")
        }
        manual_test_overlap_count = len(manual_queries & test_queries)
        if manual_test_overlap_count and not args.retire_existing_test:
            raise SystemExit(
                f"Manual review contains {manual_test_overlap_count} narrative(s) "
                "from the previous Testing split. Pass --retire-existing-test "
                "to acknowledge those test scores are retired."
            )
        pairs.extend(manual_pairs)
    positive_count = sum(label == 1.0 for _, _, label in pairs)
    negative_count = len(pairs) - positive_count
    if not positive_count or not negative_count:
        raise SystemExit(
            "Training data must include both relevant and non-relevant pairs."
        )
    if not any(group["relevant"] for group in evaluation_groups):
        raise SystemExit("Evaluation data contains no relevant article labels.")

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    base_model_path = _cached_model_path()
    model_path = args.model_path or base_model_path
    if not model_path.exists():
        raise SystemExit(f"SentenceTransformer model path does not exist: {model_path}")
    inherited_test_retirement = _starting_model_retired_test(model_path)
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = SentenceTransformer(str(model_path), device=device)
    baseline_vectors = model.encode(
        article_texts,
        batch_size=64,
        convert_to_numpy=True,
        normalize_embeddings=True,
        show_progress_bar=True,
    )
    baseline_vectors = np.asarray(baseline_vectors, dtype=np.float32)
    if baseline_vectors.shape != (len(article_ids), 384):
        raise SystemExit(
            f"Baseline embedding matrix has unexpected shape {baseline_vectors.shape}."
        )
    if not np.isfinite(baseline_vectors).all():
        raise SystemExit("Baseline embeddings contain NaN or infinite values.")
    if not np.allclose(np.linalg.norm(baseline_vectors, axis=1), 1.0, atol=1e-3):
        raise SystemExit("Baseline embeddings are not unit-normalized.")
    baseline = _retrieval_metrics(
        model,
        evaluation_groups,
        article_ids,
        article_texts,
        corpus_vectors=baseline_vectors,
    )
    starting_training_metrics = _retrieval_metrics(
        model,
        training_groups,
        article_ids,
        article_texts,
        corpus_vectors=baseline_vectors,
    )

    run_directory = (
        args.output_root
        / args.experiment_name
        / datetime.now().strftime("%Y%m%d_%H%M%S")
    )
    run_directory.mkdir(parents=True, exist_ok=False)
    examples = [
        InputExample(texts=[query, article], label=label)
        for query, article, label in pairs
    ]
    generator = torch.Generator()
    generator.manual_seed(args.seed)
    class_counts = Counter(int(pair[2]) for pair in pairs)
    sampler = None
    if args.manual_review is not None:
        sample_weights = [1.0 / class_counts[int(pair[2])] for pair in pairs]
        sampler = WeightedRandomSampler(
            sample_weights,
            num_samples=len(examples),
            replacement=True,
            generator=generator,
        )
    loader = DataLoader(
        examples,
        shuffle=sampler is None,
        sampler=sampler,
        batch_size=args.batch_size,
        collate_fn=model.smart_batching_collate,
        generator=generator,
    )
    loss = losses.CosineSimilarityLoss(model)
    initial_training_loss = _pair_loss(
        model, loss, pairs, args.batch_size
    )
    initial_validation_loss = _pair_loss(
        model, loss, evaluation_pairs, args.batch_size
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.learning_rate)
    total_steps = len(loader) * args.epochs
    warmup_steps = max(1, int(total_steps * 0.1))
    scheduler = get_linear_schedule_with_warmup(
        optimizer,
        num_warmup_steps=warmup_steps,
        num_training_steps=total_steps,
    )

    epoch_history: list[dict[str, Any]] = []
    best_score: tuple[float, float, float, float] | None = None
    best_state: dict[str, Any] | None = None
    best_epoch = 0
    best_validation_metrics: dict[str, Any] | None = None
    best_corpus_vectors: Any | None = None
    device_value = model.device
    for epoch in range(1, args.epochs + 1):
        model.train()
        loss_total = 0.0
        for features, labels in loader:
            labels = labels.to(device_value)
            optimizer.zero_grad(set_to_none=True)
            loss_value = loss(features, labels)
            loss_value.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            scheduler.step()
            loss_total += float(loss_value.detach().cpu())

        mean_loss = loss_total / len(loader)
        validation_loss = _pair_loss(
            model, loss, evaluation_pairs, args.batch_size
        )
        evaluate_retrieval = (
            epoch % args.validation_retrieval_every == 0 or epoch == args.epochs
        )
        validation_vectors = None
        validation_metrics = None
        if evaluate_retrieval:
            validation_vectors = np.asarray(
                model.encode(
                    article_texts,
                    batch_size=32,
                    convert_to_numpy=True,
                    normalize_embeddings=True,
                    show_progress_bar=False,
                ),
                dtype=np.float32,
            )
            validation_metrics = _retrieval_metrics(
                model,
                evaluation_groups,
                article_ids,
                article_texts,
                corpus_vectors=validation_vectors,
            )
        epoch_history.append(
            {
                "epoch": epoch,
                "mean_training_loss": mean_loss,
                "validation_loss": validation_loss,
                "validation_retrieval": validation_metrics,
            }
        )
        result_summary = (
            (
                f"validation_hit3={validation_metrics['hit_at_3']:.4f}, "
                f"validation_mrr10={validation_metrics['mrr_at_10']:.4f}"
            )
            if validation_metrics is not None
            else "retrieval checkpoint skipped"
        )
        print(
            f"Epoch {epoch}/{args.epochs}: "
            f"train_loss={mean_loss:.4f}, validation_loss={validation_loss:.4f}, "
            f"{result_summary}"
        )
        if validation_metrics is not None:
            score = _score_key(validation_metrics)
            if best_score is None or score > best_score:
                best_score = score
                best_epoch = epoch
                best_state = {
                    name: value.detach().cpu().clone()
                    for name, value in model.state_dict().items()
                }
                best_validation_metrics = validation_metrics
                best_corpus_vectors = validation_vectors

    if (
        best_state is None
        or best_validation_metrics is None
        or best_corpus_vectors is None
    ):
        raise RuntimeError("Training completed without a validation checkpoint.")
    model.load_state_dict(best_state)
    selected_training_metrics = _retrieval_metrics(
        model,
        training_groups,
        article_ids,
        article_texts,
        corpus_vectors=best_corpus_vectors,
    )
    candidate_path = run_directory / "candidate_model"
    model.save(str(candidate_path))

    report = {
        "experiment_name": args.experiment_name,
        "configuration_file": (
            str(args.config_file.resolve()) if args.config_file is not None else None
        ),
        "configuration": {
            "epochs": args.epochs,
            "validation_retrieval_every": args.validation_retrieval_every,
            "batch_size": args.batch_size,
            "learning_rate": args.learning_rate,
            "seed": args.seed,
            "output_root": str(args.output_root),
        },
        "base_model": BASE_MODEL_ID,
        "base_model_path": str(base_model_path),
        "starting_model_path": str(model_path),
        "starting_model_is_base_model": model_path.resolve() == base_model_path.resolve(),
        "device": device,
        "seed": args.seed,
        "epochs": args.epochs,
        "validation_retrieval_every": args.validation_retrieval_every,
        "batch_size": args.batch_size,
        "learning_rate": args.learning_rate,
        "warmup_steps": warmup_steps,
        "scheduler": "linear_with_warmup",
        "checkpoint_selection": (
            "validation hit_at_3, then mrr_at_10, hit_at_1, hit_at_10"
        ),
        "training_pair_loss_before_training": initial_training_loss,
        "validation_pair_loss_before_training": initial_validation_loss,
        "epoch_history": epoch_history,
        "selected_epoch": best_epoch,
        "training_pairs": len(pairs),
        "training_positive_pairs": positive_count,
        "training_negative_pairs": negative_count,
        "balanced_pair_sampling": sampler is not None,
        "training_query_groups": len(training_groups),
        "evaluation_rows": len(evaluation_rows),
        "evaluation_query_groups": len(evaluation_groups),
        "corpus_articles": len(article_ids),
        "starting_model_on_training": starting_training_metrics,
        "starting_model_on_evaluation": baseline,
        "selected_model_on_training": selected_training_metrics,
        "selected_model_on_evaluation": best_validation_metrics,
        "final_candidate_beats_baseline_by_hit3_then_mrr": (
            _score_key(best_validation_metrics) > _score_key(baseline)
        ),
        "testing_split_used": manual_test_overlap_count > 0,
        "inherited_test_retirement": inherited_test_retirement,
        "previous_testing_split_retired": (
            manual_test_overlap_count > 0 or inherited_test_retirement
        ),
        "final_test_metrics_valid": (
            manual_test_overlap_count == 0 and not inherited_test_retirement
        ),
        "testing_query_overlap_count": manual_test_overlap_count,
        "manual_review": (
            {
                **manual_review_metadata,
                "source": str(args.manual_review.resolve()),
                "review_queries_overlap_previous_testing_split": (
                    manual_test_overlap_count > 0
                ),
                "inherited_test_retirement": inherited_test_retirement,
                "uncertain_labels_used_for_training": False,
                "prior_test_results_retired": True,
            }
            if manual_review_metadata is not None
            else None
        ),
        "candidate_model_path": str(candidate_path),
    }
    report_path = run_directory / "evaluation_report.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"\nStarting model on Evaluation: {json.dumps(baseline, sort_keys=True)}")
    print(
        f"Selected epoch {best_epoch} on Evaluation: "
        f"{json.dumps(best_validation_metrics, sort_keys=True)}"
    )
    print(
        "Candidate improves the Hit@3-first evaluation ranking: "
        f"{report['final_candidate_beats_baseline_by_hit3_then_mrr']}"
    )
    print(f"Candidate model: {candidate_path}")
    print(f"Evaluation report: {report_path}")


if __name__ == "__main__":
    main()
