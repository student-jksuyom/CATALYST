"""Embed token-id sequences with the production ONNX encoder (host only)."""
import json

import numpy as np
import onnxruntime as ort

session = ort.InferenceSession(
    "assets/models/catalyst_encoder_e5.onnx", providers=["CPUExecutionProvider"]
)
ids = json.load(open("tool/offline_eval/out/ids.json"))
vectors = {}
for key, tokens in ids.items():
    arr = np.array([tokens], dtype=np.int64)
    mask = np.ones_like(arr)
    out = session.run(None, {"input_ids": arr, "attention_mask": mask})[0][0]
    vectors[key] = [float(v) for v in out]
json.dump(vectors, open("tool/offline_eval/out/vectors.json", "w"))
print(len(vectors), "embeddings")
