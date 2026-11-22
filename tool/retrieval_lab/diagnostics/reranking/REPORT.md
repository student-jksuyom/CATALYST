# Sprint 2: offline legal-article reranking

## Decision

The cross-encoder is implemented and evaluated as an **offline experiment**,
not enabled in the Flutter app. The best development blend improves the
metrics, but on this Windows CPU it takes around 10 seconds per query for
the full pool-50 candidate list and the process peaks at 590 MiB. This is
not evidence of acceptable mobile latency or memory. An ARM ONNX export,
device benchmarks, broader no-match tests, and an independent legal evaluation
are needed before deployment. The existing production ranking remains the
default and fallback; only an optional candidate-pool experiment setting was
added to the service.

## Model and implementation

- Model: [`cross-encoder/mmarco-mMiniLMv2-L12-H384-v1`](https://huggingface.co/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1),
  revision `1427fd652930e4ba29e8149678df786c240d8825`.
  The [model metadata](https://huggingface.co/api/models/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1)
  identifies its license as Apache-2.0. It is an XLM-R-based multilingual
  MiniLM cross-encoder trained on translated MS MARCO, not a Philippine-law
  model. Filipino and Taglish are not specifically established by the model
  card; their performance here is empirical, not a language guarantee.
- The experiment uses the publisher's CPU AVX2 quantized ONNX model
  `onnx/model_quint8_avx2.onnx` (118,620,016 bytes, SHA-256
  `6c2513767fb63d008a4377bef7a7a3555433d9436342bb53e35a3a72ffc52d4b`).
  It runs locally in ONNX Runtime with no paid API. This x86 model is not a
  tested Android binary; the publisher also provides a separate ARM export.
- Flutter generates candidate articles and hybrid scores from the existing
  E5/BM25/training-query pipeline. Source-list limits 50 and 500 were tested,
  retaining the existing 0.80 cosine gate and early no-match rules. The
  experiment uses cached Stage 1 production ONNX query vectors and the same
  pass-through preprocessing as that baseline. Actual E5 inference time is
  therefore excluded.
- The reranker compares the original concern with each candidate's actual
  corpus article text. It tokenizes the full article into overlapping windows,
  scores all windows and uses the maximum logit for that article. Pair inputs
  are at most 256 tokens; the query is limited to 128 tokens and document
  windows overlap by 32 tokens. This covers all document tokens but truncates
  exceptionally long queries; the maximum across windows can favor long
  documents. The XLM-R pair format was checked against the model tokenizer.
- For blending, a sigmoid maps the maximum logit to a bounded relevance
  signal, then `weight * sigmoid(logit) + (1 - weight) * hybridScore`.
  The hybrid score is the service's displayed score (rounded to four decimal
  places before scaling). Neither score is a legal correctness probability.
  Direct ranking uses weight 1.0.

## Development accuracy

The production baseline was reproduced exactly, ordered Top 15 for all
46 queries: 13/17/21 Hit@1/3/15 and 12.32% Precision@3. Precision@3
counts labeled relevant results divided by 138; unlabeled results are not
necessarily irrelevant. No held-out cases were used.

| Source pool | Reranked candidates | Cross weight | Hit@1 | Hit@3 | Hit@15 | Precision@3 | Co-ownership regression |
|---|---:|---:|---:|---:|---:|---:|---|
| Current production | 0 | 0 | 13 | 17 | 21 | 12.32% | pass |
| 50 | 30 | 0.50 | 13 | 18 | 23 | 13.04% | pass |
| 50 | 50 | 0.50 | 13 | 18 | 23 | 13.04% | pass |
| 50 | 100 | 0.50 | **14** | **19** | **25** | **13.77%** | pass |
| 50 | 200 | 0.50 | 14 | 19 | 25 | 13.77% | pass |
| 50 | 100 | 1.00 (direct) | 2 | 4 | 17 | 2.90% | fail |
| 500 | 30 | 0.50 | 13 | 18 | 23 | 13.04% | fail |
| 500 | 50 | 0.50 | 12 | 17 | 23 | 12.32% | fail |
| 500 | 100 | 0.50 | 12 | 17 | 22 | 12.32% | fail |
| 500 | 200 | 0.50 | 13 | 17 | 23 | 12.32% | fail |
| 500 | 200 | 1.00 (direct) | 1 | 4 | 12 | 2.90% | fail |

The best tested blend gained +1 Hit@1, +2 Hit@3, +4 Hit@15 and
+1.45 percentage points Precision@3 over Sprint 1. This is a development-set
measurement, not an expected independent gain. At pool 50 / 100 candidates,
CC-EV-002 moved 5 to 3, CC-EV-025 moved from a miss to 1, and CC-EV-007,
CC-EV-021 and CA-EV-005 entered the Top 15. CC-EV-019 moved 6 to 10,
FC-EV-002 4 to 5, and FC-EV-003 6 to 14. Even though the best blend passes
the existing co-ownership assertions, it puts Civil Code 1819 at rank 1 and
493 at rank 3 for that fixture; passing a single regression is not proof of
legal quality.

All 32 combinations (two source pools, four candidate counts, and weights
0.25/0.50/0.75/1.00), corrected per-query lists and negative outcomes are in
[corrected_results.json](./corrected_results.json); the initial full-pool
scores and memory are in [results.json](./results.json). Candidate limits are maxima:
pool 50 yields 41–125 gated, deduplicated articles (mean 84.1), and pool 500
yields 41–200 (mean 185.7); fewer than the requested number are reranked
when fewer survive.

The quantized ONNX model's logits depend on batch composition. Reusing the
full-pool logits unmodified at smaller cutoffs changed 745 candidate scores,
with a maximum logit difference of 0.998. The correction reruns all batches
touching each cutoff boundary, including every window of affected articles.
It was checked against independent full-prefix inference for 30 and 50
candidates, with zero observed score difference. Four aggregate rows changed
relative to the preliminary results; the chosen 100-candidate blend's
metrics and ordered Top-15 lists did not change.

| Source pool | Top 30 | Top 50 | Top 100 | Top 200 |
|---|---:|---:|---:|---:|
| 50: queries / labels covered after gate | 26/27 | 28/30 | 32/34 | 32/34 |
| 500: queries / labels covered after gate | 24/25 | 27/29 | 32/34 | 37/39 |

These are coverage out of 46 queries and 50 labels, after hybrid ranking and
the cosine gate. The earlier 45/46, 49/50 figure was the wider **pre-gate
union**, not the Top 200 handed to this reranker.

## Safety and performance

All six existing off-topic probes returned no candidates with either pool,
so no reranker result was returned. This is a small safety check, not a
comprehensive false-positive evaluation. No threshold was changed.

On an AMD Ryzen 5 7520U, four CPU threads, ONNX Runtime 1.31, batch size 8,
the complete 46-query run took on average **10.67 s** for all available
pool-50 candidates and **23.32 s** for up to 200 pool-500 candidates
(medians 10.10 and 22.50 s). Means include tokenization and pair inference,
not actual E5 ONNX inference. The cached-vector Flutter export measured
67.6 ms and 136.6 ms mean for those two retrieval paths respectively;
these debug-host timings are not mobile end-to-end measurements. Model
initialization took 1.84 s. Windows process working set was 70.7 MiB before
loading, 454.4 MiB after loading, and peaked at 590.0 MiB during the run;
this is whole-process memory, not model-only or mobile memory.

For individual candidate counts, three warm development cases were timed
separately. These are small, noisy samples on a shared machine, not a
representative device benchmark. Each number includes tokenization and ONNX
inference; requested counts are capped at available candidates.

| Source pool | Requested candidates | Mean actual candidates | Mean reranker time | Range |
|---|---:|---:|---:|---:|
| 50 | 30 | 30 | 5.86 s | 3.19–8.14 s |
| 50 | 50 | 50 | 10.84 s | 7.47–16.94 s |
| 50 | 100 | 69 | 14.25 s | 10.74–19.11 s |
| 50 | 200 | 69 | 12.81 s | 10.37–14.64 s |
| 500 | 30 | 30 | 7.36 s | 4.22–9.16 s |
| 500 | 50 | 50 | 10.95 s | 6.17–13.80 s |
| 500 | 100 | 86 | 16.85 s | 14.85–19.13 s |
| 500 | 200 | 152.7 | 25.64 s | 13.58–34.73 s |

Individual measurements and retrieval timings are in
[latency_samples.json](./latency_samples.json). Another test ran during part
of this sample, so the timings should not be treated as isolated throughput.

## Tests

- Production baseline and extended-result order matched for all 46 queries;
  six negative probes returned no candidates at both source-pool settings.
- The three focused retrieval/conversation/co-ownership Flutter test files
  passed 32 tests. Four Python tests cover long-window coverage, batch
  boundary correction, blending, empty inputs, and multi-label metrics; Dart
  analysis reported no issues.
- The full `flutter test` run passed 139 and failed 5 unrelated widget tests:
  one jurisprudence follow-up, two law-details follow-up, and two XAI
  navigation tests. Their finders expect a `TextField` or send button in
  `LawDetailsScreen`, but no matching widget was present. These screens
  were not changed by this experiment.

## Reproduce

The files under `tool/retrieval_lab/out/reranker/` are local ignored model
assets, not bundled Flutter assets. Download the model and tokenizer from
the pinned public revision if they are absent:

```powershell
New-Item -ItemType Directory -Force 'tool\retrieval_lab\out\reranker' | Out-Null
$base = 'https://huggingface.co/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1/resolve/1427fd652930e4ba29e8149678df786c240d8825'
curl.exe -L --fail -o 'tool\retrieval_lab\out\reranker\model_quint8_avx2.onnx' "$base/onnx/model_quint8_avx2.onnx"
curl.exe -L --fail -o 'tool\retrieval_lab\out\reranker\tokenizer.json' "$base/tokenizer.json"
flutter test 'tool\retrieval_lab\diagnostics\reranking\export_candidates_test.dart'
$env:HF_HUB_OFFLINE = '1'
py -3.14 'tool\retrieval_lab\diagnostics\reranking\rerank.py' --model 'tool\retrieval_lab\out\reranker\model_quint8_avx2.onnx' --tokenizer 'tool\retrieval_lab\out\reranker\tokenizer.json'
py -3.14 'tool\retrieval_lab\diagnostics\reranking\correct_boundaries.py' --model 'tool\retrieval_lab\out\reranker\model_quint8_avx2.onnx' --tokenizer 'tool\retrieval_lab\out\reranker\tokenizer.json'
py -3.14 'tool\retrieval_lab\diagnostics\reranking\benchmark.py' --model 'tool\retrieval_lab\out\reranker\model_quint8_avx2.onnx' --tokenizer 'tool\retrieval_lab\out\reranker\tokenizer.json'
py -3.14 -m unittest discover -s 'tool\retrieval_lab\diagnostics\reranking' -p 'test_*.py'
```

The Python environment needs `numpy`, `onnxruntime`, and `tokenizers`.
The 53-record [scores checkpoint](./scores.jsonl) is resumable and includes
candidate text and raw logits; it checks hashes of the model, tokenizer and
candidate export. Re-exporting the candidates changes recorded timings and
therefore its hash: archive the old checkpoint before starting a fresh run.
To recheck Flutter baseline parity without replacing the input fixture, use
`flutter test --dart-define=WRITE_RERANKING_CANDIDATES=false` with the
exporter test path.

## Next strongest alternative

Benchmark a smaller multilingual pairwise model or distilled version on-device
against this exact candidate/gate pipeline, with a staged budget (for example
30 candidates) and explicit latency/memory limits. Evaluate on new,
lawyer-reviewed data after choosing the method; the present 46 queries and
co-ownership regression were used to inspect results and cannot establish
generalization or legal correctness.
