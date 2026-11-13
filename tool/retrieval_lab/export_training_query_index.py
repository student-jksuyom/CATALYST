"""Export labeled Training Dataset queries as an on-device E5 example index."""

from __future__ import annotations

import json
from pathlib import Path
import re
from typing import Any

import numpy as np
import onnxruntime as ort
from openpyxl import load_workbook
from tokenizers import Tokenizer


ROOT = Path(__file__).resolve().parents[2]
DATASET_PATH = ROOT / "DATA" / "Datasets" / "Trainingdataset.xlsx"
ARTICLES_PATH = ROOT / "assets" / "data" / "legal_articles.json"
MODEL_PATH = ROOT / "assets" / "models" / "catalyst_encoder_e5.onnx"
TOKENIZER_PATH = ROOT / "assets" / "models" / "e5_tokenizer.json"
EMBEDDINGS_PATH = ROOT / "assets" / "data" / "training_query_embeddings_e5.f32"
LABELS_PATH = ROOT / "assets" / "data" / "training_query_labels_e5.json"
DIMENSIONS = 384
MAX_LENGTH = 128

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


def _article_id(value: str) -> str:
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def _load_training_examples(
    article_indices: dict[str, int],
) -> list[dict[str, Any]]:
    workbook = load_workbook(DATASET_PATH, read_only=True, data_only=True)
    try:
        worksheet = workbook.active
        rows = worksheet.iter_rows(values_only=True)
        headers = [str(value).strip() if value is not None else "" for value in next(rows)]
        required = {
            "Sample Narrative",
            "Case_Category",
            "Applicable_Article_ID",
            "Relevance_Label",
        }
        missing = sorted(required - set(headers))
        if missing:
            raise ValueError(f"Training Dataset is missing columns: {missing}")

        column = {name: headers.index(name) for name in required}
        grouped: dict[str, dict[str, Any]] = {}
        for row_number, row in enumerate(rows, start=2):
            query_value = row[column["Sample Narrative"]]
            if not isinstance(query_value, str) or not query_value.strip():
                continue
            query = query_value.strip()
            normalized = _normalize_query(query)

            category_value = row[column["Case_Category"]]
            category = str(category_value).strip().casefold().split("-", maxsplit=1)[0]
            if category not in {"civil", "consumer", "family"}:
                raise ValueError(
                    f"Training Dataset row {row_number} has unsupported "
                    f"case category {category_value!r}."
                )
            key = f"{normalized.casefold()}|{category}"

            label_value = row[column["Relevance_Label"]]
            if label_value not in (0, 0.0, 1, 1.0):
                raise ValueError(
                    f"Training Dataset row {row_number} has invalid relevance "
                    f"label {label_value!r}."
                )

            record = grouped.setdefault(
                key,
                {
                    "query": normalized,
                    "domain": category,
                    "positive": set(),
                    "negative": set(),
                },
            )
            article_value = row[column["Applicable_Article_ID"]]
            if not isinstance(article_value, str) or not article_value.strip():
                raise ValueError(
                    f"Training Dataset row {row_number} has no article ID."
                )
            article_ids = re.split(r"\s*,\s*", article_value.strip())
            target = record["positive"] if label_value == 1 else record["negative"]
            for article_id in article_ids:
                index = article_indices.get(_article_id(article_id))
                if index is None:
                    raise ValueError(
                        f"Training Dataset row {row_number} references unknown "
                        f"article {article_id!r}."
                    )
                target.add(index)
    finally:
        workbook.close()

    examples = list(grouped.values())
    for example in examples:
        conflicts = example["positive"] & example["negative"]
        if conflicts:
            raise ValueError(
                "A training query marks the same article relevant and "
                f"non-relevant: {sorted(conflicts)}"
            )
    if not examples:
        raise ValueError("The Training Dataset contains no usable queries.")
    return examples


def _encode_examples(examples: list[dict[str, Any]]) -> np.ndarray:
    tokenizer = Tokenizer.from_file(str(TOKENIZER_PATH))
    tokenizer.enable_truncation(max_length=MAX_LENGTH)
    session = ort.InferenceSession(
        str(MODEL_PATH),
        providers=["CPUExecutionProvider"],
    )
    input_names = {item.name for item in session.get_inputs()}
    vectors = []

    for example in examples:
        encoded = tokenizer.encode(f"query: {example['query']}")
        input_ids = np.asarray([encoded.ids], dtype=np.int64)
        attention_mask = np.asarray([encoded.attention_mask], dtype=np.int64)
        inputs = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }
        if "token_type_ids" in input_names:
            inputs["token_type_ids"] = np.zeros_like(input_ids)
        vector = np.asarray(session.run(None, inputs)[0][0], dtype=np.float32)
        norm = float(np.linalg.norm(vector))
        if vector.shape != (DIMENSIONS,) or not np.isfinite(norm) or norm == 0:
            raise ValueError("The E5 encoder produced an invalid training vector.")
        vectors.append(vector / norm)

    return np.asarray(vectors, dtype="<f4")


def main() -> None:
    articles = json.loads(ARTICLES_PATH.read_text(encoding="utf-8"))
    if not isinstance(articles, list) or not articles:
        raise ValueError("The bundled article corpus is empty or invalid.")

    article_indices: dict[str, int] = {}
    for index, article in enumerate(articles):
        article_indices.setdefault(
            _article_id(f"{article['Law']}:{article['Article']}"),
            index,
        )

    examples = _load_training_examples(article_indices)
    vectors = _encode_examples(examples)
    metadata = {
        "formatVersion": 1,
        "articleCount": len(articles),
        "embeddingCount": len(examples),
        "examples": [
            {
                "domain": example["domain"],
                "positiveArticleIndexes": sorted(example["positive"]),
                "negativeArticleIndexes": sorted(example["negative"]),
            }
            for example in examples
        ],
    }

    EMBEDDINGS_PATH.write_bytes(vectors.tobytes(order="C"))
    LABELS_PATH.write_text(
        json.dumps(metadata, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(
        f"Exported {len(examples)} query vectors for {len(articles)} articles "
        f"to {EMBEDDINGS_PATH.relative_to(ROOT)}."
    )


if __name__ == "__main__":
    main()
