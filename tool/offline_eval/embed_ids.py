"""Embed token-id sequences with the production ONNX encoder (host only)."""
import argparse
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort

parser = argparse.ArgumentParser()
parser.add_argument("--output-dir", type=Path, default=Path("tool/offline_eval/out"))
output_dir = parser.parse_args().output_dir

session = ort.InferenceSession(
    "assets/models/catalyst_encoder_e5.onnx", providers=["CPUExecutionProvider"]
)
ids = json.loads((output_dir / "ids.json").read_text(encoding="utf-8"))
vectors = {}
for key, tokens in ids.items():
    arr = np.array([tokens], dtype=np.int64)
    mask = np.ones_like(arr)
    out = session.run(None, {"input_ids": arr, "attention_mask": mask})[0][0]
    vectors[key] = [float(v) for v in out]
(output_dir / "vectors.json").write_text(json.dumps(vectors), encoding="utf-8")
print(len(vectors), "embeddings")
