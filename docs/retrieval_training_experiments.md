# CATALYST retrieval training experiments

**Run date:** 2026-11-13  
**Status:** Offline development experiments; no candidate was integrated into
the app.

## Summary

The production retriever remains multilingual E5-small with article-chunk
embeddings, BM25, reciprocal-rank fusion, and a labeled training-query signal.
The controlled training runs below fine-tuned a separate
`paraphrase-multilingual-MiniLM-L12-v2` Sentence-BERT model using whole-article
representations. They do not measure a replacement for the complete production
pipeline.

Experiment B, selected at epoch 10, was the strongest MiniLM run by Evaluation
Hit@3 (8/46). It did not match the production E5 hybrid baseline (16/46 Hit@3).
Experiment C reduced its training pair loss to 0.0087 by epoch 30, but its
final sampled retrieval checkpoint fell to 5/46 Hit@3. Its best sampled
retrieval checkpoint was epoch 10, not epoch 30. Lower training or validation
pair loss was therefore not a reliable proxy for retrieval quality.

Keep the production E5 system. The MiniLM checkpoint is experimental and has
not been tested for app integration, latency, memory, or mobile deployment.

## Implementation and data audit

- **Production and experimental architectures are separate.** Production uses
  multilingual E5-small with chunked articles, dense cosine ranking, BM25,
  reciprocal-rank fusion, and a small training-query signal.
  `finetune_sbert.py` fine-tunes multilingual MiniLM-L12-v2 (384-dimensional
  sentence embeddings) and evaluates whole-article representations against the
  2,700-article corpus.
- **Training objective and optimizer:** `CosineSimilarityLoss` on narrative /
  article pairs labeled 0 or 1, AdamW, linear warmup/decay, and batch size 8.
  Pair labels come from the existing Training Dataset; no legal examples or
  article IDs were fabricated.
- **Data profile:** Training contains 200 pairs (178 positive, 22 negative).
  Evaluation contains 50 rows grouped into 46 positive queries and one
  negative-only query; it has only one negative pair. The corpus references
  were validated. The dataset audit found no exact narrative overlap between
  splits and no within-split conflicting labels. Three law/article key
  collisions exist in the corpus, but none are referenced by these splits.
- **Retrieval and selection:** Evaluation retrieves against the full corpus.
  Checkpoints are selected by Evaluation Hit@3, then MRR@10, Hit@1, and
  Hit@10. Pair loss is recorded separately and is not the selection metric.
- **Test isolation:** B and C did not use Testing data. A reuses a legacy run
  whose output folder also contains an older Testing report; that report was
  not read or used in these comparisons. Historical overlap with the legacy
  Testing split means it is not an untouched final test for this candidate.
  The separate held-out gate still has provisional labels awaiting qualified
  legal review; no final test score is claimed.

The Evaluation Dataset is small and labels are sparse: an unlisted article is
not necessarily irrelevant. In particular, one negative-only query cannot
support conclusions about negative rejection.

## Configurations and results

All runs used seed 42 and batch size 8. B and C started from the same cached
base MiniLM checkpoint, not from each other's weights. B used 25 warmup steps;
C used 75 because its training schedule was longer. A reuses the clean prior
three-epoch run with the same baseline training hyperparameters; its retrieval
was evaluated after the final epoch, rather than at per-epoch retrieval
checkpoints.

| Experiment | Epochs | Learning rate | Retrieval checks | Selected epoch |
| --- | ---: | ---: | --- | ---: |
| A — baseline | 3 | 2e-5 | Final epoch (prior clean run) | 3 |
| B — extended | 10 | 1e-5 | 5, 10 | 10 |
| C — intentional overfit diagnostic | 30 | 1e-5 | 10, 20, 30 | 10 |

Validation results below are on the same 46 positive Evaluation query groups.
Train Hit@3 uses the 171 positive Training query groups. `n/r` means the
historical A report did not record that metric. The loss column is the final
epoch's mean training loss; A's separately recomputed post-training pair loss
was 0.0816.

| Model / checkpoint | Final-epoch mean train loss | Validation pair loss | Train Hit@3 | Eval Top-1 | Eval Hit@3 | Eval P@3 | Eval R@3 | Eval MRR@10 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| MiniLM before fine-tuning | n/r | 0.5124 | n/r | 2/46 (0.0435) | 3/46 (0.0652) | n/r | n/r | 0.0702 |
| A — epoch 3 | 0.0850 | 0.0309 | n/r | 2/46 (0.0435) | 5/46 (0.1087) | n/r | n/r | 0.1002 |
| B — epoch 10 | 0.0620 | 0.0331 | 30/171 (0.1754) | 4/46 (0.0870) | 8/46 (0.1739) | 0.0652 | 0.1739 | 0.1412 |
| C — selected epoch 10 | 0.0514 | 0.0298 | 32/171 (0.1871) | 5/46 (0.1087) | 7/46 (0.1522) | 0.0507 | 0.1413 | 0.1450 |
| Production E5 hybrid | n/r | n/r | n/r | 11/46 (0.2391) | 16/46 (0.3478) | 0.116 | 0.320 | MRR@15 0.304 |

Production E5 results are included as an operational reference, not a
strictly like-for-like comparison: production uses hybrid signals, whereas
the experimental MiniLM evaluation is dense whole-article ranking. The
Evaluation labels and metrics remain provisional and do not establish legal
relevance or applicability.

### Experiment details

- **A:** The untuned MiniLM scored Hit@3 3/46 and MRR@10 0.0702. After three
  epochs, it reached Hit@3 5/46 and MRR@10 0.1002; Top-1 remained 2/46.
  Mean epoch training loss fell from 0.2259 to 0.0850. Separately recomputed
  pair losses moved from 0.4800 to 0.0816 on Training and from 0.5124 to 0.0309
  on Evaluation.
- **B:** Training loss fell from 0.3546 to 0.0620. Validation pair loss was
  lowest at epoch 3 (0.0297), but the epoch-10 checkpoint improved Hit@3 from
  7/46 at epoch 5 to 8/46, with MRR@10 0.1412. This was the best MiniLM
  checkpoint by the predeclared Hit@3-first selection rule.
- **C:** Training loss fell from 0.4205 to 0.0087 by epoch 30. Validation pair
  loss reached 0.0240 at epoch 27, but retrieval was measured only at epochs
  10, 20, and 30. Hit@3 was 7/46 at both epochs 10 and 20, then 5/46 at epoch
  30; the tie-break selected epoch 10 (MRR@10 0.1450 versus 0.1081 at epoch
  20). Thus epoch 10 is the best **sampled** checkpoint, not proven to be the
  best of all 30 epochs. The selected checkpoint's Training Hit@3 was only
  32/171. The experiment demonstrates that pair loss can continue decreasing
  without retrieval gains; it does not demonstrate strong retrieval
  memorization.

## Weaknesses, conclusions, and next step

1. **The main bottleneck is not shown to be too few epochs.** B improves over
   the original MiniLM baseline, but C's much lower final training loss did
   not produce better final retrieval. Do not extend training solely to lower
   loss.
2. **Negative supervision is inadequate for a reliable negative-sample
   conclusion.** Training is 178 positive versus 22 negative pairs; Evaluation
   has only one negative pair. Negative-label quality and retrieval rejection
   cannot be inferred from these counts.
3. **Per-category, per-language, and per-article error analysis is unavailable
   in the saved aggregate reports.** No categories or articles are named as
   consistent successes/failures here rather than guessing. A follow-up should
   save per-query rankings and report results by manually verified category
   and English/Tagalog/Taglish variant.
4. **No candidate is production-ready.** B is the best MiniLM checkpoint in
   these runs, but it trails the production hybrid baseline and has not been
   evaluated in the app.

The next experiment should first improve the reviewed labels and diagnostics,
not change several hyperparameters at once: add manually verified negatives
based on high-scoring false positives, preserve existing article IDs, and
report per-query and language/category results. Continue to keep the Testing
split sealed; run a final evaluation only after a genuinely untouched,
independently reviewed test set is available.

## Reproducibility and checkpoint

Configurations:

- [Experiment A](../tool/retrieval_lab/configs/experiment_a_baseline.json)
- [Experiment B](../tool/retrieval_lab/configs/experiment_b_extended.json)
- [Experiment C](../tool/retrieval_lab/configs/experiment_c_overfit.json)

Detailed machine-readable reports are saved separately:

- A: `tool/retrieval_lab/out/sbert_finetune/20261110_003421/evaluation_report.json`
- B: `tool/retrieval_lab/out/controlled_experiments/B-extended/20261113_093529/evaluation_report.json`
- C: `tool/retrieval_lab/out/controlled_experiments/C-intentional-overfit/20261113_100806/evaluation_report.json`

Best experimental checkpoint (B, epoch 10):
`tool/retrieval_lab/out/controlled_experiments/B-extended/20261113_093529/candidate_model/`.
It is not the production model and must not be used as evidence of legal
accuracy.
