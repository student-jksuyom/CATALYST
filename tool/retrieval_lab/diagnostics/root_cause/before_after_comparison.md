# Retrieval ranking experiment: before and after

## Scope

Ran 256 configurations through `LocalSemanticRetrievalService` on the 46 Stage 1 development queries and six existing off-topic probes. No held-out evaluation data was read. The query encoder used the saved Stage 1 ONNX vectors cached by token IDs; it did not rerun ONNX.

Warm-up request: 1463 ms. Runtime numbers are 
host test timings, not mobile-device latency measurements.

## Selected configuration

`all_domains__bm25_015__training_030__rrf_20__calibratedScore`

## Existing co-ownership regression gate

Checked all 256 configurations against the existing co-ownership ranking regression; 64 passed. The selected configuration passes.

The highest development-metric configuration `all_domains__bm25_015__training_045__rrf_20__rankBased` was not selected because it failed this existing regression.

## Development metrics

| Metric | Original production | Selected | Change |
|---|---:|---:|---:|
| Hit@1 | 11/46 | 13/46 | +2 |
| Hit@3 | 16/46 | 17/46 | +1 |
| Precision@3 | 11.59% | 12.32% | +0.72 pp |
| Hit@15 | 20/46 | 21/46 | +1 |
| Negative probes with results | 0/6 | 0/6 | 0 |
| Negative results returned | 0 | 0 | 0 |

## Query ranking changes

8 of 46 query Top-15 lists changed.

| Dataset case | Relevant rank before | Relevant rank after |
|---|---:|---:|
| CC-EV-005 | miss | 1 |
| CC-EV-013 | miss | miss |
| CC-EV-016 | miss | miss |
| CC-EV-019 | 4 | 6 |
| CC-EV-021 | miss | miss |
| FC-EV-001 | miss | miss |
| FC-EV-002 | 3 | 4 |
| CA-EV-009 | 5 | 1 |

Exact before/after article lists are included in the CSV.

## Runtime

- Positive batch: 945.3 ms original; 778.4 ms selected.
- Negative probes: 32.1 ms original; 26.5 ms selected.
- Unique cached query vectors used: 67.
- Production service defaults matched selected Top-15 lists for 46/46 queries and matched all 6 negative probes.

## Negative-probe limitation

The six probes are a limited safety check, not a comprehensive false-positive evaluation. No conclusion about general abstention safety follows from these results.

## Production decision

The selected configuration is integrated as the production default. Rollback settings remain 0.15 BM25, 0.30 training-query weight, filtered training domain, RRF k=20, and calibrated-score ranking.
