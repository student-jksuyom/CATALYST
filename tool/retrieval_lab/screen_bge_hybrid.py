"""Screen BGE-M3 in the current hybrid ranking pipeline on development data."""

from __future__ import annotations

import ast
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any

import numpy as np

from screen_multilingual_models import _current_word_chunks, _encode
from segmentation_experiment import BM25Index, QueryAnalyzer
import export_training_query_index


ROOT = Path(__file__).resolve().parents[2]
ARTICLES_PATH = ROOT / "assets" / "data" / "legal_articles.json"
EVALUATION_REPORT_PATH = (
    ROOT / "tool" / "offline_eval" / "out" / "current_app_eval" / "report.json"
)
OUTPUT_ROOT = ROOT / "tool" / "retrieval_lab" / "out" / "model_screening"
ENCODER_ID = "BAAI/bge-m3"
DIMENSIONS = 1024
QUERY_POOL = 50
FUSION_K = 20
MINIMUM_COSINE = 0.80
DISPLAY_FLOOR = 0.75
DISPLAY_CEILING = 0.90
LEXICAL_WEIGHT = 0.15
TRAINING_SIGNAL_WEIGHT = 0.30
MINIMUM_TRAINING_QUERY_COSINE = 0.90
TRAINING_NEIGHBOR_COUNT = 3
RESULT_LIMIT = 15
WORD_PATTERN = re.compile(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*")


def _article_id(law: str, number: str) -> str:
    normalized_law = re.sub(r"[^a-z0-9]", "", law.casefold())
    normalized_number = re.sub(r"\s+", "", number).casefold()
    return f"{normalized_law}:{normalized_number}"


def _dart_set(source: str, name: str) -> set[str]:
    match = re.search(
        rf"const _{name}\s*=\s*\{{(.*?)\n\}};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise ValueError(f"Could not load query cue set {name!r}.")
    return set(re.findall(r"'([^']+)'", match.group(1)))


def _legal_wording(source: str) -> dict[str, list[str]]:
    match = re.search(
        r"const _legalWording\s*=\s*<String,\s*List<String>>\s*\{(.*?)\n\};",
        source,
        re.DOTALL,
    )
    if match is None:
        raise ValueError("Could not load legal wording expansions.")
    return ast.literal_eval("{" + match.group(1) + "}")


def _query_domain(
    query: str,
    analyzer: QueryAnalyzer,
    family_cues: set[str],
    consumer_cues: set[str],
    civil_cues: set[str],
) -> str:
    tokens = WORD_PATTERN.findall(analyzer.analyze(query)["normalized"].lower())
    counts = (
        sum(token in family_cues for token in tokens),
        sum(token in consumer_cues for token in tokens),
        sum(token in civil_cues for token in tokens),
    )
    best = max(counts)
    if best == 0:
        return "unknown"
    if counts[0] == best:
        return "family"
    if counts[1] == best:
        return "consumer"
    return "civil"


def _load_cases() -> list[dict[str, Any]]:
    rows = json.loads(EVALUATION_REPORT_PATH.read_text(encoding="utf-8"))
    cases = [
        row
        for row in rows
        if row["strategy"] == "hybrid" and row["mode"] == "baseline"
    ]
    if not cases:
        raise ValueError("The current app evaluation report has no baseline cases.")
    return cases


def _load_bge_training_examples(
    article_ids: list[str],
) -> list[dict[str, Any]]:
    article_indices: dict[str, int] = {}
    for index, article_id in enumerate(article_ids):
        article_indices.setdefault(
            re.sub(r"[^a-z0-9]", "", article_id.casefold()),
            index,
        )
    return export_training_query_index._load_training_examples(article_indices)


def _training_vote(
    query_vector: np.ndarray,
    domain: str,
    training_vectors: np.ndarray,
    examples: list[dict[str, Any]],
) -> tuple[list[int], dict[int, float]]:
    if domain == "unknown":
        return [], {}
    matches = []
    for index, example in enumerate(examples):
        if example["domain"] != domain:
            continue
        matches.append((index, float(training_vectors[index] @ query_vector)))
    matches.sort(key=lambda item: (-item[1], item[0]))
    if not matches or matches[0][1] < MINIMUM_TRAINING_QUERY_COSINE:
        return [], {}

    votes: dict[int, float] = {}
    neighbor_rank = 0
    for index, similarity in matches:
        if neighbor_rank == TRAINING_NEIGHBOR_COUNT:
            break
        if similarity < MINIMUM_TRAINING_QUERY_COSINE:
            break
        weight = similarity**3 / np.sqrt(neighbor_rank + 1)
        neighbor_rank += 1
        for article_index in examples[index]["positive"]:
            votes[article_index] = votes.get(article_index, 0.0) + weight
        for article_index in examples[index]["negative"]:
            votes[article_index] = votes.get(article_index, 0.0) - weight

    positive_votes = {
        index: score for index, score in votes.items() if score > 0
    }
    if not positive_votes:
        return [], {}
    maximum = max(positive_votes.values())
    ranked = sorted(positive_votes, key=lambda index: (-positive_votes[index], index))
    ranked = ranked[:QUERY_POOL]
    return ranked, {index: positive_votes[index] / maximum for index in ranked}


def _fuse_rankings(rankings: list[list[int]]) -> list[int]:
    fused: dict[int, float] = {}
    for ranking in rankings:
        for rank, index in enumerate(ranking):
            fused[index] = fused.get(index, 0.0) + 1 / (FUSION_K + rank + 1)
    return sorted(fused, key=lambda index: (-fused[index], index))


def _rank_case(
    case: dict[str, Any],
    article_ids: list[str],
    chunk_vectors: np.ndarray,
    owners: np.ndarray,
    query_vectors: dict[str, np.ndarray],
    training_vectors: np.ndarray,
    training_examples: list[dict[str, Any]],
    lexical_index: BM25Index,
    analyzer: QueryAnalyzer,
    legal_words: dict[str, list[str]],
    family_cues: set[str],
    consumer_cues: set[str],
    civil_cues: set[str],
) -> dict[str, Any]:
    analysis = analyzer.analyze(case["query"])
    variants = [analysis["normalized"]]
    glossary_query = " ".join(analysis["glossary"])
    if glossary_query and glossary_query not in variants:
        variants.append(glossary_query)

    articles_count = len(article_ids)
    best_cosine = np.full(articles_count, -1.0, dtype=np.float32)
    cosine_sum = np.zeros(articles_count, dtype=np.float32)
    dense_lists = []
    for variant in variants:
        scores = chunk_vectors @ query_vectors[variant]
        article_scores = np.full(articles_count, -1.0, dtype=np.float32)
        np.maximum.at(article_scores, owners, scores)
        best_cosine = np.maximum(best_cosine, article_scores)
        cosine_sum += article_scores
        dense_lists.append(np.argsort(-article_scores, kind="stable")[:QUERY_POOL].tolist())

    lexical_terms = []
    for token in WORD_PATTERN.findall(case["query"].lower().replace("’", "'")):
        lexical_terms.extend(legal_words.get(token, []))
    lexical_query = " ".join(
        [
            case["query"],
            case["query"],
            *analysis["glossary"],
            *lexical_terms,
        ]
    )
    lexical_hits = lexical_index.search(lexical_query, QUERY_POOL)
    lexical_order = [index for index, _ in lexical_hits]
    lexical_scores = dict(lexical_hits)

    primary_vector = query_vectors[analysis["normalized"]]
    domain = _query_domain(
        case["query"], analyzer, family_cues, consumer_cues, civil_cues
    )
    training_order, training_votes = _training_vote(
        primary_vector, domain, training_vectors, training_examples
    )
    rankings = [*dense_lists]
    if lexical_order:
        rankings.append(lexical_order)
    if training_order:
        rankings.append(training_order)
    fused_order = _fuse_rankings(rankings)

    maximum_lexical = lexical_hits[0][1] if lexical_hits else 0.0
    mean_cosine = cosine_sum / len(variants)

    def blended_score(index: int) -> float:
        dense = min(
            max(
                (float(mean_cosine[index]) - DISPLAY_FLOOR)
                / (DISPLAY_CEILING - DISPLAY_FLOOR),
                0.0,
            ),
            1.0,
        )
        lexical = (
            lexical_scores.get(index, 0.0) / maximum_lexical
            if maximum_lexical > 0
            else 0.0
        )
        corpus_score = (1 - LEXICAL_WEIGHT) * dense + LEXICAL_WEIGHT * lexical
        training = training_votes.get(index, 0.0)
        return (1 - TRAINING_SIGNAL_WEIGHT) * corpus_score + TRAINING_SIGNAL_WEIGHT * training

    eligible = [
        index for index in fused_order if best_cosine[index] >= MINIMUM_COSINE
    ]
    eligible.sort(key=lambda index: -blended_score(index))
    unique_ids = []
    seen = set()
    for index in eligible:
        article_id = article_ids[index]
        if article_id in seen:
            continue
        seen.add(article_id)
        unique_ids.append(article_id)
        if len(unique_ids) == RESULT_LIMIT:
            break

    relevant = set(case["relevant"])
    first_rank = next(
        (rank for rank, article_id in enumerate(unique_ids, 1) if article_id in relevant),
        None,
    )
    return {
        "datasetId": case["datasetId"],
        "language": case["language"],
        "query": case["query"],
        "relevantArticleIds": sorted(relevant),
        "firstRelevantRank": first_rank,
        "top3": unique_ids[:3],
        "top15": unique_ids,
    }


def _metrics(cases: list[dict[str, Any]]) -> dict[str, Any]:
    positive = [case for case in cases if case["relevantArticleIds"]]
    count = len(positive)
    return {
        "positiveQueryGroups": count,
        "top1": sum(case["firstRelevantRank"] == 1 for case in positive),
        "hit3": sum(
            case["firstRelevantRank"] is not None
            and case["firstRelevantRank"] <= 3
            for case in positive
        ),
        "hit15": sum(
            case["firstRelevantRank"] is not None
            and case["firstRelevantRank"] <= 15
            for case in positive
        ),
        "mrr15": sum(
            1 / case["firstRelevantRank"]
            if case["firstRelevantRank"] is not None
            and case["firstRelevantRank"] <= 15
            else 0
            for case in positive
        )
        / count
        if count
        else 0,
    }


def main() -> None:
    import torch

    articles = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))
    article_ids = [_article_id(article["Law"], article["Article"]) for article in articles]
    chunk_texts = []
    owners = []
    for article_index, article in enumerate(articles):
        chunks = _current_word_chunks(article["Article Text"])
        chunk_texts.extend(chunks)
        owners.extend([article_index] * len(chunks))
    owner_array = np.asarray(owners, dtype=np.int32)

    cases = _load_cases()
    training_examples = _load_bge_training_examples(article_ids)
    analyzer = QueryAnalyzer()
    query_analysis = {case["query"]: analyzer.analyze(case["query"]) for case in cases}
    query_texts = set()
    for analysis in query_analysis.values():
        query_texts.add(analysis["normalized"])
        glossary = " ".join(analysis["glossary"])
        if glossary:
            query_texts.add(glossary)
    training_queries = [example["query"] for example in training_examples]
    all_texts = chunk_texts + list(query_texts) + training_queries

    analysis_source = (
        ROOT / "lib" / "services" / "query_analysis.dart"
    ).read_text(encoding="utf-8")
    family_cues = _dart_set(analysis_source, "familyCues")
    consumer_cues = _dart_set(analysis_source, "consumerCues")
    civil_cues = _dart_set(analysis_source, "civilCues")
    legal_words = _legal_wording(analysis_source)

    device = "cuda" if torch.cuda.is_available() else "cpu"
    print(f"Encoding BGE-M3 hybrid inputs on {device}")
    vectors = _encode(
        ENCODER_ID,
        "bge",
        all_texts,
        role="passage",
        device=device,
    )
    chunk_vectors = vectors[: len(chunk_texts)]
    query_start = len(chunk_texts)
    query_vector_list = vectors[query_start : query_start + len(query_texts)]
    query_vectors = dict(zip(query_texts, query_vector_list))
    training_vectors = vectors[query_start + len(query_texts) :]
    if training_vectors.shape != (len(training_examples), DIMENSIONS):
        raise ValueError("BGE-M3 training-query embeddings have an invalid shape.")

    lexical_index = BM25Index([article["Article Text"] for article in articles])
    results = [
        _rank_case(
            case,
            article_ids,
            chunk_vectors,
            owner_array,
            query_vectors,
            training_vectors,
            training_examples,
            lexical_index,
            analyzer,
            legal_words,
            family_cues,
            consumer_cues,
            civil_cues,
        )
        for case in cases
    ]
    current_app = _metrics(
        [
            {
                **case,
                "firstRelevantRank": next(
                    (
                        rank
                        for rank, article_id in enumerate(case["all"], 1)
                        if article_id in set(case["relevant"])
                    ),
                    None,
                ),
                "relevantArticleIds": case["relevant"],
            }
            for case in cases
        ]
    )
    report = {
        "createdAt": datetime.now().astimezone().isoformat(),
        "dataset": "DATA/Datasets/Evaluationdataset.xlsx",
        "heldoutUsed": False,
        "datasetStatus": "development-only; labels are not independent legal ground truth",
        "encoder": ENCODER_ID,
        "device": device,
        "method": (
            "BGE-M3 substituted for E5 vectors in the current hybrid algorithm: "
            "same article chunks, glossary query variants, BM25, reciprocal-rank "
            "fusion, cosine gate, score blend, and domain-filtered labeled-query "
            "votes. The production thresholds and weights were not tuned."
        ),
        "parameters": {
            "dimensions": DIMENSIONS,
            "minimumCosine": MINIMUM_COSINE,
            "minimumTrainingQueryCosine": MINIMUM_TRAINING_QUERY_COSINE,
            "fusionK": FUSION_K,
            "candidatePool": QUERY_POOL,
            "lexicalWeight": LEXICAL_WEIGHT,
            "trainingSignalWeight": TRAINING_SIGNAL_WEIGHT,
            "chunkCount": len(chunk_texts),
            "trainingQueryCount": len(training_examples),
        },
        "currentAppE5Hybrid": current_app,
        "bgeM3Hybrid": _metrics(results),
        "cases": results,
    }
    OUTPUT_ROOT.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_ROOT / f"{datetime.now():%Y%m%d_%H%M%S}_bge_hybrid_report.json"
    output_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print("Current app:", json.dumps(current_app, sort_keys=True))
    print("BGE-M3 hybrid:", json.dumps(report["bgeM3Hybrid"], sort_keys=True))
    print(f"Saved {output_path.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
