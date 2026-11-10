"""Compare fine-tuned SBERT, base MiniLM, and local CATALYST E5 retrieval."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
from pathlib import Path
import re
from typing import Any

import numpy as np

try:
    from .finetune_sbert import (
        OUTPUT_ROOT,
        _article_embedding_text,
        _cached_model_path,
        _load_relevance_groups,
        _read_rows,
    )
except ImportError:
    from finetune_sbert import (
        OUTPUT_ROOT,
        _article_embedding_text,
        _cached_model_path,
        _load_relevance_groups,
        _read_rows,
    )


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATASET_DIRECTORY = PROJECT_ROOT / "DATA" / "Datasets"
CORPUS_PATH = PROJECT_ROOT / "DATA" / "Corpus" / "MasterCorpus.xlsx"
TEST_PATH = DATASET_DIRECTORY / "Testingdataset.xlsx"
E5_MODEL_PATH = PROJECT_ROOT / "tool" / "retrieval_lab" / "e5" / "model.onnx"
E5_TOKENIZER_PATH = (
    PROJECT_ROOT / "tool" / "retrieval_lab" / "e5" / "tokenizer.json"
)
E5_CHUNKS_PATH = PROJECT_ROOT / "tool" / "retrieval_lab" / "out" / "chunks_e5.npy"
E5_OWNERS_PATH = (
    PROJECT_ROOT / "tool" / "retrieval_lab" / "out" / "chunk_owner.json"
)
ARTICLES_PATH = PROJECT_ROOT / "assets" / "data" / "legal_articles.json"
CLASSIFICATION_THRESHOLD = 0.5

STOPWORDS = set(
    "a an the and or of to in on at by for with from as is are was were be been "
    "being it its this that these those which who whom shall may can could would "
    "should will has have had do does did if but than then so such any all his her "
    "their our my your he she they we you i me us them him not no nor upon into "
    "under over between other only also article art ang ng sa na mga ko mo yung ay "
    "pa po ba lang naman kasi pero kahit si ni kay din rin daw raw mayroon".split()
)
TOKEN_PATTERN = re.compile(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*")


def _load_corpus() -> tuple[list[str], list[str]]:
    rows = _read_rows(CORPUS_PATH)
    if not rows:
        raise ValueError(f"Corpus contains no rows: {CORPUS_PATH}")
    ids: list[str] = []
    texts: list[str] = []
    for row in rows:
        ids.append(str(row["Article_ID"]).strip().casefold())
        texts.append(_article_embedding_text(row))
    return ids, texts


def _load_groups(
    path: Path, article_texts: dict[str, str]
) -> tuple[list[dict[str, Any]], list[tuple[str, str, float]]]:
    rows = _read_rows(path)
    groups = _load_relevance_groups(rows, article_texts, path)
    pairs: list[tuple[str, str, float]] = []
    for row in rows:
        query = str(row["Sample Narrative"]).strip()
        label = float(row["Relevance_Label"])
        for article_id in str(row["Applicable_Article_ID"]).split(","):
            normalized_id = article_id.strip().casefold()
            if normalized_id:
                pairs.append((query, article_texts[normalized_id], label))
    return groups, pairs


def _stem(token: str) -> str:
    if len(token) > 4 and token.endswith("ies"):
        return token[:-3] + "y"
    if len(token) > 5 and token.endswith("ing"):
        return token[:-3]
    if len(token) > 4 and token.endswith("ed"):
        return token[:-2]
    if len(token) > 4 and token.endswith("es"):
        return token[:-2]
    if len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
        return token[:-1]
    return token


def _terms(text: str) -> list[str]:
    return [
        _stem(token)
        for token in TOKEN_PATTERN.findall(text.lower().replace("’", "'"))
        if len(token) > 1 and token not in STOPWORDS
    ]


class BM25Index:
    def __init__(self, documents: list[str]) -> None:
        self.term_counts = [Counter(_terms(document)) for document in documents]
        self.document_lengths = np.asarray(
            [sum(counts.values()) for counts in self.term_counts], dtype=np.float64
        )
        self.average_length = float(self.document_lengths.mean())
        document_frequency: Counter[str] = Counter()
        for counts in self.term_counts:
            document_frequency.update(counts.keys())
        count = len(documents)
        self.idf = {
            term: math.log(1 + (count - frequency + 0.5) / (frequency + 0.5))
            for term, frequency in document_frequency.items()
        }
        self.postings: dict[str, list[tuple[int, int]]] = defaultdict(list)
        for index, counts in enumerate(self.term_counts):
            for term, frequency in counts.items():
                self.postings[term].append((index, frequency))

    def scores(self, query: str) -> np.ndarray:
        output = np.zeros(len(self.term_counts), dtype=np.float32)
        for term in set(_terms(query)):
            idf = self.idf.get(term)
            if idf is None:
                continue
            for index, frequency in self.postings[term]:
                normalization = (
                    1 - 0.75
                    + 0.75 * self.document_lengths[index] / self.average_length
                )
                output[index] += (
                    idf
                    * frequency
                    * 2.2
                    / (frequency + 1.2 * normalization)
                )
        return output


def _rank(scores: np.ndarray) -> list[int]:
    return np.argsort(-scores, kind="stable").tolist()


def _rrf(
    rankings: list[list[int]], article_count: int, k: int = 20, pool: int = 50
) -> np.ndarray:
    fused = np.zeros(article_count, dtype=np.float64)
    for ranking in rankings:
        for rank, index in enumerate(ranking[:pool]):
            fused[index] += 1.0 / (k + rank + 1)
    return fused


def _metrics(
    rankings: list[list[int]],
    groups: list[dict[str, Any]],
    ids: list[str],
) -> dict[str, Any]:
    positions = {article_id: index for index, article_id in enumerate(ids)}
    positive_groups = [group for group in groups if group["relevant"]]
    denominator = len(positive_groups)
    result: dict[str, Any] = {
        "positive_query_count": denominator,
        "negative_only_query_count": len(groups) - denominator,
    }
    for cutoff in (1, 3, 5, 10, 15, 25):
        hits = 0
        total_relevant = 0
        reciprocal_rank = 0.0
        for ranking, group in zip(rankings, groups):
            relevant = {
                positions[article_id]
                for article_id in group["relevant"]
                if article_id in positions
            }
            if not relevant:
                continue
            total_relevant += len(relevant)
            first = next(
                (
                    rank
                    for rank, index in enumerate(ranking, start=1)
                    if index in relevant
                ),
                None,
            )
            hits += first is not None and first <= cutoff
            if first is not None and first <= 10:
                reciprocal_rank += 1.0 / first
        found = sum(
            len(
                {
                    index
                    for index in ranking[:cutoff]
                    if ids[index] in group["relevant"]
                }
            )
            for ranking, group in zip(rankings, groups)
        )
        precision = found / (denominator * cutoff) if denominator else 0.0
        recall = found / total_relevant if total_relevant else 0.0
        result[f"hit_at_{cutoff}"] = hits / denominator if denominator else 0.0
        result[f"precision_at_{cutoff}"] = precision
        result[f"recall_at_{cutoff}"] = recall
        result[f"f1_at_{cutoff}"] = (
            2 * precision * recall / (precision + recall)
            if precision + recall
            else 0.0
        )
        if cutoff == 10:
            result["mrr_at_10"] = (
                reciprocal_rank / denominator if denominator else 0.0
            )
    return result


def _classification_metrics(
    model: Any,
    pairs: list[tuple[str, str, float]],
) -> dict[str, Any]:
    if not pairs:
        return {"available": False, "reason": "No labeled pairs."}
    queries = [pair[0] for pair in pairs]
    articles = [pair[1] for pair in pairs]
    query_vectors = np.asarray(
        model.encode(
            queries,
            batch_size=32,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        ),
        dtype=np.float32,
    )
    article_vectors = np.asarray(
        model.encode(
            articles,
            batch_size=32,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        ),
        dtype=np.float32,
    )
    scores = np.sum(query_vectors * article_vectors, axis=1)
    labels = np.asarray([pair[2] == 1 for pair in pairs], dtype=bool)
    predictions = scores >= CLASSIFICATION_THRESHOLD
    tp = int(np.sum(predictions & labels))
    fp = int(np.sum(predictions & ~labels))
    fn = int(np.sum(~predictions & labels))
    tn = int(np.sum(~predictions & ~labels))
    positive_support = tp + fn
    negative_support = tn + fp
    has_both_classes = positive_support > 0 and negative_support > 0
    precision = tp / (tp + fp) if has_both_classes and tp + fp else None
    recall = tp / positive_support if positive_support else None
    f1 = (
        2 * precision * recall / (precision + recall)
        if precision is not None and recall is not None and precision + recall
        else None
    )
    accuracy = (tp + tn) / len(pairs) if has_both_classes else None
    return {
        "available": True,
        "cosine_threshold": CLASSIFICATION_THRESHOLD,
        "pair_count": len(pairs),
        "positive_support": positive_support,
        "negative_support": negative_support,
        "true_positive": tp,
        "false_positive": fp,
        "false_negative": fn,
        "true_negative": tn,
        "accuracy": accuracy,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "specificity": tn / negative_support if negative_support else None,
        "balanced_accuracy": (
            (recall + tn / negative_support) / 2
            if recall is not None and negative_support
            else None
        ),
        "mean_positive_cosine": (
            float(scores[labels].mean()) if positive_support else None
        ),
        "mean_negative_cosine": (
            float(scores[~labels].mean()) if negative_support else None
        ),
    }


class ActiveE5Hybrid:
    def __init__(
        self,
        ids: list[str],
        texts: list[str],
        articles: list[dict[str, Any]],
    ) -> None:
        import onnxruntime as ort
        from tokenizers import Tokenizer

        for path in (E5_MODEL_PATH, E5_TOKENIZER_PATH, E5_CHUNKS_PATH, E5_OWNERS_PATH):
            if not path.is_file():
                raise FileNotFoundError(f"Required E5 comparison asset is missing: {path}")
        self.session = ort.InferenceSession(
            str(E5_MODEL_PATH), providers=["CPUExecutionProvider"]
        )
        self.tokenizer = Tokenizer.from_file(str(E5_TOKENIZER_PATH))
        self.tokenizer.enable_truncation(max_length=128)
        self.chunks = np.load(E5_CHUNKS_PATH, mmap_mode="r")
        self.owners = np.asarray(
            json.loads(E5_OWNERS_PATH.read_text(encoding="utf-8")),
            dtype=np.int64,
        )
        self.ids = ids
        self.articles = articles
        if len(self.owners) != len(self.chunks):
            raise ValueError("E5 chunk owner count does not match the embedding matrix.")
        if len(self.articles) != len(ids):
            raise ValueError("Bundled articles do not match the source corpus length.")
        for index, article in enumerate(self.articles):
            asset_law = re.sub(r"[^a-z0-9]+", "", str(article["Law"]).casefold())
            corpus_law = ids[index].split(":", maxsplit=1)[0]
            if asset_law != corpus_law:
                raise ValueError("Bundled article law order differs from the corpus.")
            if (
                str(article["Article"]).strip().casefold()
                != str(texts[index].splitlines()[1].removeprefix("Article: "))
                .strip()
                .casefold()
            ):
                raise ValueError("Bundled article number order differs from the corpus.")
            if article["Article Text"] != texts[index].split(
                "Legal provision:\n", maxsplit=1
            )[-1]:
                raise ValueError("Bundled article text differs from the prepared corpus.")
        self.bm25 = BM25Index([str(article["Article Text"]) for article in articles])

    def _encode_query(self, query: str) -> np.ndarray:
        encoded = self.tokenizer.encode(f"query: {query}")
        ids = np.asarray([encoded.ids], dtype=np.int64)
        mask = np.asarray([encoded.attention_mask], dtype=np.int64)
        names = {item.name for item in self.session.get_inputs()}
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in names:
            feed["token_type_ids"] = np.zeros_like(ids)
        hidden = self.session.run(None, feed)[0]
        vector = hidden[0] * mask[0, :, None]
        vector = vector.sum(axis=0) / max(int(mask.sum()), 1)
        norm = np.linalg.norm(vector)
        if not np.isfinite(norm) or norm == 0:
            raise ValueError("E5 produced an invalid query embedding.")
        return np.asarray(vector / norm, dtype=np.float32)

    def rank(self, query: str) -> tuple[list[int], np.ndarray]:
        vector = self._encode_query(query)
        chunk_scores = np.asarray(self.chunks @ vector, dtype=np.float32)
        best_cosine = np.full(len(self.ids), -1.0, dtype=np.float32)
        np.maximum.at(best_cosine, self.owners, chunk_scores)
        dense_order = _rank(best_cosine)[:50]
        lexical_scores = self.bm25.scores(query)
        lexical_order = [
            index for index in _rank(lexical_scores) if lexical_scores[index] > 0
        ][:50]
        rankings = [dense_order]
        if lexical_order:
            rankings.append(lexical_order)
        fused = _rrf(rankings, len(self.ids))
        eligible = [
            index for index in _rank(fused) if best_cosine[index] >= 0.79
        ]
        if not eligible:
            return [], best_cosine
        max_lexical = float(lexical_scores[lexical_order[0]]) if lexical_order else 0.0
        blended = {}
        for index in eligible:
            dense = min(max((float(best_cosine[index]) - 0.75) / 0.15, 0), 1)
            lexical = (
                float(lexical_scores[index]) / max_lexical
                if max_lexical
                else 0.0
            )
            blended[index] = 0.85 * dense + 0.15 * lexical
        order_position = {index: rank for rank, index in enumerate(_rank(fused))}
        eligible.sort(key=lambda index: (-blended[index], order_position[index]))
        return eligible[:15], best_cosine


def _prepare_sbert_vectors(
    model: Any,
    texts: list[str],
    cache_path: Path,
) -> np.ndarray:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    if cache_path.is_file():
        cached = np.load(cache_path, mmap_mode="r")
        if cached.shape == (len(texts), 384) and np.isfinite(cached).all():
            return cached
    vectors = np.asarray(
        model.encode(
            texts,
            batch_size=64,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=True,
        ),
        dtype=np.float32,
    )
    if vectors.shape != (len(texts), 384) or not np.isfinite(vectors).all():
        raise ValueError(f"Invalid corpus embedding matrix: {vectors.shape}.")
    temporary_path = cache_path.with_suffix(".tmp.npy")
    np.save(temporary_path, vectors)
    temporary_path.replace(cache_path)
    return vectors


def _rank_sbert(
    model: Any,
    query: str,
    corpus_vectors: np.ndarray,
) -> tuple[list[int], np.ndarray]:
    query_vector = np.asarray(
        model.encode(
            query,
            convert_to_numpy=True,
            normalize_embeddings=True,
            show_progress_bar=False,
        ),
        dtype=np.float32,
    ).reshape(-1)
    scores = corpus_vectors @ query_vector
    return _rank(scores), scores


def _print_article_results(
    title: str,
    ranking: list[int],
    scores: np.ndarray,
    articles: list[dict[str, Any]],
    count: int,
) -> None:
    print(f"\n{title}")
    if not ranking:
        print("  No articles passed the production E5 cosine gate.")
        return
    for position, index in enumerate(ranking[:count], start=1):
        article = articles[index]
        law = article.get("Law", "Unknown law")
        number = article.get("Article", "?")
        body = re.sub(r"\s+", " ", str(article.get("Article Text", ""))).strip()
        preview = body[:220] + ("..." if len(body) > 220 else "")
        print(
            f"  {position:>2}. {law} Art. {number} "
            f"(cosine={float(scores[index]):.3f})"
        )
        print(f"      {preview}")


def _show_known_test_labels(
    query: str,
    known_relevant: dict[str, set[str]],
    rankings: dict[str, list[int]],
    ids: list[str],
) -> None:
    relevant = known_relevant.get(query.casefold())
    if not relevant:
        return
    print("\nHeld-out labels for this exact test query:")
    print("  " + ", ".join(sorted(relevant)))
    for label, ranking in rankings.items():
        ranks = {
            article_id: ranking.index(index) + 1
            for article_id in relevant
            if (index := ids.index(article_id)) in ranking
        }
        rendered = ", ".join(
            f"{article_id} at #{rank}" for article_id, rank in sorted(ranks.items())
        )
        missing = sorted(relevant - ranks.keys())
        if missing:
            rendered = ", ".join(part for part in (rendered, f"not in list: {', '.join(missing)}") if part)
        print(f"  {label}: {rendered or 'none retrieved'}")


def _evaluation_report(
    run_directory: Path,
    ids: list[str],
    texts: list[str],
    articles: list[dict[str, Any]],
    base_model: Any,
    candidate_model: Any,
) -> dict[str, Any]:
    groups, pairs = _load_groups(TEST_PATH, dict(zip(ids, texts)))
    evaluation_groups, evaluation_pairs = _load_groups(
        DATASET_DIRECTORY / "Evaluationdataset.xlsx", dict(zip(ids, texts))
    )
    e5 = ActiveE5Hybrid(ids, texts, articles)
    corpus_fingerprint = hashlib.sha256(
        "\n".join(f"{article_id}\t{text}" for article_id, text in zip(ids, texts)).encode(
            "utf-8"
        )
    ).hexdigest()[:16]
    base_vectors = _prepare_sbert_vectors(
        base_model,
        texts,
        run_directory / f"console_base_corpus_{corpus_fingerprint}.npy",
    )
    candidate_vectors = _prepare_sbert_vectors(
        candidate_model,
        texts,
        run_directory / f"console_candidate_corpus_{corpus_fingerprint}.npy",
    )
    base_rankings: list[list[int]] = []
    candidate_rankings: list[list[int]] = []
    e5_rankings: list[list[int]] = []
    for group in groups:
        base_ranking, _ = _rank_sbert(
            base_model, group["query"], base_vectors
        )
        candidate_ranking, _ = _rank_sbert(
            candidate_model, group["query"], candidate_vectors
        )
        e5_ranking, _ = e5.rank(group["query"])
        base_rankings.append(base_ranking)
        candidate_rankings.append(candidate_ranking)
        e5_rankings.append(e5_ranking)

    retriever_rankings = {
        "base_minilm_cosine": base_rankings,
        "fine_tuned_minilm_cosine": candidate_rankings,
        "current_catalyst_e5_hybrid_raw_query": e5_rankings,
    }
    per_query = []
    for query_index, group in enumerate(groups):
        relevant = group["relevant"]
        systems: dict[str, Any] = {}
        for system, system_rankings in retriever_rankings.items():
            ranking = system_rankings[query_index]
            relevant_ranks = [
                rank
                for rank, article_index in enumerate(ranking, start=1)
                if ids[article_index] in relevant
            ]
            systems[system] = {
                "top_15_article_ids": [ids[index] for index in ranking[:15]],
                "first_relevant_rank": min(relevant_ranks, default=None),
            }
        per_query.append(
            {
                "query": group["query"],
                "relevant_article_ids": sorted(relevant),
                "rankings": systems,
            }
        )

    result = {
        "testing_split": str(TEST_PATH),
        "testing_pairs": len(pairs),
        "testing_query_groups": len(groups),
        "testing_positive_query_groups": sum(bool(g["relevant"]) for g in groups),
        "testing_negative_only_query_groups": sum(
            not bool(g["relevant"]) for g in groups
        ),
        "evaluation_query_groups": len(evaluation_groups),
        "classification_threshold": CLASSIFICATION_THRESHOLD,
        "classification_metrics_on_test_pairs": {
            "base_minilm": _classification_metrics(base_model, pairs),
            "fine_tuned_minilm": _classification_metrics(candidate_model, pairs),
        },
        "classification_metrics_on_evaluation_pairs_at_fixed_0_5_cosine": {
            "base_minilm": _classification_metrics(base_model, evaluation_pairs),
            "fine_tuned_minilm": _classification_metrics(
                candidate_model, evaluation_pairs
            ),
        },
        "retrieval_metrics": {
            "base_minilm_cosine": _metrics(base_rankings, groups, ids),
            "fine_tuned_minilm_cosine": _metrics(candidate_rankings, groups, ids),
            "current_catalyst_e5_hybrid_raw_query": _metrics(
                e5_rankings, groups, ids
            ),
        },
        "per_query_results": per_query,
        "current_e5_comparison_caveat": (
            "Uses the production E5 chunk embeddings, cosine gate, lexical BM25, "
            "RRF, and score blend, but passes raw queries without Flutter's query "
            "normalization, glossary expansion, or on-device Tagalog translation."
        ),
        "precision_recall_caveat": (
            "Retrieval precision/recall/F1 count only labeled relevant article IDs; "
            "articles without a label are unjudged and treated as non-relevant. "
            "The Testing split has no labeled negative pairs, so test-set pair "
            "classification accuracy, precision, and F1 are undefined."
        ),
    }
    report_path = run_directory / "testing_retrieval_report.json"
    report_path.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Test report saved: {report_path}")
    _print_metric_table(result)
    return result


def _print_metric_table(report: dict[str, Any]) -> None:
    labels = (
        ("base_minilm_cosine", "Base MiniLM cosine"),
        ("fine_tuned_minilm_cosine", "Fine-tuned SBERT"),
        ("current_catalyst_e5_hybrid_raw_query", "Current E5 hybrid*"),
    )
    print("\nTEST SET RETRIEVAL (unjudged articles count as non-relevant)")
    print(f"{'System':<24} {'Hit@1':>7} {'P@3':>7} {'R@3':>7} {'F1@3':>7} {'R@10':>7} {'MRR@10':>8}")
    for key, label in labels:
        metrics = report["retrieval_metrics"][key]
        print(
            f"{label:<24} "
            f"{metrics['hit_at_1']:>7.3f} "
            f"{metrics['precision_at_3']:>7.3f} "
            f"{metrics['recall_at_3']:>7.3f} "
            f"{metrics['f1_at_3']:>7.3f} "
            f"{metrics['recall_at_10']:>7.3f} "
            f"{metrics['mrr_at_10']:>8.3f}"
        )
    print(
        f"Queries: {report['testing_positive_query_groups']} with labeled "
        f"relevant articles; {report['testing_negative_only_query_groups']} "
        "negative-only."
    )
    print("*Raw query approximate production pipeline; see report caveat.")
    print("\nPAIR CLASSIFICATION (fixed cosine threshold 0.5; evaluation set)")
    for key, label in (
        ("base_minilm", "Base MiniLM"),
        ("fine_tuned_minilm", "Fine-tuned SBERT"),
    ):
        metrics = report[
            "classification_metrics_on_evaluation_pairs_at_fixed_0_5_cosine"
        ][key]
        print(
            f"{label:<24} n={metrics['pair_count']} "
            f"accuracy={metrics['accuracy']} precision={metrics['precision']} "
            f"recall={metrics['recall']} f1={metrics['f1']} "
            f"specificity={metrics['specificity']} "
            f"balanced_accuracy={metrics['balanced_accuracy']} "
            f"confusion=[TP {metrics['true_positive']}, "
            f"FP {metrics['false_positive']}, FN {metrics['false_negative']}, "
            f"TN {metrics['true_negative']}]"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--run",
        type=Path,
        default=None,
        help="Fine-tuning run directory (defaults to latest completed run).",
    )
    parser.add_argument(
        "--query",
        type=str,
        default=None,
        help="Search one concern and print results for all three retrievers.",
    )
    parser.add_argument(
        "--top",
        type=int,
        default=10,
        help="Maximum articles to show per model in query mode (default: 10).",
    )
    parser.add_argument(
        "--evaluate",
        action="store_true",
        help="Evaluate on Testing only when the selected candidate has a valid test split.",
    )
    args = parser.parse_args()
    if args.top < 1:
        parser.error("--top must be positive.")
    if args.evaluate and args.query is not None:
        parser.error("Use --evaluate or --query, not both.")

    runs = sorted(
        (
            path
            for path in OUTPUT_ROOT.iterdir()
            if path.is_dir() and (path / "evaluation_report.json").is_file()
        ),
        key=lambda path: path.stat().st_mtime,
    ) if OUTPUT_ROOT.is_dir() else []
    run_directory = args.run or (runs[-1] if runs else None)
    if run_directory is None:
        raise SystemExit(
            f"No completed fine-tune run found under {OUTPUT_ROOT}; fine-tune first."
        )
    report_path = run_directory / "evaluation_report.json"
    if not report_path.is_file():
        raise SystemExit(f"Fine-tuning report not found: {report_path}")
    training_report = json.loads(report_path.read_text(encoding="utf-8"))
    if args.evaluate and not training_report.get("final_test_metrics_valid", True):
        raise SystemExit(
            "This candidate was trained using judgments from the previous "
            "Testing split. Those test results are retired; provide a new "
            "unseen test set before running a final test evaluation."
        )
    candidate_path = Path(training_report["candidate_model_path"])
    if not candidate_path.is_dir():
        raise SystemExit(f"Fine-tuned model not found: {candidate_path}")

    from sentence_transformers import SentenceTransformer

    base_model_path = Path(training_report.get("base_model_path") or _cached_model_path())
    base_model = SentenceTransformer(str(base_model_path), device="cpu")
    candidate_model = SentenceTransformer(str(candidate_path), device="cpu")
    ids, texts = _load_corpus()
    if len(ids) != int(training_report["corpus_articles"]):
        raise SystemExit("Current corpus size differs from the fine-tuned model report.")
    bundled_articles = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))

    if args.evaluate:
        _evaluation_report(
            run_directory,
            ids,
            texts,
            bundled_articles,
            base_model,
            candidate_model,
        )
        return

    if args.query is not None:
        queries = [args.query]
        interactive = False
    else:
        queries = []
        interactive = True
        print("CATALYST retrieval comparison (base MiniLM / fine-tuned SBERT / current E5 hybrid)")
        print("Type a legal concern; enter :quit to exit.")

    corpus_fingerprint = hashlib.sha256(
        "\n".join(f"{article_id}\t{text}" for article_id, text in zip(ids, texts)).encode(
            "utf-8"
        )
    ).hexdigest()[:16]
    base_vectors = _prepare_sbert_vectors(
        base_model,
        texts,
        run_directory / f"console_base_corpus_{corpus_fingerprint}.npy",
    )
    candidate_vectors = _prepare_sbert_vectors(
        candidate_model,
        texts,
        run_directory / f"console_candidate_corpus_{corpus_fingerprint}.npy",
    )
    e5 = ActiveE5Hybrid(ids, texts, bundled_articles)
    known_relevant: dict[str, set[str]] = defaultdict(set)
    previous_test_retired = training_report.get(
        "previous_testing_split_retired", False
    )
    if not previous_test_retired:
        for row in _read_rows(TEST_PATH):
            query_key = str(row["Sample Narrative"]).strip().casefold()
            if float(row["Relevance_Label"]) != 1.0:
                continue
            known_relevant[query_key].update(
                article_id.strip().casefold()
                for article_id in str(row["Applicable_Article_ID"]).split(",")
                if article_id.strip()
            )
    elif interactive:
        print("Prior Testing labels are hidden for this run because they were used in training.")

    while True:
        if interactive:
            try:
                query = input("\nConcern> ").strip()
            except (EOFError, KeyboardInterrupt):
                print()
                break
            if query.casefold() in {":q", ":quit", "exit", "quit"}:
                break
        else:
            query = queries[0]
        if not query:
            if interactive:
                print("Please enter a non-empty concern.")
                continue
            raise SystemExit("The query must not be empty.")

        base_ranking, base_scores = _rank_sbert(base_model, query, base_vectors)
        candidate_ranking, candidate_scores = _rank_sbert(
            candidate_model, query, candidate_vectors
        )
        e5_ranking, e5_scores = e5.rank(query)
        print(f"\nQuery: {query}")
        _print_article_results(
            "Base MiniLM cosine",
            base_ranking,
            base_scores,
            bundled_articles,
            args.top,
        )
        _print_article_results(
            "Fine-tuned SBERT cosine",
            candidate_ranking,
            candidate_scores,
            bundled_articles,
            args.top,
        )
        _print_article_results(
            "Current CATALYST E5 hybrid (raw-query approximation)",
            e5_ranking,
            e5_scores,
            bundled_articles,
            args.top,
        )
        _show_known_test_labels(
            query,
            known_relevant,
            {
                "Base MiniLM": base_ranking,
                "Fine-tuned SBERT": candidate_ranking,
                "Current E5 hybrid": e5_ranking,
            },
            ids,
        )
        if not interactive:
            return


if __name__ == "__main__":
    main()
