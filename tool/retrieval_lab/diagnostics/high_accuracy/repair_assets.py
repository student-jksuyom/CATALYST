"""Build a staged, auditable corpus repair without changing app assets.

Run from the repository root with Python, numpy, onnxruntime and tokenizers.
After the repair is applied, pass --source-dir pointing to the original assets.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "tool" / "retrieval_lab"))
from segmentation_experiment import (  # noqa: E402
    _current_word_chunks,
    _embed,
    _word_chunks,
)
from export_training_query_index import _index_articles, _load_training_examples  # noqa: E402

OUTPUT = Path(__file__).resolve().parent / "repaired_assets"
DIMENSIONS = 384


def article_id(article: dict) -> str:
    import re

    return (
        re.sub(r"[^a-z0-9]", "", article["Law"].casefold())
        + ":"
        + re.sub(r"\s+", "", article["Article"]).casefold()
    )


def repair_corpus(source: list[dict]) -> tuple[list[dict], list[int]]:
    articles = [dict(article) for article in source]
    if not (
        article_id(articles[1594]) == "civilcode:1595"
        and article_id(articles[1595]) == "civilcode:1596"
        and articles[1595]["Article Text"].startswith("article 1596, fourth paragraph")
        and articles[1594]["Article Text"].endswith("the provisions of")
        and articles[1596]["Article Text"].startswith("Article 1596.")
    ):
        raise ValueError("Unexpected Civil Code 1595/1596 source records.")
    articles[1594]["Article Text"] += " " + articles[1595]["Article Text"]

    for index, old, new in ((2592, "50", "150"), (2661, "129", "219")):
        article = articles[index]
        prefix = f"Art. {old}."
        if article["Law"] != "FamilyCode" or article["Article"] != old or not article["Article Text"].startswith(prefix):
            raise ValueError(f"Unexpected Family Code source at index {index}.")
        article["Article"] = new
        article["Article Text"] = f"Art. {new}." + article["Article Text"][len(prefix):]

    old_sibling_clause = "(3) Among brothers and sisters, whether of the full or half-blood."
    if old_sibling_clause not in articles[2592]["Article Text"]:
        raise ValueError("Unexpected Family Code 150 clauses.")
    articles[2592]["Article Text"] = articles[2592]["Article Text"].replace(
        old_sibling_clause,
        "(3) Among other ascendants and descendants; and (4) Among brothers and sisters, whether of the full or half-blood.",
    )
    chapter_heading = " Chapter 3. Effect of Parental Authority Upon the Persons of the Children"
    if not articles[2661]["Article Text"].endswith(chapter_heading):
        raise ValueError("Unexpected Family Code 219 chapter heading.")
    articles[2661]["Article Text"] = articles[2661]["Article Text"][:-len(chapter_heading)]

    del articles[1595]
    # The split fragment was first-wins for Civil Code 1596 training labels.
    # Preserve the label's intended citation, not the fragment's old position.
    remap = [
        1595 if i == 1595 else i if i < 1595 else i - 1
        for i in range(len(source))
    ]
    ids = [article_id(article) for article in articles]
    if len(set(ids)) != len(ids):
        raise ValueError(f"Duplicate repaired article IDs: {Counter(ids).most_common(5)}")
    return articles, remap


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", type=Path, default=ROOT / "assets" / "data")
    assets = parser.parse_args().source_dir
    source = json.loads((assets / "legal_articles.json").read_text(encoding="utf-8"))
    owners = json.loads((assets / "chunk_owners_e5.json").read_text(encoding="utf-8"))
    old_vectors = np.fromfile(assets / "chunk_embeddings_e5.f32", dtype="<f4").reshape(
        -1, DIMENSIONS
    )
    old_chunks = [_current_word_chunks(article["Article Text"]) for article in source]
    expected_owners = [i for i, chunks in enumerate(old_chunks) for _ in chunks]
    if owners != expected_owners or len(old_vectors) != len(owners):
        raise ValueError("Existing chunk owners do not match the reconstructed corpus.")

    articles, remap = repair_corpus(source)
    labels = json.loads((assets / "training_query_labels_e5.json").read_text(encoding="utf-8"))
    if labels["articleCount"] != len(source):
        raise ValueError("Training labels do not match the original corpus.")
    for example in labels["examples"]:
        for key in ("positiveArticleIndexes", "negativeArticleIndexes"):
            example[key] = sorted({remap[index] for index in example[key]})
        if set(example["positiveArticleIndexes"]) & set(example["negativeArticleIndexes"]):
            raise ValueError("Remapping produced contradictory training labels.")
    labels["articleCount"] = len(articles)
    indices = _index_articles(articles)
    training = _load_training_examples(indices)
    if len(training) != len(labels["examples"]):
        raise ValueError("Training workbook example count disagrees with packaged labels.")
    for source_example, remapped_example in zip(training, labels["examples"]):
        if (
            source_example["domain"] != remapped_example["domain"]
            or sorted(source_example["positive"]) != remapped_example["positiveArticleIndexes"]
            or sorted(source_example["negative"]) != remapped_example["negativeArticleIndexes"]
        ):
            raise ValueError("Remapped training labels disagree with their source workbook.")

    # Reuse an embedding only when its original article and exact chunk agree.
    old_by_key = {}
    offset = 0
    for i, chunks in enumerate(old_chunks):
        for j, chunk in enumerate(chunks):
            old_by_key[(i, chunk)] = old_vectors[offset + j]
        offset += len(chunks)
    new_owners, vectors, pending, pending_positions = [], [], [], []
    for new_index, article in enumerate(articles):
        old_index = new_index if new_index < 1595 else new_index + 1
        chunks = _word_chunks(article["Article Text"])
        for chunk in chunks:
            new_owners.append(new_index)
            vector = old_by_key.get((old_index, chunk))
            if vector is None:
                pending_positions.append(len(vectors))
                pending.append(chunk)
                vectors.append(None)
            else:
                vectors.append(vector)
    if not pending:
        raise ValueError("No changed or previously omitted chunks were found.")

    tokenizer = Tokenizer.from_file(str(ROOT / "assets" / "models" / "e5_tokenizer.json"))
    tokenizer.enable_truncation(max_length=256)
    full_tokenizer = Tokenizer.from_file(str(ROOT / "assets" / "models" / "e5_tokenizer.json"))
    full_tokenizer.no_truncation()
    capped_chunks = 0
    import re

    for article in articles:
        chunks = _word_chunks(article["Article Text"])
        for index, chunk in enumerate(chunks):
            text = "passage: " + chunk
            if len(full_tokenizer.encode(text).ids) <= 256:
                continue
            capped_chunks += 1
            if index == len(chunks) - 1:
                raise ValueError(f"Final chunk truncated for {article_id(article)}.")
            words = list(re.finditer(r"\S+", chunk))
            if len(words) <= 40:
                raise ValueError(f"Truncated chunk lacks overlap for {article_id(article)}.")
            next_start = len("passage: ") + words[40].start()
            covered_end = max(end for _, end in tokenizer.encode(text).offsets)
            if covered_end < next_start:
                raise ValueError(f"Token truncation leaves a gap for {article_id(article)}.")
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(
        str(ROOT / "tool" / "retrieval_lab" / "e5" / "model.onnx"),
        sess_options=options,
        providers=["CPUExecutionProvider"],
    )
    # Check compatibility before mixing freshly encoded and packaged vectors.
    check_indices = [0, 100, 1000, 2000, 3000, 4000]
    flat_old_chunks = [chunk for chunks in old_chunks for chunk in chunks]
    check = _embed([flat_old_chunks[i] for i in check_indices], tokenizer, session, prefix="passage: ")
    similarities = np.sum(check * old_vectors[check_indices], axis=1)
    if np.min(similarities) < 0.999:
        raise ValueError(f"Encoder is incompatible with packaged vectors: {similarities}")
    encoded = _embed(pending, tokenizer, session, prefix="passage: ")
    for position, vector in zip(pending_positions, encoded):
        vectors[position] = vector
    matrix = np.asarray(vectors, dtype="<f4")
    if matrix.shape != (len(new_owners), DIMENSIONS) or not np.isfinite(matrix).all():
        raise ValueError("Invalid repaired embedding matrix.")
    if not np.allclose(np.linalg.norm(matrix, axis=1), 1, atol=1e-4):
        raise ValueError("Repaired vectors are not unit-normalized.")

    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "legal_articles.json").write_text(json.dumps(articles, ensure_ascii=False), encoding="utf-8")
    (OUTPUT / "chunk_owners_e5.json").write_text(json.dumps(new_owners), encoding="utf-8")
    (OUTPUT / "training_query_labels_e5.json").write_text(json.dumps(labels), encoding="utf-8")
    matrix.tofile(OUTPUT / "chunk_embeddings_e5.f32")
    audit = {
        "originalArticles": len(source),
        "repairedArticles": len(articles),
        "originalChunks": len(owners),
        "repairedChunks": len(new_owners),
        "reusedVectors": len(vectors) - len(pending),
        "newVectors": len(pending),
        "tokenCappedChunks": capped_chunks,
        "tokenCappedChunksHaveNoCoverageGap": True,
        "minimumEncoderCompatibilityCosine": float(np.min(similarities)),
        "trainingExamplesValidatedAgainstWorkbook": len(training),
        "originalArticleSha256": hashlib.sha256((assets / "legal_articles.json").read_bytes()).hexdigest(),
        "changes": [
            "Joined Civil Code 1595 with its incorrectly split continuation; remapped 1596 labels to its actual provision.",
            "Changed Family Code 50 to 150 and its heading; restored the omitted ascendants/descendants clause and corrected sibling clause numbering.",
            "Changed Family Code 129 to 219 and its heading; removed the following chapter heading from its text.",
            "Added all missing 60-word/40-stride windows for eight long Consumer Act articles.",
        ],
        "sources": [
            "https://elibrary.judiciary.gov.ph/thebookshelf/showdocs/1/43553",
            "https://lawphil.net/executive/execord/eo1987/eo_209_1987.html",
            "https://lawphil.net/statutes/repacts/ra1949/ra_386_1949.html",
        ],
        "limitations": ["The corpus as a whole has not been legally audited."],
    }
    (OUTPUT / "audit.json").write_text(json.dumps(audit, indent=2), encoding="utf-8")
    print(json.dumps(audit, indent=2))


if __name__ == "__main__":
    main()
