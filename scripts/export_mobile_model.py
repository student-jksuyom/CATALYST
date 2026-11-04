"""Export and parity-check the CATALYST MiniLM sentence encoder for Android."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import tempfile
import time
from typing import Any

import numpy as np
import onnx
import onnxruntime as ort
import torch
from sentence_transformers import SentenceTransformer
from torch import Tensor, nn
from torch.nn import functional as F


PROJECT_ROOT = Path(__file__).resolve().parent.parent
MODEL_CACHE = (
    Path.home()
    / ".cache"
    / "huggingface"
    / "hub"
    / "models--sentence-transformers--paraphrase-multilingual-MiniLM-L12-v2"
    / "snapshots"
)
CORPUS_PATH = PROJECT_ROOT / "DATA" / "Corpus" / "MasterCorpus_Embedded.pkl"
OUTPUT_PATH = PROJECT_ROOT / "assets" / "models" / "catalyst_encoder.onnx"
REPORT_PATH = PROJECT_ROOT / "scripts" / "mobile_retrieval_validation.json"
DIMENSIONS = 384
MAX_SEQUENCE_LENGTH = 128
QUERIES = (
    (
        "english",
        "I bought a phone and it stopped working after only two days. "
        "Can I demand a refund or replacement?",
    ),
    (
        "tagalog",
        "Binili ko ang telepono ngunit agad itong nasira. "
        "Ano ang maaari kong gawin bilang mamimili?",
    ),
    (
        "taglish",
        "Nag-order ako online ng shoes, pero fake yung dumating. "
        "Pwede ko bang i-return at hingin ang refund?",
    ),
    (
        "defective-phone",
        "Binili ko yung phone pero sira agad kahit kakabili ko lang",
    ),
)


class MeanPooledEncoder(nn.Module):
    def __init__(self, transformer: nn.Module) -> None:
        super().__init__()
        self.transformer = transformer

    def forward(self, input_ids: Tensor, attention_mask: Tensor) -> Tensor:
        token_embeddings = self.transformer(
            input_ids=input_ids,
            attention_mask=attention_mask,
        ).last_hidden_state
        mask = attention_mask.unsqueeze(-1).to(token_embeddings.dtype)
        summed = torch.sum(token_embeddings * mask, dim=1)
        counts = torch.clamp(torch.sum(mask, dim=1), min=1e-9)
        mean = summed / counts
        return F.normalize(mean, p=2, dim=1)


def _default_model_path() -> Path:
    if not MODEL_CACHE.is_dir():
        raise FileNotFoundError(
            "The cached multilingual MiniLM model was not found. "
            "Pass its local snapshot directory with --model-path."
        )
    snapshots = [path for path in MODEL_CACHE.iterdir() if path.is_dir()]
    if not snapshots:
        raise FileNotFoundError(f"No model snapshots found in {MODEL_CACHE}")
    return max(snapshots, key=lambda path: path.stat().st_mtime)


def _identity(row: Any) -> dict[str, str]:
    import pandas as pd

    def clean(value: Any) -> str:
        return "" if pd.isna(value) else str(value)

    return {
        "law": clean(row["Law"]),
        "article": clean(row["Article"]),
        "title": clean(row.get("Title", "")),
        "chapterTitle": clean(row.get("Chapter Title", "")),
    }


def _tokenize(model: SentenceTransformer, query: str) -> tuple[np.ndarray, np.ndarray]:
    encoded = model.tokenizer(
        query.strip(),
        add_special_tokens=True,
        truncation=True,
        max_length=MAX_SEQUENCE_LENGTH,
        padding=False,
        return_tensors="np",
    )
    return (
        np.asarray(encoded["input_ids"], dtype=np.int64),
        np.asarray(encoded["attention_mask"], dtype=np.int64),
    )


def _run_session(
    session: ort.InferenceSession,
    input_ids: np.ndarray,
    attention_mask: np.ndarray,
) -> np.ndarray:
    return np.asarray(
        session.run(
            ["sentence_embedding"],
            {"input_ids": input_ids, "attention_mask": attention_mask},
        )[0],
        dtype=np.float32,
    )[0]


def _rank(
    vector: np.ndarray,
    matrix: np.ndarray,
    corpus: Any,
) -> tuple[list[int], list[dict[str, Any]]]:
    scores = matrix @ vector
    indices = np.argsort(-scores, kind="stable")[:3].tolist()
    results = [
        {
            **_identity(corpus.iloc[index]),
            "score": float(scores[index]),
            "scoreRounded": round(float(scores[index]), 4),
            "corpusIndex": index,
        }
        for index in indices
    ]
    return indices, results


def _compare_variant(
    session: ort.InferenceSession,
    model: SentenceTransformer,
    matrix: np.ndarray,
    corpus: Any,
) -> dict[str, Any]:
    query_reports: list[dict[str, Any]] = []
    all_rankings_match = True
    max_embedding_difference = 0.0
    max_score_difference = 0.0
    latencies_ms: list[float] = []

    for label, query in QUERIES:
        input_ids, attention_mask = _tokenize(model, query)
        baseline = np.asarray(
            model.encode(
                query.strip(),
                normalize_embeddings=True,
                convert_to_numpy=True,
            ),
            dtype=np.float32,
        ).reshape(-1)
        onnx_vector = _run_session(session, input_ids, attention_mask)
        embedding_difference = float(np.max(np.abs(baseline - onnx_vector)))
        baseline_indices, baseline_results = _rank(baseline, matrix, corpus)
        onnx_indices, onnx_results = _rank(onnx_vector, matrix, corpus)
        score_difference = max(
            abs(left["score"] - right["score"])
            for left, right in zip(baseline_results, onnx_results)
        )

        _run_session(session, input_ids, attention_mask)
        started = time.perf_counter()
        for _ in range(5):
            _run_session(session, input_ids, attention_mask)
        latencies_ms.append((time.perf_counter() - started) * 200)

        same_ranking = baseline_indices == onnx_indices
        all_rankings_match = all_rankings_match and same_ranking
        max_embedding_difference = max(
            max_embedding_difference, embedding_difference
        )
        max_score_difference = max(max_score_difference, score_difference)
        query_reports.append(
            {
                "label": label,
                "embeddingDimensions": int(onnx_vector.size),
                "baselineEmbeddingNorm": float(np.linalg.norm(baseline)),
                "convertedEmbeddingNorm": float(np.linalg.norm(onnx_vector)),
                "maxAbsoluteEmbeddingDifference": embedding_difference,
                "maxTop3ScoreDifference": score_difference,
                "sameOrderedTop3": same_ranking,
                "pythonTop3": baseline_results,
                "convertedTop3": onnx_results,
            }
        )

    return {
        "orderedTop3MatchesForAllQueries": all_rankings_match,
        "maxAbsoluteEmbeddingDifference": max_embedding_difference,
        "maxTop3ScoreDifference": max_score_difference,
        "medianWarmInferenceMs": float(np.median(latencies_ms)),
        "queries": query_reports,
    }


def _export_fp32(model: SentenceTransformer, output_path: Path) -> None:
    transformer = model[0].auto_model.eval()
    encoder = MeanPooledEncoder(transformer).eval()
    sample_ids, sample_mask = _tokenize(model, QUERIES[-1][1])
    input_ids = torch.from_numpy(sample_ids)
    attention_mask = torch.from_numpy(sample_mask)

    with torch.inference_mode():
        torch.onnx.export(
            encoder,
            (input_ids, attention_mask),
            str(output_path),
            input_names=["input_ids", "attention_mask"],
            output_names=["sentence_embedding"],
            dynamic_axes={
                "input_ids": {0: "batch", 1: "sequence"},
                "attention_mask": {0: "batch", 1: "sequence"},
                "sentence_embedding": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
            dynamo=False,
        )
    onnx.checker.check_model(onnx.load(str(output_path)))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", type=Path, default=None)
    parser.add_argument("--corpus-path", type=Path, default=CORPUS_PATH)
    parser.add_argument("--output-path", type=Path, default=OUTPUT_PATH)
    parser.add_argument("--report-path", type=Path, default=REPORT_PATH)
    args = parser.parse_args()

    model_path = args.model_path or _default_model_path()
    import pandas as pd

    corpus = pd.read_pickle(args.corpus_path)
    matrix = np.stack(
        [np.asarray(value, dtype=np.float32) for value in corpus["Embedding"]]
    )
    if matrix.ndim != 2 or matrix.shape[1] != DIMENSIONS:
        raise ValueError(f"Expected {DIMENSIONS}-dimensional embeddings, got {matrix.shape}")
    if not np.isfinite(matrix).all():
        raise ValueError("Corpus embeddings contain NaN or infinite values.")
    if not np.allclose(np.linalg.norm(matrix, axis=1), 1.0, atol=1e-3):
        raise ValueError("Corpus embeddings are not unit-normalized.")

    model = SentenceTransformer(str(model_path), local_files_only=True)
    if model.max_seq_length != MAX_SEQUENCE_LENGTH:
        raise ValueError(
            f"Expected baseline max_seq_length={MAX_SEQUENCE_LENGTH}, "
            f"received {model.max_seq_length}."
        )
    if model.get_embedding_dimension() != DIMENSIONS:
        raise ValueError("The cached model does not produce 384-dimensional vectors.")

    args.output_path.parent.mkdir(parents=True, exist_ok=True)
    args.report_path.parent.mkdir(parents=True, exist_ok=True)
    report: dict[str, Any] = {
        "model": "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
        "modelSnapshot": str(model_path),
        "dimensions": DIMENSIONS,
        "maxSequenceLength": MAX_SEQUENCE_LENGTH,
        "pooling": "attention-mask-aware mean pooling followed by L2 normalization",
        "runtime": f"ONNX Runtime {ort.__version__} CPU",
        "corpusRows": len(corpus),
        "corpusEmbeddingDtype": str(matrix.dtype),
    }

    with tempfile.TemporaryDirectory(
        prefix="catalyst_onnx_", dir=args.output_path.parent
    ) as temporary_directory:
        temporary = Path(temporary_directory)
        fp32_path = temporary / "encoder.fp32.onnx"
        _export_fp32(model, fp32_path)

        fp32_session = ort.InferenceSession(
            str(fp32_path), providers=["CPUExecutionProvider"]
        )
        fp32_report = _compare_variant(fp32_session, model, matrix, corpus)
        report["fp32"] = fp32_report
        fp32_session = None

        from onnxruntime.quantization import QuantType, quantize_dynamic

        quantized_candidates: list[tuple[str, Path, dict[str, Any]]] = []
        for name, per_channel in (
            ("dynamicInt8PerChannel", True),
            ("dynamicInt8PerTensor", False),
        ):
            int8_path = temporary / f"encoder.{name}.onnx"
            quantize_dynamic(
                str(fp32_path),
                str(int8_path),
                weight_type=QuantType.QInt8,
                per_channel=per_channel,
                op_types_to_quantize=["MatMul", "Gemm"],
            )
            int8_session = ort.InferenceSession(
                str(int8_path), providers=["CPUExecutionProvider"]
            )
            int8_report = _compare_variant(int8_session, model, matrix, corpus)
            report[name] = int8_report
            quantized_candidates.append((name, int8_path, int8_report))
            int8_session = None

        accepted_quantized = [
            candidate
            for candidate in quantized_candidates
            if candidate[2]["orderedTop3MatchesForAllQueries"]
            and candidate[2]["maxTop3ScoreDifference"] <= 0.01
        ]
        if accepted_quantized:
            selected_name, selected_path, selected_report = min(
                accepted_quantized,
                key=lambda candidate: (
                    candidate[1].stat().st_size,
                    candidate[2]["maxTop3ScoreDifference"],
                ),
            )
            selected_variant = selected_name
            report["selectedQuantizationScoreDifference"] = (
                selected_report["maxTop3ScoreDifference"]
            )
        elif fp32_report["orderedTop3MatchesForAllQueries"]:
            selected_path = fp32_path
            selected_variant = "fp32"
        else:
            report["selectedVariant"] = None
            args.report_path.write_text(
                json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
            )
            raise RuntimeError(
                "Neither the FP32 nor the quantized ONNX export preserved every "
                "ordered Top-3 ranking. See the validation report before proceeding."
            )

        shutil.copy2(selected_path, args.output_path)
        report["selectedVariant"] = selected_variant
        report["selectedModelBytes"] = args.output_path.stat().st_size
        args.report_path.write_text(
            json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8"
        )

    print(json.dumps(report, indent=2, ensure_ascii=False))
    print(f"Selected ONNX model: {args.output_path}")
    print(f"Validation report: {args.report_path}")


if __name__ == "__main__":
    main()
