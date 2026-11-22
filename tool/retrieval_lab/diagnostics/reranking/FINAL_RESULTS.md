# Final retrieval optimization

## Accuracy

46 development queries, unchanged 0.80 gate, source pool 50, reranker weight
0.50. Top 10 preserves the original ranks 11–15 after reranking its prefix.

| Configuration | Hit@1 | Hit@3 | Hit@15 | Precision@3 |
|---|---:|---:|---:|---:|
| Production hybrid | 13 | 17 | 21 | 12.32% |
| Earlier experimental reranker, Top 100 | 14 | 19 | 25 | 13.77% |
| Top 10 | 13 | 18 | 21 | 13.04% |
| Top 20 | 13 | 18 | 22 | 13.04% |
| Top 30 | 13 | 18 | 23 | 13.04% |

All three passed the co-ownership regression and returned no results for the
six negative probes. These probes are not a comprehensive safety evaluation.
The 30-candidate full inference run reproduced all 46 cached evaluation
rankings, with and without document-token caching. No held-out data was used.

## Latency and memory

Windows Ryzen 5 7520U, four CPU threads; E5 query vectors were cached, so
these times exclude E5 inference and mobile overhead. Peak memory is the
whole Python process working set. Model startup is not included in query time.

| Configuration | Mean reranker time | Peak memory |
|---|---:|---:|
| Previous full-pool reranker (46 queries) | 10.67 s | 590.0 MiB |
| Top 10, no token cache (3-query sample) | 2.25 s | 542.2 MiB |
| Top 20, no token cache (3-query sample) | 3.51 s | 541.9 MiB |
| Top 30, no token cache (46 queries) | 4.04 s | 545.1 MiB |
| Top 30, document-token cache (46 queries) | 3.59 s | 546.3 MiB |

The cache held 719 article tokenizations; its measured 30-candidate p95 was
6.33 s. Timings are separate, non-isolated host runs and do not establish
that caching alone caused the full difference. ONNX sessions were already
reused and the x86 model was already INT8 quantized.

## Production

The reranker remains disabled. The current hybrid default is unchanged.

## Remaining blockers

The best tested short cutoff is still above the provisional two-second
target on this host and reduces accuracy versus the earlier Top-100 reranker.
No Android device was connected; the AVX2 model and Python implementation
have not been validated as an offline mobile integration. Memory, latency,
and ranking quality must be verified on intended hardware before enabling it.

[Cutoff results](./final_cutoffs.json) ·
[Uncached measurements](./final_benchmark_no_cache.json) ·
[Cached measurements](./final_benchmark_cache.json)
