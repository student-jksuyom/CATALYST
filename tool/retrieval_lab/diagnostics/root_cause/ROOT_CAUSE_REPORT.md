# CATALYST hybrid retrieval: root-cause diagnosis

## Scope and method

This diagnosis uses only the 46 development queries in
`tool/retrieval_lab/diagnostics/stage1_baseline/cases.json` and the supplied
six off-topic probes. It does not read or tune against the held-out dataset,
does not modify production retrieval behavior, and does not change the Stage 1
baseline artifacts.

The runnable audit is
`tool/retrieval_lab/diagnostics/root_cause/root_cause_eval_test.dart`.
It ports the production scoring stages using the production `LocalTokenizer`,
`QueryAnalysis`, `Bm25Index`, article/chunk/training assets, and the saved
Stage 1 ONNX query vectors. Before reporting any ablation, it asserts exact
ordered Top-15 parity with the production hybrid report and exact Top-3 parity
with the legacy dense report: **46/46 exact matches for each path**.

Run from the repository root:

```powershell
flutter test tool\retrieval_lab\diagnostics\root_cause\root_cause_eval_test.dart
```

The detailed per-query trace, scores, candidate lists, ablations, and asset
checks are in `root_cause_results.json`; the smaller roll-up is in
`experiment_summary.json`.

## Implementation audit

- The service uses `query: ` for query embeddings and a 384-dimensional
  sentence embedding. The corpus export uses `passage: `; the training-query
  exporter also uses `query: `. The production and lab tokenizer JSON files
  are byte-identical (SHA-256
  `0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39`).
- The production ONNX asset is the pooled artifact built from the lab E5
  encoder; `build_pooled_e5.py` adds masked mean pooling and L2 normalization.
  The chunk exporter performs the corresponding masked pooling and
  normalization. All stored chunk and training vectors are finite and
  unit-normalized; used query vectors are also unit-normalized (observed norm
  range 0.99999963–1.00000036). No tokenizer, prefix, dimension, or unit-norm
  incompatibility was found.
- App query and training tokenization is truncated at 128 tokens. Corpus
  chunks are exported with a 256-token limit: the production tokenizer finds
  8 chunks over 128 tokens and 3 at the 256-token cap. This is a verified
  sequence-length difference to investigate, not proof of an encoder
  mismatch.
- Chunk owner count (4,368), article count (2,700), and per-article chunk
  counts match the current 60-word window / 40-word stride generator. Best
  chunk cosine is used per article. The BM25 index is over whole article
  texts, with the production stopwords/stemming, `k1=1.2`, and `b=0.75`.
- Hybrid retrieval uses normalized query text plus an English glossary
  semantic variant when available; the glossary and legal-word expansions
  also enter the lexical query. Translation is not an E5 dense variant.
  Stage 1's recorded processed query is unchanged for all 46 cases.
- Training assets contain 182 labeled query vectors (89 civil, 55 family,
  38 consumer), aligned to 2,700 articles, with no positive/negative
  conflicts. Production filters neighbors by inferred domain and requires
  cosine >= 0.90 before voting.
- `offline_eval_test.dart` scores `reviewedRelevantArticleIds` after
  normalizing article IDs. Every expected ID maps to the corpus, but the
  three distinct-text duplicate IDs listed below make some normalized IDs
  ambiguous.

## 1. Baseline

| Strategy | Hit@1 | Hit@3 | Hit@15 |
|---|---:|---:|---:|
| Production hybrid | 11/46 (23.9%) | 16/46 (34.8%) | 20/46 (43.5%) |
| Legacy E5 dense-only | 2/46 (4.3%) | 6/46 (13.0%) | 6/46 (13.0%) |

The legacy path returns only three results, so its Hit@15 equals its
all-returned hit count. There are 50 expected article labels across the
46 development queries. Production hybrid returns 21 of those at rank 15
(42% label recall), and 16 at rank 3 (32%).

## 2. Component candidate recall

“Query coverage” means a query has at least one expected article in the
component list. “Label recall” counts each of the 50 expected article labels.
Semantic coverage is at article level and uses the best chunk cosine.

| Stage (production pool 50) | Queries covered | Labels found |
|---|---:|---:|
| Primary normalized E5 variant, Top 50 | 25/46 (54.3%) | 27/50 (54%) |
| Glossary E5 variant alone, Top 50 | 4/46 (8.7%) | 4/50 (8%) |
| E5 primary + glossary union | 27/46 (58.7%) | 29/50 (58%) |
| BM25, Top 50 | 22/46 (47.8%) | 23/50 (46%) |
| Training-query candidates, Top 50 | 10/46 (21.7%) | 10/50 (20%) |
| Combined RRF list before cosine gate | 33/46 (71.7%) | 35/50 (70%) |
| Combined candidates surviving cosine >= 0.80 | 32/46 (69.6%) | 34/50 (68%) |
| Final Top 15 | 20/46 (43.5%) | 21/50 (42%) |
| Final Top 3 | 16/46 (34.8%) | 16/50 (32%) |

The glossary variant adds some coverage, but its standalone recall is small:
the union improves primary E5 coverage by only 2 queries and 2 labels.
The detailed trace records each relevant article's per-variant semantic rank
and cosine, BM25 rank and score, training vote, RRF rank, gate decision, and
final rank. It also writes the actual Top-50 component lists and all combined
RRF candidates for every query.

Expanding every source list to 500 increases the pre-gate combined coverage to
**45/46 queries and 49/50 labels**. At the production 0.80 gate, this is
40/46 queries and 43/50 labels. Despite the much higher candidate recall,
Hit@1/3/15 stays **11/16/20**. Without the gate, candidate coverage returns to
45/46 and 49/50, but Hit@K still stays 11/16/20.

## 3. Controlled ablations

All rows use the same Stage 1 labels. Unless noted, hybrid variants retain
the production 0.80 cosine gate, RRF `k=20`, and Top-15 result limit.
Candidate recall is the number of expected labels present before the gate.

| Configuration | Hit@1 | Hit@3 | Hit@15 | Candidate coverage |
|---|---:|---:|---:|---:|
| Production hybrid (pool 50) | 11 | 16 | 20 | 33 queries / 35 labels |
| E5-only, primary normalized variant, no gate | 2 | 6 | 19 | 25 / 27 |
| Legacy dense-only, exact production Top 3 | 2 | 6 | 6 | 25 / 27 |
| BM25-only | 2 | 3 | 9 | 22 / 23 |
| E5 + BM25, training disabled | 4 | 6 | 14 | 32 / 34 |
| Hybrid, cosine gate disabled | 11 | 16 | 20 | 33 / 35 |
| Hybrid, pool 100 | 11 | 16 | 20 | 35 / 38 |
| Hybrid, pool 200 | 11 | 16 | 20 | 38 / 41 |
| Hybrid, pool 500 | 11 | 16 | 20 | 45 / 49 |
| Hybrid, pool 500, no gate | 11 | 16 | 20 | 45 / 49 |
| Hybrid, training candidates from all domains | 13 | 17 | 21 | 34 / 36 |

Counts are out of 46 queries; the last column is queries covered / labels
found. E5-only here returns up to 15 ranked articles; the separate legacy row
matches the production dense-only implementation and its three-result limit.

### Weight sweeps

| BM25 weight | Training weight | Hit@1 | Hit@3 | Hit@15 |
|---:|---:|---:|---:|---:|
| 0.00 | 0.30 | 11 | 14 | 19 |
| 0.15 (production) | 0.30 (production) | 11 | 16 | 20 |
| 0.30 | 0.30 | 11 | 15 | 21 |
| 0.50 | 0.30 | 6 | 11 | 21 |
| 0.15 | 0.00 (training candidates retained, weight zero) | 4 | 6 | 14 |
| 0.15 | 0.15 | 11 | 14 | 19 |
| 0.15 | 0.50 | 10 | 16 | 20 |

The full 4x4 BM25/training-weight grid is in the JSON output. Among measured
weight settings, BM25 0.30 with training 0.30 gives **+1 Hit@15, unchanged
Hit@1, and -1 Hit@3** versus production; it is a trade-off, not an across-the-
board improvement.

### Cosine threshold and no-match probes

| Minimum cosine | Dev Hit@1/3/15 | Off-topic probes with any returned result | Returned results summed across probes |
|---:|---:|---:|---:|
| 0.75 | 11 / 16 / 20 | 5/6 | 75 |
| 0.78 | 11 / 16 / 20 | 3/6 | 32 |
| 0.80 (production) | 11 / 16 / 20 | 0/6 | 0 |
| 0.82 | 11 / 16 / 20 | 0/6 | 0 |
| 0.85 | 4 / 5 / 7 | 0/6 | 0 |
| 0.90 | 0 / 0 / 0 | 0/6 | 0 |

The six probes are the repository's existing off-topic checks, not a
representative negative evaluation set. At pool 50, disabling the gate does
not change which queries hit Top 15. The gate excludes the expected article
for `CC-EV-010` (cosine 0.7777; BM25 rank 33, score 6.207; RRF rank 59), but
without the gate that article still does not reach Top 15. Therefore this is a
real stage-level rejection, not a measured cause of a lost Hit@15. Raising the
threshold to 0.85 or higher is harmful on this development set; lowering it
to 0.78 or 0.75 raises false positives without improving positive-query
Hit@K.

The all-domain training ablation has the same six-probe false-positive counts
at every tested threshold as domain-filtered training (including 0/6 at 0.80).
That is encouraging but too small a negative set to certify safety.

## 4. Failure analysis

### Miss categories

At pool 50, among the 26 queries missing Hit@15:

| Primary failure stage | Queries |
|---|---:|
| No expected article in combined candidate list | 13 |
| Candidate present, but ranking fails to place it in Top 15 | 13 |
| Cosine-gate counterfactual loss | 0 |

The `CC-EV-010` target is separately recorded as rejected by the gate, but
removing the gate does not change that query's Hit@15 result. With pool 500,
the taxonomy shifts to **1 candidate-generation miss, 25 ranking failures,
and 0 gate-caused losses**. Four queries hit at rank 4–15 but not Top 3:
`CC-EV-002`, `CC-EV-019`, `FC-EV-003`, and `CA-EV-009`.

Pool-50 candidate-generation misses:
`CC-EV-001`, `CC-EV-004`, `CC-EV-008`, `CC-EV-011`, `CC-EV-012`,
`CC-EV-015`, `CC-EV-016`, `CC-EV-020`, `CC-EV-022`, `CC-EV-023`,
`CC-EV-024`, `FC-EV-001`, `CA-EV-010`.

Pool-50 ranking failures:
`CC-EV-005`, `CC-EV-006`, `CC-EV-007`, `CC-EV-009`, `CC-EV-010`,
`CC-EV-013`, `CC-EV-017`, `CC-EV-021`, `CC-EV-025`, `FC-EV-006`,
`FC-EV-014`, `CA-EV-005`, `CA-EV-007`.

### Legal-area and language groups

| Expected group | Queries | Hit@1 | Hit@3 | Hit@15 |
|---|---:|---:|---:|---:|
| Civil Code | 23 | 1 | 1 | 3 |
| Family Code | 13 | 5 | 9 | 10 |
| Consumer Act | 10 | 5 | 6 | 7 |

Civil Code is the weakest group: 20/23 miss Hit@15. By language:

| Language | Queries | Hit@1 | Hit@3 | Hit@15 |
|---|---:|---:|---:|---:|
| Taglish | 19 | 5 | 7 | 9 |
| English | 12 | 3 | 5 | 6 |
| Tagalog | 15 | 3 | 4 | 5 |

Tagalog has 10/15 Hit@15 misses; Taglish has 10/19; English has 6/12.
These are descriptive small-sample differences, not proof that language
alone causes failure. The detailed group-specific case IDs and stage causes
are included in `root_cause_results.json`.

### Domain inference and training-query signal

The inferred production `QueryDomain` differs from the development set's
coarse legal-area category on **16/46** queries:

- Civil cases: 12 inferred civil, 5 unknown, 4 consumer, 2 family.
- Family cases: 10 inferred family, 3 civil (`FC-EV-001` through `FC-EV-003`).
- Consumer cases: 8 inferred consumer, 1 family, 1 unknown.

Unknown domains disable production training-query retrieval. The measured
all-domain training candidate variant changes Hit@K from 11/16/20 to
13/17/21, while candidate coverage changes from 33/46 and 35/50 to 34/46 and
36/50. This is evidence that domain gating is worth further development-set
study, not proof that removing domain filtering is generally correct. The
classifier's domain categories are heuristic and may not correspond exactly
to the dataset's legal-area labels.

### Labels, corpus mappings, and chunks

- All 50 expected article IDs map to at least one corpus entry; none are
  missing. This does **not** establish that each expected label is legally
  complete or correct; those judgments need human review.
- There are three duplicate normalized article IDs whose corpus texts differ:
  `civilcode:1596` (indexes 1595/1596), `familycode:50` (2492/2592), and
  `familycode:129` (2571/2661). Retrieval deduplicates results by normalized
  ID and article lookup returns the first matching entry; the training
  exporter also resolves normalized-ID collisions first-wins. Thus the ID
  cannot uniquely identify which provision text was scored or labeled.
- The 4,368 chunk owners match the current 40-word stride / 60-word window
  generator, and all 2,700 articles have chunks. However, the current loop
  covers only about the first 500 words of long articles. Eight Consumer Act
  articles exceed that window; two are expected labels (`consumeract:23` and
  `consumeract:64`). `CA-EV-004` retrieves Article 64 at rank 1, but
  `CA-EV-005` misses Article 23 at rank 15 despite semantic rank 5 and cosine
  0.8391. The truncation is a verified coverage limitation, but its causal
  contribution to that miss has not been isolated by re-embedding.
- Eight source chunks exceed 128 tokenizer tokens and three reach the
  256-token export cap. Query and training vectors use a 128-token limit;
  corpus chunks were embedded with a 256-token limit. This length difference
  warrants a targeted re-embedding ablation, but is not by itself evidence
  that the embeddings are incompatible.

## 5. Ranked root causes

1. **Final ranking / score fusion is the largest measured bottleneck.**
   At pool 500, 49/50 expected labels are in the fused candidate set and
   43/50 survive the 0.80 gate, yet Hit@15 remains 20/46. The pool-500
   failure attribution is 25 ranking failures versus only one candidate
   generation failure. The precise ranking feature responsible still needs
   targeted score/reranker experiments.
2. **The production Top-50 candidate cutoff loses substantial recall.**
   At pool 50, the fused list covers only 33/46 queries and 35/50 labels;
   13 complete misses are attributable to candidate generation. Pool 500
   raises coverage to 45/46 and 49/50, but produces zero Hit@K gain without a
   better ranking stage.
3. **Heuristic domain classification can suppress or misdirect training
   signal.** It disagrees with the dataset category on 16/46 queries, and a
   no-domain-filter training experiment measures +2 Hit@1, +1 Hit@3, +1
   Hit@15. This needs broader negative-query validation before any production
   change.
4. **Multilingual semantic/lexical coverage is uneven, especially for Civil
   Code and Tagalog.** Primary E5 Top-50 coverage is 25/46 queries; BM25 is
   22/46. Their union improves recall, but Civil Code reaches only 3/23
   Hit@15 and Tagalog 5/15. Review hard cases and add reviewed examples rather
   than assuming a tokenizer defect.
5. **Corpus identity and long-article coverage have concrete data-quality
   risks.** Three IDs alias different texts; long-article chunking omits
   content past roughly 500 words for eight articles, including two expected
   labels. These can make both retrieval and ID-based evaluation ambiguous.

## 6. Recommendations

1. **Correct and validate corpus identities first.** Resolve the three
   duplicate-ID entries against authoritative sources and ensure labels,
   training indexes, lookup, and retrieval use a unique provision key. No
   retrieval gain is claimed for this correctness fix.
2. **Investigate reranking before simply enlarging candidate pools.** Pool
   expansion recovers candidates but does not move them into Top 15. Compare
   rank-only fusion, calibrated cosine/BM25/training scores, and a
   corpus-grounded second-stage reranker on development data; measure
   latency, Top-1/3/15, and candidate recall.
3. **Audit domain inference and test a guarded fallback.** The all-domain
   training variant is the best measured Hit@K configuration (13/17/21), but
   the improvement is only 46 development queries. Consider a confidence-
   gated domain fallback as a follow-up experiment; validate on a larger,
   independently reviewed negative set before shipping.
4. **Keep the current 0.80 cosine gate for now.** Lower thresholds produced
   3–5 false-positive off-topic probes without improving development Hit@K;
   0.85 sharply reduced recall. Pool-500 no-gate runs show no development
   Hit@K gain.
5. **Treat BM25 0.30 as a measured trade-off, not a release recommendation.**
   It yields +1 Hit@15 but -1 Hit@3 and no Hit@1 improvement. Do not select
   it solely from the maximum Hit@15 in this small dataset.
6. **Run targeted coverage experiments.** Re-embed uncapped / tail-aware
   chunks for long statutes and compare the affected cases; review missed
   expected labels and high-ranked alternatives manually. Do not modify the
   held-out set during this work.

## 7. Measured gains and limitations

Only observed development-set deltas are reported:

- No-domain-filter training: **+2 / +1 / +1** Hit@1/3/15.
- BM25 weight 0.30 with training weight 0.30: **0 / -1 / +1**.
- Pool 50 to 500: **0 / 0 / 0** Hit@K, despite candidate coverage increasing
  from 33/46 and 35/50 to 45/46 and 49/50.
- Disabling the 0.80 gate: **0 / 0 / 0** Hit@K.

These are not estimates of production outcomes. The positive set has only 46
queries, the no-match check has six probes, no significance testing was
performed, and labels were not re-adjudicated. The scoring audit uses saved
Stage 1 vectors documented as production-ONNX outputs; it does not freshly
run ONNX inference. Exact ordered parity validates the scoring port against
the saved production results, not vector provenance or future model exports.
No latency, memory, or mobile-device performance measurements were made.

No production changes were made as part of this diagnosis.
