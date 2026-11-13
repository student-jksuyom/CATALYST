"""Offline A/B evaluation of article chunk segmentation; never writes app assets.

Run from the repository root with:
    .venv\\Scripts\\python tool\\retrieval_lab\\segmentation_experiment.py
"""

from __future__ import annotations

import ast
import hashlib
import json
import math
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer


ROOT = Path(__file__).resolve().parents[2]
ARTICLES_PATH = ROOT / "assets" / "data" / "legal_articles.json"
OWNERS_PATH = ROOT / "assets" / "data" / "chunk_owners_e5.json"
EMBEDDINGS_PATH = ROOT / "assets" / "data" / "chunk_embeddings_e5.f32"
TOKENIZER_PATH = ROOT / "assets" / "models" / "e5_tokenizer.json"
ENCODER_PATH = ROOT / "tool" / "retrieval_lab" / "e5" / "model.onnx"
CASES_PATH = ROOT / "tool" / "offline_eval" / "cases.json"
EVALUATION_DATASET_PATH = ROOT / "DATA" / "Datasets" / "Evaluationdataset.xlsx"
BASELINE_REPORT_PATH = ROOT / "tool" / "offline_eval" / "out" / "report.json"
OUTPUT_PATH = ROOT / "tool" / "retrieval_lab" / "out" / "segmentation_experiment.json"
VECTOR_CACHE_PATH = ROOT / "tool" / "retrieval_lab" / "out" / "segmentation_vectors_v2.npz"
GATE_THRESHOLDS = (0.79, 0.82, 0.84, 0.86, 0.88, 0.90, 0.92)
MINIMUM_SECTION_WORDS = 35

DIMENSIONS = 384
WORD_LIMIT = 75
WINDOW_WORDS = 60
WINDOW_STRIDE = 40
QUERY_POOL = 50
FUSION_K = 20
MINIMUM_COSINE = 0.79
DISPLAY_FLOOR = 0.75
DISPLAY_CEILING = 0.90
LEXICAL_WEIGHT = 0.15
RESULT_LIMIT = 15
ENUMERATOR_PATTERN = re.compile(
    r"(?P<paren_alpha>\([a-z]\))"
    r"|(?P<paren_number>\((?:0|[1-9]\d*)\))"
    r"|(?P<bare_alpha>(?<![A-Za-z0-9])[a-z]\))"
    r"|(?P<bare_number>(?<![A-Za-z0-9])(?:0|[1-9]\d*)\))",
    re.IGNORECASE,
)
WORD_PATTERN = re.compile(r"[A-Za-zÀ-ÿ0-9]+(?:['’-][A-Za-zÀ-ÿ0-9]+)*")


class BM25Index:
    """Port of the app's BM25 scoring over whole-article documents."""

    def __init__(self, documents: list[str]) -> None:
        source = (ROOT / "lib" / "services" / "lexical_index.dart").read_text(
            encoding="utf-8"
        )
        stopword_block = re.search(
            r"const _stopwords = <String>\{(.*?)\};", source, re.DOTALL
        )
        if stopword_block is None:
            raise ValueError("Could not load the app's BM25 stopword list.")
        self.stopwords = set(re.findall(r"'([^']+)'", stopword_block.group(1)))
        self.term_counts = [Counter(self._terms(document)) for document in documents]
        self.document_lengths = [sum(counts.values()) for counts in self.term_counts]
        self.average_length = sum(self.document_lengths) / max(len(documents), 1)
        document_frequency: Counter[str] = Counter()
        for counts in self.term_counts:
            document_frequency.update(counts.keys())
        self.idf = {
            term: math.log(
                1 + (len(documents) - frequency + 0.5) / (frequency + 0.5)
            )
            for term, frequency in document_frequency.items()
        }
        self.postings: dict[str, list[tuple[int, int]]] = defaultdict(list)
        for index, counts in enumerate(self.term_counts):
            for term, frequency in counts.items():
                self.postings[term].append((index, frequency))

    def _terms(self, text: str) -> list[str]:
        tokens = WORD_PATTERN.findall(text.lower().replace("’", "'"))
        output = []
        for token in tokens:
            if len(token) <= 1 or token in self.stopwords:
                continue
            if len(token) > 4 and token.endswith("ies"):
                token = token[:-3] + "y"
            elif len(token) > 5 and token.endswith("ing"):
                token = token[:-3]
            elif len(token) > 4 and token.endswith("ed"):
                token = token[:-2]
            elif len(token) > 4 and token.endswith("es"):
                token = token[:-2]
            elif len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
                token = token[:-1]
            output.append(token)
        return output

    def search(self, query: str, limit: int) -> list[tuple[int, float]]:
        scores: dict[int, float] = {}
        for term in dict.fromkeys(self._terms(query)):
            idf = self.idf.get(term)
            if idf is None:
                continue
            for index, frequency in self.postings[term]:
                normalization = (
                    1 - 0.75
                    + 0.75 * self.document_lengths[index] / self.average_length
                )
                scores[index] = scores.get(index, 0) + (
                    idf
                    * frequency
                    * 2.2
                    / (frequency + 1.2 * normalization)
                )
        return sorted(scores.items(), key=lambda item: (-item[1], item[0]))[:limit]


def _article_id(article: dict[str, str]) -> str:
    law = re.sub(r"[^a-z0-9]", "", article["Law"].casefold())
    number = re.sub(r"\s+", "", article["Article"]).casefold()
    return f"{law}:{number}"


def _word_chunks(text: str) -> list[str]:
    words = text.split()
    if len(words) <= WORD_LIMIT:
        return [text]
    chunks = []
    for start in range(0, len(words), WINDOW_STRIDE):
        chunks.append(" ".join(words[start : start + WINDOW_WORDS]))
        if start + WINDOW_WORDS >= len(words):
            break
    return chunks


def _current_word_chunks(text: str) -> list[str]:
    words = text.split()
    if len(words) <= WORD_LIMIT:
        return [" ".join(words)]
    chunks = []
    for start in range(0, min(len(words), WINDOW_STRIDE * 12), WINDOW_STRIDE):
        chunks.append(" ".join(words[start : start + WINDOW_WORDS]))
        if start + WINDOW_WORDS >= len(words):
            break
    return chunks


def _subsection_chunks(text: str, *, minimum_words: int = 0) -> list[str]:
    matches = list(ENUMERATOR_PATTERN.finditer(text))
    markers: dict[str, list[tuple[int, int, str]]] = {}
    for match in matches:
        style = match.lastgroup
        if style is None:
            continue
        label = match.group().strip().casefold()
        if style.endswith("alpha"):
            label = re.sub(r"[^a-z]", "", label)
            value = ord(label[-1]) - ord("a")
        else:
            value = int(re.sub(r"\D", "", label))
        markers.setdefault(style, []).append((match.start(), value, style))

    accepted_positions: set[int] = set()
    for entries in markers.values():
        for previous, following in zip(entries, entries[1:]):
            if following[1] == previous[1] + 1:
                accepted_positions.update((previous[0], following[0]))

    boundaries = sorted(accepted_positions)
    if not boundaries:
        return _word_chunks(text)

    sections = [
        text[start:end].strip()
        for start, end in zip([0, *boundaries], [*boundaries, len(text)])
        if text[start:end].strip()
    ]
    if minimum_words > 0:
        merged_sections = []
        pending = []
        pending_words = 0
        for section in sections:
            pending.append(section)
            pending_words += len(section.split())
            if pending_words >= minimum_words:
                merged_sections.append(" ".join(pending))
                pending = []
                pending_words = 0
        if pending:
            if merged_sections:
                merged_sections[-1] += " " + " ".join(pending)
            else:
                merged_sections.append(" ".join(pending))
        sections = merged_sections
    return [
        chunk
        for section in sections
        for chunk in _word_chunks(section)
    ]


def _embed(
    texts: list[str],
    tokenizer: Tokenizer,
    session: ort.InferenceSession,
    *,
    prefix: str,
    batch_size: int = 16,
) -> np.ndarray:
    encoded = [tokenizer.encode(prefix + text) for text in texts]
    order = sorted(range(len(encoded)), key=lambda index: len(encoded[index].ids))
    vectors = np.zeros((len(texts), DIMENSIONS), dtype=np.float32)
    for offset in range(0, len(order), batch_size):
        indexes = order[offset : offset + batch_size]
        width = max(len(encoded[index].ids) for index in indexes)
        input_ids = np.ones((len(indexes), width), dtype=np.int64)
        attention_mask = np.zeros((len(indexes), width), dtype=np.int64)
        for row, index in enumerate(indexes):
            ids = encoded[index].ids
            input_ids[row, : len(ids)] = ids
            attention_mask[row, : len(ids)] = 1
        feed = {"input_ids": input_ids, "attention_mask": attention_mask}
        if "token_type_ids" in {item.name for item in session.get_inputs()}:
            feed["token_type_ids"] = np.zeros_like(input_ids)
        hidden = session.run(None, feed)[0]
        mask = attention_mask[..., None]
        pooled = (hidden * mask).sum(axis=1) / mask.sum(axis=1).clip(min=1)
        norms = np.linalg.norm(pooled, axis=1, keepdims=True)
        pooled /= norms
        vectors[indexes] = pooled
    return vectors


class QueryAnalyzer:
    def __init__(self) -> None:
        source = (ROOT / "lib" / "services" / "query_analysis.dart").read_text(
            encoding="utf-8"
        )
        self.informal_spellings = self._read_dart_map(source, "informalSpellings")
        self.phrase_glossary = self._read_dart_map(source, "phraseGlossary")
        self.word_glossary = self._read_dart_map(source, "wordGlossary")

    @staticmethod
    def _read_dart_map(source: str, name: str) -> dict[str, Any]:
        match = re.search(
            rf"const _{name}\s*=\s*<[^{{]+>\s*\{{(.*?)\n\}};",
            source,
            re.DOTALL,
        )
        if match is None:
            raise ValueError(f"Could not load query-analysis map {name!r}.")
        return ast.literal_eval("{" + match.group(1) + "}")

    def analyze(self, query: str) -> dict[str, Any]:
        normalized = re.sub(r"\s+", " ", query)
        normalized = re.sub(
            r"([A-Za-z])\1{2,}", lambda match: match.group(1), normalized
        ).strip()

        def replace_spelling(match: re.Match[str]) -> str:
            word = match.group()
            replacement = self.informal_spellings.get(word.casefold())
            return word if replacement is None or "-" in replacement else replacement

        normalized = WORD_PATTERN.sub(replace_spelling, normalized)
        tokens = WORD_PATTERN.findall(normalized.lower().replace("’", "'"))
        remaining = f" {' '.join(tokens)} "
        glossary: list[str] = []

        def add(terms: list[str]) -> None:
            for term in terms:
                if term not in glossary:
                    glossary.append(term)

        for phrase, terms in self.phrase_glossary.items():
            needle = f" {phrase} "
            if needle in remaining:
                add(terms)
                remaining = remaining.replace(needle, " ")
        for token in tokens:
            add(self.word_glossary.get(token, []))
        if " mga anak " in f" {' '.join(tokens)} ":
            add(self.word_glossary["mga anak"])
        return {"normalized": normalized, "glossary": glossary}


def _summarize(
    rankings: list[list[int]],
    relevant_sets: list[set[str]],
    article_ids: list[str],
) -> dict[str, float | int]:
    positive = [
        (ranking, relevant)
        for ranking, relevant in zip(rankings, relevant_sets)
        if relevant
    ]
    n = len(positive)
    top1 = hit3 = hit10 = hit15 = 0
    reciprocal_rank = 0.0
    recall15 = 0.0
    for ranking, relevant in positive:
        ids = [article_ids[index] for index in ranking]
        top1 += bool(ids and ids[0] in relevant)
        hit3 += any(article_id in relevant for article_id in ids[:3])
        hit10 += any(article_id in relevant for article_id in ids[:10])
        hit15 += any(article_id in relevant for article_id in ids)
        hits = sum(article_id in relevant for article_id in ids)
        recall15 += hits / len(relevant) if relevant else 0.0
        first = next(
            (rank for rank, article_id in enumerate(ids, 1) if article_id in relevant),
            None,
        )
        if first is not None:
            reciprocal_rank += 1 / first
    return {
        "query_groups": len(rankings),
        "positive_query_groups": n,
        "negative_only_query_groups": len(rankings) - n,
        "top1": top1,
        "top1_rate": round(top1 / n, 4) if n else 0,
        "hit_at_3": hit3,
        "hit_at_3_rate": round(hit3 / n, 4) if n else 0,
        "hit_at_10": hit10,
        "hit_at_10_rate": round(hit10 / n, 4) if n else 0,
        "hit_at_15": hit15,
        "hit_at_15_rate": round(hit15 / n, 4) if n else 0,
        "mrr_at_15": round(reciprocal_rank / n, 4) if n else 0,
        "mean_recall_at_15": round(recall15 / n, 4) if n else 0,
    }


def main() -> None:
    articles = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))
    article_ids = [_article_id(article) for article in articles]
    texts = [article["Article Text"] for article in articles]
    owners = np.asarray(json.loads(OWNERS_PATH.read_text(encoding="utf-8")))
    baseline_vectors = np.fromfile(EMBEDDINGS_PATH, dtype="<f4").reshape(-1, DIMENSIONS)
    if len(owners) != len(baseline_vectors):
        raise ValueError("The packaged chunk-owner and embedding files disagree.")
    if owners.min() < 0 or owners.max() >= len(articles):
        raise ValueError("The packaged chunk index contains an invalid article id.")

    # The lab tokenizer dump is the source of the exact shipped owner sequence.
    owner_path = ROOT / "tool" / "retrieval_lab" / "out" / "chunk_owner.json"
    lab_owners = json.loads(owner_path.read_text(encoding="utf-8"))
    if lab_owners != owners.tolist():
        raise ValueError("The lab chunk mapping differs from the packaged index.")

    tokenizer = Tokenizer.from_file(str(TOKENIZER_PATH))
    tokenizer.enable_truncation(max_length=256)
    session_options = ort.SessionOptions()
    session_options.intra_op_num_threads = 2
    session_options.inter_op_num_threads = 1
    session = ort.InferenceSession(
        str(ENCODER_PATH),
        sess_options=session_options,
        providers=["CPUExecutionProvider"],
    )

    pilot_cases = json.loads(CASES_PATH.read_text(encoding="utf-8"))
    analyzer = QueryAnalyzer()

    import pandas as pd

    evaluation_rows = pd.read_excel(EVALUATION_DATASET_PATH).to_dict("records")
    evaluation_groups: dict[str, dict[str, Any]] = {}
    article_id_set = set(article_ids)
    for row in evaluation_rows:
        query = str(row["Sample Narrative"]).strip()
        key = query.casefold()
        group = evaluation_groups.setdefault(
            key,
            {
                "datasetId": str(row["Narrative_ID"]),
                "language": str(row["Language"]),
                "query": query,
                "reviewedRelevantArticleIds": set(),
                "labels": {},
            },
        )
        label = int(row["Relevance_Label"])
        article_ids_in_row = [
            item.strip().casefold()
            for item in str(row["Applicable_Article_ID"]).split(",")
            if item.strip()
        ]
        if not article_ids_in_row:
            raise ValueError(f"Evaluation data row for {key!r} has no article ids.")
        for article_id in article_ids_in_row:
            if article_id not in article_id_set:
                raise ValueError(
                    f"Evaluation data references unknown article {article_id!r}."
                )
            previous = group["labels"].get(article_id)
            if previous is not None and previous != label:
                raise ValueError(
                    f"Conflicting evaluation labels for {key!r}, {article_id}."
                )
            group["labels"][article_id] = label
            if label == 1:
                group["reviewedRelevantArticleIds"].add(article_id)
    confirmatory_cases = [
        {
            **group,
            "reviewedRelevantArticleIds": sorted(
                group["reviewedRelevantArticleIds"]
            ),
            "evaluation_set": "confirmatory_evaluation_split",
        }
        for group in evaluation_groups.values()
    ]
    cases = [
        {**case, "evaluation_set": "pilot"}
        for case in pilot_cases
    ] + confirmatory_cases

    query_texts: list[str] = []
    case_analyses = []
    for case in cases:
        analysis = analyzer.analyze(case["query"])
        case_analyses.append(analysis)
        query_texts.append(analysis["normalized"])
        if analysis["glossary"]:
            query_texts.append(" ".join(analysis["glossary"]))
    probes = [
        "What is the best recipe for chicken adobo?",
        "Who won the basketball game last night?",
        "asdf qwer zxcv uiop",
        "How do I install a graphics driver on my laptop?",
        "Ano ang magandang lugar para mag-bakasyon sa Palawan?",
        "Anong oras magbubukas ang mall bukas?",
    ]
    query_texts.extend(probes)

    query_tokenizer = Tokenizer.from_file(str(TOKENIZER_PATH))
    query_tokenizer.enable_truncation(max_length=128)
    query_vectors_all = _embed(
        query_texts,
        query_tokenizer,
        session,
        prefix="query: ",
    )
    query_vectors: dict[str, np.ndarray] = {}
    for text, vector in zip(query_texts, query_vectors_all):
        query_vectors[text] = vector

    # The three cases differ only in dense passage segmentation. BM25 and all
    # production ranking parameters stay fixed.
    subsection_chunks_by_article = [_subsection_chunks(text) for text in texts]
    merged_subsection_chunks_by_article = [
        _subsection_chunks(text, minimum_words=MINIMUM_SECTION_WORDS)
        for text in texts
    ]

    current_index = (baseline_vectors, owners)

    def flatten_chunks(
        chunks_by_article: list[list[str]],
    ) -> tuple[list[str], np.ndarray]:
        chunk_texts = []
        chunk_owners = []
        for article_index, chunks in enumerate(chunks_by_article):
            chunk_texts.extend(chunks)
            chunk_owners.extend([article_index] * len(chunks))
        return chunk_texts, np.asarray(chunk_owners, dtype=np.int32)

    window_chunks_by_article = [
        _word_chunks(text) for text in texts
    ]
    current_chunks_by_article = [_current_word_chunks(text) for text in texts]
    current_texts, current_text_owners = flatten_chunks(current_chunks_by_article)
    if len(current_texts) != len(owners) or not np.array_equal(
        current_text_owners, owners
    ):
        raise ValueError("Reconstructed current chunk index differs from production.")
    window_texts, window_owners = flatten_chunks(window_chunks_by_article)
    subsection_texts, subsection_owners = flatten_chunks(subsection_chunks_by_article)
    merged_subsection_texts, merged_subsection_owners = flatten_chunks(
        merged_subsection_chunks_by_article
    )
    print(
        f"Articles={len(articles)}; shipped_chunks={len(owners)}; "
        f"uncapped_windows={len(window_texts)}; "
        f"subsection_chunks={len(subsection_texts)}; "
        f"merged_subsection_chunks={len(merged_subsection_texts)}",
        flush=True,
    )
    fingerprints = [
        hashlib.sha256(
            json.dumps(chunks, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        ).hexdigest()
        for chunks in (window_texts, subsection_texts, merged_subsection_texts)
    ]
    cached_vectors = None
    if VECTOR_CACHE_PATH.is_file():
        with np.load(VECTOR_CACHE_PATH) as cache:
            if cache["fingerprints"].tolist() == fingerprints:
                cached_vectors = (
                    cache["window_vectors"].copy(),
                    cache["window_owners"].copy(),
                    cache["subsection_vectors"].copy(),
                    cache["subsection_owners"].copy(),
                    cache["merged_subsection_vectors"].copy(),
                    cache["merged_subsection_owners"].copy(),
                )
    if cached_vectors is None:
        window_vectors = _embed(
            window_texts, tokenizer, session, prefix="passage: "
        )
        subsection_vectors = _embed(
            subsection_texts, tokenizer, session, prefix="passage: "
        )
        merged_subsection_vectors = _embed(
            merged_subsection_texts, tokenizer, session, prefix="passage: "
        )
        np.savez_compressed(
            VECTOR_CACHE_PATH,
            fingerprints=np.asarray(fingerprints),
            window_vectors=window_vectors,
            window_owners=window_owners,
            subsection_vectors=subsection_vectors,
            subsection_owners=subsection_owners,
            merged_subsection_vectors=merged_subsection_vectors,
            merged_subsection_owners=merged_subsection_owners,
        )
    else:
        (
            window_vectors,
            window_owners,
            subsection_vectors,
            subsection_owners,
            merged_subsection_vectors,
            merged_subsection_owners,
        ) = cached_vectors

    lexical_index = BM25Index(texts)
    report_rows = json.loads(BASELINE_REPORT_PATH.read_text(encoding="utf-8"))
    exact_baseline = {
        (str(row["datasetId"]), row["query"]): row["all"]
        for row in report_rows
        if row["strategy"] == "hybrid" and row["mode"] == "baseline"
    }
    results: dict[str, list[list[int]]] = {
        "current_production_index": [],
        "uncapped_word_windows": [],
        "subsection_aware": [],
        "subsection_aware_min35": [],
    }
    results_by_gate = {
        f"{threshold:.2f}": {
            name: [] for name in results
        }
        for threshold in GATE_THRESHOLDS
    }
    detailed = []

    for case, analysis in zip(cases, case_analyses):
        variants = [analysis["normalized"]]
        glossary_query = " ".join(analysis["glossary"])
        if glossary_query and glossary_query not in variants:
            variants.append(glossary_query)
        vectors = [query_vectors[text] for text in variants]
        lexical_query = " ".join(
            [case["query"], case["query"], *analysis["glossary"]]
        )

        scenario_rankings = {}
        query_rankings_by_gate = {
            f"{threshold:.2f}": {} for threshold in GATE_THRESHOLDS
        }
        for name, matrix, matrix_owners in (
            ("current_production_index", *current_index),
            ("uncapped_word_windows", window_vectors, window_owners),
            ("subsection_aware", subsection_vectors, subsection_owners),
            (
                "subsection_aware_min35",
                merged_subsection_vectors,
                merged_subsection_owners,
            ),
        ):
            article_scores = np.full((len(matrix_owners), len(vectors)), -1.0, dtype=np.float32)
            for variant_index, vector in enumerate(vectors):
                chunk_scores = matrix @ vector
                np.maximum.at(article_scores[:, variant_index], matrix_owners, chunk_scores)
            best_cosine = article_scores.max(axis=1)
            mean_cosine = article_scores.mean(axis=1)
            dense_lists = [
                np.argsort(-article_scores[:, variant], kind="stable")[:QUERY_POOL]
                for variant in range(len(vectors))
            ]
            lexical_hits = lexical_index.search(lexical_query, QUERY_POOL)
            lexical_order = [index for index, _ in lexical_hits]
            lexical_scores = dict(lexical_hits)
            fused_scores: dict[int, float] = {}
            rankings = [*dense_lists]
            if lexical_order:
                rankings.append(lexical_order)
            for ranking in rankings:
                for rank, article_index in enumerate(ranking):
                    fused_scores[article_index] = fused_scores.get(article_index, 0) + 1 / (
                        FUSION_K + rank + 1
                    )
            fused_order = sorted(fused_scores, key=lambda index: -fused_scores[index])
            max_lexical = lexical_scores[lexical_order[0]] if lexical_order else 0.0

            def blended(index: int) -> float:
                dense = min(
                    max((mean_cosine[index] - DISPLAY_FLOOR) /
                        (DISPLAY_CEILING - DISPLAY_FLOOR), 0),
                    1,
                )
                lexical = lexical_scores.get(index, 0.0) / max_lexical if max_lexical else 0.0
                return (1 - LEXICAL_WEIGHT) * dense + LEXICAL_WEIGHT * lexical

            def rank_at_gate(threshold: float) -> list[int]:
                eligible = [
                    index for index in fused_order
                    if best_cosine[index] >= threshold
                ]
                eligible.sort(key=lambda index: -blended(index))
                ranked = []
                seen = set()
                for index in eligible:
                    if article_ids[index] in seen:
                        continue
                    seen.add(article_ids[index])
                    ranked.append(index)
                    if len(ranked) == RESULT_LIMIT:
                        break
                return ranked

            ranked_by_gate = {
                f"{threshold:.2f}": rank_at_gate(threshold)
                for threshold in GATE_THRESHOLDS
            }
            ranked = ranked_by_gate[f"{MINIMUM_COSINE:.2f}"]
            scenario_rankings[name] = ranked
            results[name].append(ranked)
            for threshold, gated_ranking in ranked_by_gate.items():
                results_by_gate[threshold][name].append(gated_ranking)
                query_rankings_by_gate[threshold][name] = gated_ranking

        baseline_ids = [
            article_ids[index]
            for index in scenario_rankings["current_production_index"]
        ]
        expected = exact_baseline.get((str(case["datasetId"]), case["query"]))
        detailed.append(
            {
                "dataset_id": case["datasetId"],
                "evaluation_set": case["evaluation_set"],
                "language": case["language"],
                "query": case["query"],
                "relevant": case["reviewedRelevantArticleIds"],
                "baseline_matches_saved_production_eval": (
                    expected[:RESULT_LIMIT] == baseline_ids
                    if expected is not None
                    else None
                ),
                "saved_production_results": (
                    expected[:RESULT_LIMIT] if expected is not None else None
                ),
                "rankings": {
                    name: [article_ids[index] for index in ranked]
                    for name, ranked in scenario_rankings.items()
                },
                "rankings_by_cosine_gate": {
                    threshold: {
                        name: [article_ids[index] for index in ranked]
                        for name, ranked in gated_rankings.items()
                    }
                    for threshold, gated_rankings in query_rankings_by_gate.items()
                },
                "relevant_ranks": {
                    name: next(
                        (rank for rank, index in enumerate(ranked, 1)
                         if article_ids[index] in case["reviewedRelevantArticleIds"]),
                        None,
                    )
                    for name, ranked in scenario_rankings.items()
                },
                "relevant_ranks_by_cosine_gate": {
                    threshold: {
                        name: next(
                            (
                                rank
                                for rank, index in enumerate(ranked, 1)
                                if article_ids[index]
                                in case["reviewedRelevantArticleIds"]
                            ),
                            None,
                        )
                        for name, ranked in gated_rankings.items()
                    }
                    for threshold, gated_rankings in query_rankings_by_gate.items()
                },
            }
        )

    relevant_sets = [set(case["reviewedRelevantArticleIds"]) for case in cases]
    summaries = {}
    for evaluation_set in ("pilot", "confirmatory_evaluation_split"):
        indexes = [
            index
            for index, case in enumerate(cases)
            if case["evaluation_set"] == evaluation_set
        ]
        summaries[evaluation_set] = {
            name: _summarize(
                [rankings[index] for index in indexes],
                [relevant_sets[index] for index in indexes],
                article_ids,
            )
            for name, rankings in results.items()
        }
    gate_summaries = {}
    for threshold, scenario_results in results_by_gate.items():
        gate_summaries[threshold] = {}
        for evaluation_set in ("pilot", "confirmatory_evaluation_split"):
            indexes = [
                index
                for index, case in enumerate(cases)
                if case["evaluation_set"] == evaluation_set
            ]
            gate_summaries[threshold][evaluation_set] = {
                name: _summarize(
                    [rankings[index] for index in indexes],
                    [relevant_sets[index] for index in indexes],
                    article_ids,
                )
                for name, rankings in scenario_results.items()
            }

    def chunk_profile(chunks: list[str]) -> dict[str, Any]:
            word_counts = np.asarray([len(chunk.split()) for chunk in chunks])
            token_profile = Tokenizer.from_file(str(TOKENIZER_PATH))
            token_counts = np.asarray(
                [len(token_profile.encode("passage: " + chunk).ids) for chunk in chunks]
            )
            return {
                "chunks": len(chunks),
                "word_count": {
                    "p10": int(np.percentile(word_counts, 10)),
                    "median": float(np.median(word_counts)),
                    "p90": int(np.percentile(word_counts, 90)),
                    "under_10": int(np.sum(word_counts < 10)),
                    "under_20": int(np.sum(word_counts < 20)),
                },
                "token_count": {
                    "p10": int(np.percentile(token_counts, 10)),
                    "median": float(np.median(token_counts)),
                    "p90": int(np.percentile(token_counts, 90)),
                    "over_256": int(np.sum(token_counts > 256)),
                },
            }

    off_topic = []
    for probe in probes:
        vector = query_vectors[probe]
        outcomes = {}
        for name, matrix, matrix_owners in (
            ("current_production_index", *current_index),
            ("uncapped_word_windows", window_vectors, window_owners),
            ("subsection_aware", subsection_vectors, subsection_owners),
            (
                "subsection_aware_min35",
                merged_subsection_vectors,
                merged_subsection_owners,
            ),
        ):
            chunk_scores = matrix @ vector
            best = np.full(len(articles), -1.0, dtype=np.float32)
            np.maximum.at(best, matrix_owners, chunk_scores)
            lexical_hits = lexical_index.search(
                " ".join((probe, probe)), QUERY_POOL
            )
            dense_order = np.argsort(-best, kind="stable")[:QUERY_POOL]
            rankings = [dense_order.tolist()]
            if lexical_hits:
                rankings.append([index for index, _ in lexical_hits])
            fused: dict[int, float] = {}
            for ranking in rankings:
                for rank, index in enumerate(ranking):
                    fused[index] = fused.get(index, 0) + 1 / (
                        FUSION_K + rank + 1
                    )
            max_lexical = lexical_hits[0][1] if lexical_hits else 0.0
            lexical_scores = dict(lexical_hits)
            outcomes[name] = {}
            for threshold in GATE_THRESHOLDS:
                eligible = [
                    index
                    for index in sorted(fused, key=lambda index: -fused[index])
                    if best[index] >= threshold
                ]

                def blended_off_topic(index: int) -> float:
                    dense = min(
                        max(
                            (float(best[index]) - DISPLAY_FLOOR)
                            / (DISPLAY_CEILING - DISPLAY_FLOOR),
                            0,
                        ),
                        1,
                    )
                    lexical = (
                        lexical_scores.get(index, 0.0) / max_lexical
                        if max_lexical
                        else 0.0
                    )
                    return (1 - LEXICAL_WEIGHT) * dense + LEXICAL_WEIGHT * lexical

                eligible.sort(key=lambda index: -blended_off_topic(index))
                seen = set()
                returned = []
                for index in eligible:
                    if article_ids[index] in seen:
                        continue
                    seen.add(article_ids[index])
                    returned.append(article_ids[index])
                    if len(returned) == RESULT_LIMIT:
                        break
                outcomes[name][f"{threshold:.2f}"] = {
                    "eligible_articles": int(np.sum(best >= threshold)),
                    "returned_results": len(returned),
                    "top_results": returned,
                }
        off_topic.append({"query": probe, "results": outcomes})

    checked_rows = [
        row
        for row in detailed
        if row["baseline_matches_saved_production_eval"] is not None
    ]
    mismatch_count = sum(
        row["baseline_matches_saved_production_eval"] is False for row in detailed
    )
    report = {
        "experiment": "paragraph/subsection-aware dense chunk segmentation",
        "production_assets_modified": False,
        "inputs": {
            "articles": len(articles),
            "query_groups_by_set": {
                evaluation_set: sum(
                    case["evaluation_set"] == evaluation_set for case in cases
                )
                for evaluation_set in ("pilot", "confirmatory_evaluation_split")
            },
            "confirmatory_evaluation_rows": len(evaluation_rows),
            "confirmatory_label_policy": (
                "Only label-1 article ids count as relevant; negative-only query "
                "groups are excluded from positive retrieval metrics."
            ),
            "corpus_chunks_current": len(owners),
            "corpus_chunks_uncapped_windows": len(window_owners),
            "corpus_chunks_subsection_aware": len(subsection_owners),
            "corpus_chunks_subsection_aware_min35": len(merged_subsection_owners),
            "chunk_profiles": {
                "current_production_index": chunk_profile(
                    current_texts
                ),
                "uncapped_word_windows": chunk_profile(window_texts),
                "subsection_aware": chunk_profile(subsection_texts),
                "subsection_aware_min35": chunk_profile(merged_subsection_texts),
            },
            "section_boundary_rule": (
                "Split at sequential same-style a)/b), (a)/(b), 1)/2), or "
                "(1)/(2) enumerators; split oversized sections into 60-word "
                "windows with 40-word stride; preserve all source text. The "
                "min35 variant merges adjacent sections until they contain at "
                f"least {MINIMUM_SECTION_WORDS} words."
            ),
            "shared_parameters": {
                "encoder": "multilingual-e5-small ONNX; 384-d; L2 normalized",
                "passage_prefix": "passage: ",
                "passage_token_limit": 256,
                "query_prefix": "query: ",
                "query_token_limit": 128,
                "bm25_documents": "whole articles (unchanged)",
                "candidate_pool": QUERY_POOL,
                "rrf_k": FUSION_K,
                "dense_weight": 1 - LEXICAL_WEIGHT,
                "bm25_weight": LEXICAL_WEIGHT,
                "minimum_cosine": MINIMUM_COSINE,
                "top_results": RESULT_LIMIT,
            },
        },
        "production_baseline_parity": {
            "matched_saved_production_evaluation": len(checked_rows) - mismatch_count,
            "queries_checked": len(checked_rows),
            "mismatch_count": mismatch_count,
        },
        "metrics": summaries,
        "cosine_gate_sweep": gate_summaries,
        "off_topic_gate_probe": off_topic,
        "per_query": detailed,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {
                "metrics": summaries,
                "cosine_gate_sweep": gate_summaries,
                "production_parity": report["production_baseline_parity"],
                "output": str(OUTPUT_PATH),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
