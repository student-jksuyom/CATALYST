"""Embed token ids for the lab. Usage: python embed.py e5|minilm

e5: multilingual-e5-small ONNX (mean pooling + L2 norm done here).
minilm: the production catalyst_encoder.onnx (already pooled and normalized).
"""
import json
import sys

import numpy as np
import onnxruntime as ort

D = "tool/retrieval_lab"
model = sys.argv[1]
path = f"{D}/e5/model.onnx" if model == "e5" else "assets/models/catalyst_encoder.onnx"
session = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
names = {i.name for i in session.get_inputs()}
data = json.load(open(f"{D}/out/ids_{model}.json"))


def embed(seqs, batch=16):
    order = sorted(range(len(seqs)), key=lambda i: len(seqs[i]))
    out = np.zeros((len(seqs), 384), dtype=np.float32)
    for start in range(0, len(order), batch):
        idx = order[start : start + batch]
        width = max(len(seqs[i]) for i in idx)
        ids = np.ones((len(idx), width), dtype=np.int64)  # pad id 1
        mask = np.zeros((len(idx), width), dtype=np.int64)
        for row, i in enumerate(idx):
            ids[row, : len(seqs[i])] = seqs[i]
            mask[row, : len(seqs[i])] = 1
        feed = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in names:
            feed["token_type_ids"] = np.zeros_like(ids)
        if model == "e5":
            hidden = session.run(None, feed)[0]
            pooled = (hidden * mask[..., None]).sum(1) / mask.sum(1, keepdims=True)
            pooled /= np.linalg.norm(pooled, axis=1, keepdims=True)
        else:
            pooled = session.run(["sentence_embedding"], feed)[0]
        out[idx] = pooled
    return out


np.save(f"{D}/out/chunks_{model}.npy", embed(data["chunks"]))
np.save(f"{D}/out/passages_{model}.npy", embed(data["passages"]))
json.dump(data["chunkOwner"], open(f"{D}/out/chunk_owner.json", "w"))
keys = list(data["queries"].keys())
q = embed([data["queries"][k] for k in keys])
json.dump({k: q[i].tolist() for i, k in enumerate(keys)}, open(f"{D}/out/queries_{model}.json", "w"))
print(model, len(data["chunks"]), len(keys))
