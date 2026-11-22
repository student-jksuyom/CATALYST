# BGE-M3 full-hybrid evaluation

## Decision

**Keep E5-small in production. Do not integrate BGE-M3.** The standard BGE
full-hybrid configuration is below production Hit@3 in both FP32 (13/46) and
dynamic INT8 (9/46). Removing the training-neighbor similarity cutoff improves
FP32 to 21/46, but four development cases have a highly similar training
neighbor carrying the same positive article label. That result is therefore
not a defensible estimate of generalization. INT8 without the cutoff reaches
17/46, only ties production Hit@3, and still has training overlap.

The Android deployment path is not ready: the published ONNX model uses an
external data file of 2,266,820,608 bytes, no quantized ONNX artifact was
tested, and no Android device was available. Production code, model assets,
corpus text, citations, and the held-out set were not changed or accessed.

## Comparable retrieval results

The same 46 development concerns, labels, 2,699 articles, 4,514 chunks, BM25
lists, query preprocessing, candidate source pools (50 per source), and
article-level best-chunk aggregation were used. Each encoder used its own
tokenization, pooling, normalization, and vectors. BGE training-query vectors
were newly encoded with BGE-M3 (182 examples); E5 and BGE embeddings were not
mixed. The E5 reproduction returned the same top-15 as Flutter on all 46
queries.

`Coverage pre/post` counts relevant queries and labels present in the
candidate union before and after the cosine gate, respectively. BGE uses a
model-specific gate of 0.486354 (FP32) or 0.507071 (dynamic INT8). The six
negative probes set each gate and thus are not an independent safety test.

| Configuration | Hit@1 / 3 / 15 | Precision@3 | Civil / Family / Consumer Hit@3 | Coverage pre → post (queries; labels) |
|---|---:|---:|---:|---:|
| Production E5-small | 13 / 17 / 21 | 12.32% | 2/23 / 8/13 / 7/10 | 34/46, 36/50 → 32/46, 34/50 |
| BGE-M3 FP32 dense-only | 4 / 14 / 23 | 10.14% | 4/23 / 6/13 / 4/10 | 39/46, 41/50 → 36/46, 38/50 |
| BGE-M3 FP32 full hybrid, training cutoff .90 | 6 / 13 / 24 | 9.42% | 3/23 / 5/13 / 5/10 | 39/46, 41/50 → 36/46, 38/50 |
| BGE-M3 FP32 full hybrid, no training cutoff* | 11 / 21 / 26 | 15.22% | 5/23 / 9/13 / 7/10 | 41/46, 43/50 → 37/46, 39/50 |
| BGE-M3 dynamic INT8 dense-only | 5 / 10 / 22 | 7.25% | 2/23 / 5/13 / 3/10 | 37/46, 39/50 → 35/46, 37/50 |
| BGE-M3 dynamic INT8 full hybrid, training cutoff .90 | 8 / 9 / 24 | 6.52% | 2/23 / 3/13 / 4/10 | 39/46, 41/50 → 36/46, 38/50 |
| BGE-M3 dynamic INT8 full hybrid, no training cutoff* | 14 / 17 / 26 | 12.32% | 4/23 / 7/13 / 6/10 | 41/46, 43/50 → 37/46, 39/50 |

`*` Removes only the minimum similarity requirement for training-query
neighbors; it still applies the BGE cosine gate. It is a diagnostic, not a
production recommendation.

The default FP32 full hybrid falls four Hit@3 below E5, despite recovering
four more relevant labels after the gate. That difference is ranking, not
candidate availability. Reusing the E5 calibrated cosine scale with BGE was
also unsuitable (6/46 Hit@3). Rank fusion performed better (13/46), but still
did not match production. Lowering the BGE training threshold to .80 reached
14/46 Hit@3, also below production. The INT8 model reduced dense-only Hit@3
from FP32's 14/46 to 10/46 and the standard full-hybrid result from 13/46 to
9/46. Its no-cutoff result merely tied production at 17/46.

All six negative probes returned no candidates with the respective gates;
without the gate, all six returned candidates. Since the probes define the
gate, this demonstrates the cutoff's mechanical effect only, not real-world
false-positive safety.

## Training-query overlap

There were no exact normalized query matches. One development query,
CA-EV-004, had character similarity 0.806 to a training query. With FP32 BGE,
five development cases had a top-three training neighbor at cosine ≥.80;
four also shared a positive article label:

| Development case | BGE similarity | Shared training/evaluation article |
|---|---:|---|
| CA-EV-004 | 0.927 | Consumer Act 64 |
| CA-EV-006 | 0.805 | Consumer Act 91 |
| CA-EV-009 | 0.952 | Consumer Act 110 |
| CA-EV-010 | 0.891 | Consumer Act 53 |

For dynamic INT8, three of those four label overlaps remain ≥.80. No
development labels were used as retrieval features and no held-out data was
used, but these near-duplicates make the no-cutoff Hit@3 gain unreliable as
an unseen-query estimate.

## Cost and deployment

Measurements are from this Windows CPU host with three PyTorch threads. They
are not Android measurements. Ranking time includes hybrid scoring and
candidate ordering but excludes neural inference and model initialization.

| Encoder/mode | Model weights | Chunk index | Mean single variant query inference | Mean ranking time | Peak process working set |
|---|---:|---:|---:|---:|---:|
| E5-small production ONNX | 448.4 MiB | 6.6 MiB | 42.5 ms | 3.3 ms | 914 MiB |
| BGE-M3 FP32 PyTorch | 2,166 MiB | 17.6 MiB | 656.8 ms | 3.6 ms | 2,077 MiB |
| BGE-M3 dynamic INT8 PyTorch | ~1,299 MiB estimated parameters | 17.6 MiB | 412.4 ms | 2.1 ms | 5,768 MiB |

For this dataset, 64 query variants were encoded for 46 concerns (1.39 per
concern). That implies a warm host-side query-encoding-plus-ranking estimate
of about 0.92 s for FP32 and 0.58 s for dynamic INT8, excluding startup,
loading, application overhead, and device-specific costs. It is not a mobile
latency claim. FP32 corpus-vector creation took 42.3 minutes; the dynamic
INT8 run took 22.5 minutes. The INT8 process peak includes conversion
temporaries and index generation, not just steady-state inference memory.

The BGE-M3 snapshot is revision
`5617a9f61b028005a4858fdac845db406aefb181`; its model card lists the MIT
license ([BAAI/bge-m3](https://huggingface.co/BAAI/bge-m3)). The published
ONNX repository includes `onnx/model.onnx_data` at 2,266,820,608 bytes.
Dynamic INT8 was tested as a PyTorch CPU experiment, not exported to ONNX and
not shown to be compatible with Flutter/Android. No Android device was
attached. These size, memory, and validation gaps block a responsible offline
production deployment.

## Integrity and validation

The runner checked the exported corpus IDs and article text against the
current master corpus, stable unique article IDs, chunk ownership, expected
label mappings, vector dimensions, finite values, and unit norms. The repaired
corpus and citation mappings were preserved. Six negative probes abstained
with the measured gate but are too few to establish no-match safety.

The corrected dense-only control excludes BM25 and training candidates when
their weights are zero. A focused regression test covers candidate-source
selection. Three Python unit tests and Python syntax compilation pass. The
Flutter exporter analysis and targeted grounding, co-ownership, and
corpus-integrity tests had passed; no Dart or production Flutter code changed
in this comparison.

## Reproduction

The scripts use locally cached models and fail if a snapshot is missing.
They do not modify application assets.

```powershell
flutter test --no-pub tool\retrieval_lab\diagnostics\embedding_upgrade\export_inputs_test.dart
$env:HF_HUB_OFFLINE = '1'
$env:TRANSFORMERS_OFFLINE = '1'
py -3.14 tool\retrieval_lab\diagnostics\embedding_upgrade\compare.py --model bge-m3
py -3.14 tool\retrieval_lab\diagnostics\embedding_upgrade\compare.py --model bge-m3 --int8
py -3.14 tool\retrieval_lab\diagnostics\embedding_upgrade\full_hybrid.py
py -3.14 tool\retrieval_lab\diagnostics\embedding_upgrade\full_hybrid.py --vector-dir bge-m3-int8 --int8
py -3.14 -m unittest discover -s tool\retrieval_lab\diagnostics\embedding_upgrade -p test_compare.py
```
