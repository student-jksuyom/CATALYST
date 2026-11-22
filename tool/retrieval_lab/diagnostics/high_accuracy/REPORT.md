# High-accuracy retrieval sprint

## Production data repair

The bundled hybrid ranking and 0.80 cosine gate are unchanged. The following
data correctness fixes are installed in the app assets:

1. Civil Code 1595 had been split at a reference to Article 1596; the
   continuation is rejoined to 1595. The separate 1596 record remains 1596.
   One training label previously resolved to the continuation and now resolves
   to the actual Article 1596.
2. The provision mislabeled Family Code 50 is now Article 150. Its heading
   was corrected, the omitted clause about other ascendants and descendants
   was restored, and the sibling clause was renumbered to (4). The Supreme
   Court's [Martinez decision](https://elibrary.judiciary.gov.ph/thebookshelf/showdocs/1/43553)
   quotes the complete provision. The LawPhil transcription has the same
   numbering and omission errors as the old corpus.
3. The provision mislabeled Family Code 129 is now Article 219, including its
   heading; an unrelated following chapter heading was removed from its text.
   See the [Family Code](https://lawphil.net/executive/execord/eo1987/eo_209_1987.html).
   See also the [Civil Code](https://lawphil.net/statutes/repacts/ra1949/ra_386_1949.html).
4. Added the previously omitted trailing 60-word / 40-stride windows for
   Consumer Act articles 4, 15, 23, 31, 64, 68, 85 and 89.

The repair reduces 2,700 records with three ID collisions to 2,699 distinct
normalized citations. It changes 4,368 chunks to 4,514; 4,361 vectors were
reused and 153 freshly encoded. All chunk owners and vector lengths match;
all vectors are finite and unit normalized. Two windows reach the tokenizer
limit, but the next overlapping window covers the truncated text. Six sampled
fresh vectors matched the original encoder with minimum cosine 0.99999994.
All 182 remapped training entries were checked against their source workbook;
training-query embeddings were unchanged. The training exporter now rejects
duplicate normalized IDs rather than silently choosing the first.

This is a targeted repair, **not** a comprehensive legal audit of the corpus.
The legal text changes above are explicit; existing unrelated corpus warnings
remain. See [audit.json](./repaired_assets/audit.json).

## Development evaluation, not held-out

46 development queries, 50 relevant labels. The actual Flutter service was
run against the packaged corrected assets and cached E5 query vectors. Pool
sizes are per source; candidate coverage below is the *gated, ranked top 200*,
not the pre-gate union.

| Configuration | Hit@1 | Hit@3 | Hit@15 | Precision@3 | Candidate coverage (queries / labels) |
|---|---:|---:|---:|---:|---:|
| Before, production pool 50 | 13/46 | 17/46 | 21/46 | 12.32% | 32/46 / 34/50 |
| After repair, pool 50 | 13/46 | 17/46 | 21/46 | 12.32% | 32/46 / 34/50 |
| Before, experimental pool 500 | 13/46 | 17/46 | 21/46 | 12.32% | 37/46 / 39/50 |
| After repair, pool 500 | 13/46 | 17/46 | 21/46 | 12.32% | 37/46 / 39/50 |

Pool 500 improves gated candidate coverage but not Hit@K. On the prior corpus,
the original root-cause audit found 45/46 queries and 49/50 labels in the
pool-500 **pre-gate union**, a different stage and older ranking configuration.
All six existing off-topic probes returned no candidates at both pool sizes;
the co-ownership regression passed at both sizes. Six probes cannot establish
real-world false-positive safety.

At pool 50, 14 misses have no labeled relevant candidate in the gated top 200;
15 more have a candidate but no labeled hit in the top three. Civil Code
queries are particularly weak: 2/23 Hit@3, versus 8/13 Family and 7/10
Consumer. Labels may be incomplete and need legal review. Existing processing
already unions E5 and BM25 candidates, applies normalized and glossary E5
variants, and aggregates an article by its best chunk. None of the 46 queries
contains an explicit article/section-number citation, so they cannot measure
an exact-reference rule. No threshold or glossary rules were tuned here.

The earlier experimental cross-encoder attained 14/19/25 and 13.77%
Precision@3 on this development set, but remains unsuitable for deployment
without mobile inference and latency evidence. These development results do
not demonstrate accuracy on unseen concerns.

## Grouped cross-validation

[grouped_ltr.py](./grouped_ltr.py) evaluates one fixed L2 logistic model, not
a parameter search. Features are existing hybrid score and rank plus
query/article term overlap; labels are never input features. Five grouped
folds keep each legal subdomain together and also union queries sharing a
relevant article or a high character-level similarity. The scaler and model are
fit on training folds only. Results use out-of-fold predictions on the
**pre-repair** candidate export:

| | Hit@1 | Hit@3 | Hit@15 | Precision@3 |
|---|---:|---:|---:|---:|
| Existing hybrid | 13/46 | 17/46 | 21/46 | 12.32% |
| Out-of-fold lightweight model | 13/46 | 17/46 | 21/46 | 12.32% |

Training versus validation Hit@3 by fold: 15/32 vs 2/14, 16/36 vs 1/10,
12/38 vs 5/8, 14/39 vs 4/7, and 12/39 vs 5/7. Each training fold has only
25–30 labeled positive candidates. Unlabeled candidates are treated as
negative during training, although they may be relevant.

There are 13 grouping components. CC-EV-001/002 are near duplicates; CC-EV-004/024
and CC-EV-013/CA-EV-007 share labels and are grouped. A character-similarity
audit also found CA-EV-004 at 0.82 similarity to a pre-existing training
query. The production training-query index and candidate generation were
**not** rebuilt per fold, so their possible overlap with validation queries
remains; character checks cannot establish absence of semantic paraphrases.
Thus this is an exploratory OOF reranker comparison, not a fully leakage-free
or independent generalization measurement. No trained model is shipped.
Detailed folds and predictions: [grouped_ltr_results.json](./grouped_ltr_results.json).

## Runtime, memory and offline checks

On the Windows host, cached-vector Flutter runs averaged 92.3 ms/query after
the repair at pool 50, versus 67.6 ms in the earlier non-isolated baseline
run; pool 500 averaged 179.6 ms versus 136.6 ms historically. Runs were
separate, not controlled benchmarks; they exclude E5 inference, model startup
and mobile overhead. The repaired test process peaked at 420.4 MiB including
the test harness and fixtures; no comparable pre-repair Flutter peak was
recorded. The embedding file increased by 219 KiB. Device latency and memory
remain unmeasured.

Local Python ONNX Runtime successfully encoded a development query offline
with the packaged E5 model; its cosine against the cached vector was
approximately 1.0. The Flutter evaluation used cached vectors, not Flutter
ONNX inference on a mobile device. Dart analysis was clean, and 33 targeted
Flutter tests passed, including the packaged 46-query evaluation and
co-ownership regression. The earlier full suite had five unrelated widget
failures; it was not rerun in this sprint.

## Decision and remaining blockers

Only the citation/chunk correctness repair was applied. No learned reranker,
cross-encoder, wider candidate pool, or threshold change was enabled; the
existing hybrid remains the fallback. Development Hit@3 is 17/46 (37.0%),
well below 70%. The independent held-out dataset was neither accessed for
tuning nor evaluated in this sprint. Larger independently reviewed,
grouped concern sets, a broader no-match set, legal review of corpus and labels,
and measurements on intended mobile hardware are required before claiming
generalization or shipping a reranker.

## Reproduction

The original four data assets are available at Git revision
`106822909f73ba7f7abefa7dc3e7bfe1efb032d0`. Extract them without text
conversion to a separate directory, then run:

```powershell
py -3.14 tool\retrieval_lab\diagnostics\high_accuracy\repair_assets.py --source-dir <original-assets-directory>
py -3.14 tool\retrieval_lab\diagnostics\high_accuracy\grouped_ltr.py
flutter test --dart-define=TEST_PACKAGED_REPAIR=true tool\retrieval_lab\diagnostics\high_accuracy\repaired_eval_test.dart
```

The repair script requires the existing local E5 lab model and tokenizer;
the grouped experiment requires numpy, scikit-learn and openpyxl. The prior
candidate export and query vectors are fixtures, not a held-out evaluation.
