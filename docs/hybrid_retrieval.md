# Hybrid retrieval pipeline: diagnosis and baseline

**Current architecture:** Article search and passage evidence always run on
device. The Worker source accepts XAI follow-up only; it must be redeployed to
change the live Worker. The Gemini article-ranking path and ML Kit downloads
have been removed. The local E5 encoder finds semantically similar text; it
does not generate legal reasoning or verify applicability. The labeled
training-query index supplements E5 ranking, but the experimental fine-tuned
encoder has not been deployed because its measured results were weak.

## Current development evaluation

The lexical query expands selected everyday words to their legal equivalents
(for example, "landlord" to "lessor") for BM25 only; the E5 encoder still
receives the original analyzed query. On the 12-query pilot, the expected
landlord provision moved from outside the first 15 to rank 8. For original
queries, Hit@3 stayed at 4/12 and Hit@15 rose from 5/12 to 6/12. The six
existing off-topic probes returned no articles.

On the project's Evaluation Dataset, the production Flutter ranking found a
labeled provision at rank 1 for 11/46 positive query groups, within rank 3
for 16/46, and within rank 15 for 20/46. These numbers were unchanged by
the wording expansion. One negative-only group was excluded. Labels are
sparse: an unlisted article is not necessarily irrelevant. Both datasets
have been used during development and are not independent final tests.
Similarity and these metrics do not establish that a provision applies to
the narrative; a fresh held-out evaluation with lawyer-reviewed relevance and
applicability judgments is needed.

### Alternative encoder screen (development only)

`tool/retrieval_lab/screen_multilingual_models.py` compares E5-small, E5-base,
and BGE-M3 on the same 46 positive groups from `Evaluationdataset.xlsx`, using
the current article chunks and dense best-chunk ranking only. It does not use
BM25, training-query votes, or abstention. Results were:

| Encoder | Hit@1 | Hit@3 | Hit@15 | MRR@15 |
| --- | ---: | ---: | ---: | ---: |
| multilingual-e5-small | 2/46 | 6/46 | 18/46 | 0.122 |
| multilingual-e5-base | 6/46 | 11/46 | 17/46 | 0.203 |
| BGE-M3 | 7/46 | 14/46 | 24/46 | 0.247 |

BGE-M3 is the strongest standalone encoder in this screen, and E5-base
improves on E5-small at Hit@1 and Hit@3. Neither encoder-only result exceeds
the current E5 hybrid pipeline on the same development set (11/46 Hit@1,
16/46 Hit@3, 20/46 Hit@15). This is not a full-pipeline replacement test:
the current system also uses BM25 and labeled training-query signals, while
these candidates were screened as dense encoders only. No candidate was
integrated into the app. Labels are provisional and this development set is
not independent; keep the held-out gate untouched for the final candidate
comparison. BGE-M3 also took a long time to encode the corpus on CPU, so mobile
latency, memory, model size, and quantization remain untested.

### BGE-M3 in the current hybrid pipeline (development only)

Run the same hybrid ranking components with BGE-M3 vectors using:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\screen_bge_hybrid.py
```

The run used the same 46 positive development groups, current article chunks,
BM25, query variants, training-query votes, rank fusion, and production score
weights and thresholds. Current E5 hybrid reproduced 11/46 Top-1, 16/46 Hit@3,
and 20/46 Hit@15 (MRR@15 0.304). BGE-M3 returned no results for all 46 groups
with the unchanged 0.80 cosine gate.

This is a failed **drop-in replacement** test, not evidence that BGE-M3's
underlying ranking is worse: the 0.80 gate and 0.75/0.90 dense-score mapping
are explicitly calibrated for E5, and the BGE screen did not tune them. The
run did not evaluate abstention or mobile feasibility. Do not replace E5 on
this evidence. A BGE-specific calibration would need a separate development
process followed by an untouched independent evaluation; current labels are
provisional and cannot establish legal accuracy.

### Controlled MiniLM training experiments (development only)

Three controlled fine-tuning experiments compared the existing MiniLM trainer
with extended training and an intentional overfit diagnostic. The 10-epoch
candidate had the best MiniLM Evaluation Hit@3 (8/46), but trailed production
E5 hybrid retrieval (16/46). In the 30-epoch diagnostic, training loss kept
falling while the final sampled Hit@3 dropped to 5/46; the selected epoch-10
checkpoint did not establish reliable memorization. No candidate was deployed.

See the [controlled training report](./retrieval_training_experiments.md) for
the audit, configurations, validation comparisons, limits, and best
experimental checkpoint. The legacy Testing split remains retired from model
selection; no final test claim is made.

## Independent held-out quality gate

`DATA/Datasets/Independent_Heldout_Test_Dataset_Gate.xlsx` contains 42 new
narratives (14 each in English, Tagalog and Taglish), with 27 retrieval-positive
cases and 15 annotated no-match cases. The source workbook's intended scope is a
test stratum, not a legal conclusion. All rows currently say
`NEEDS_SECOND_REVIEW`; the current annotations are an apprentice-reviewed,
provisional baseline awaiting review by an actual legal professional.

The gate measures Hit@1/3/15 and MRR@15 only for cases with explicitly reviewed
relevant article IDs, and counts any returned result on a `NO_MATCH` case as a
false positive. It does not report precision because unjudged articles are not
negative labels. `Hard_Negative_Article_IDs` are candidate notes only and are
never imported or scored. An article-level negative label is accepted only
when its ID is explicit, `Review_Status` is `REVIEWED`, and
`Hard_Negative_Verification_Status` is `PARTIALLY_VERIFIED` or `COMPLETE`.

Run the production Flutter ranking with the bundled encoder:

```powershell
$out = 'tool\offline_eval\out\heldout'
.\.venv\Scripts\python.exe tool\offline_eval\export_heldout_cases.py `
  --dataset DATA\Datasets\Independent_Heldout_Test_Dataset_Gate.xlsx `
  --output "$out\cases.json"
flutter test tool\offline_eval\offline_eval_test.dart `
  --dart-define=MODE=dump --dart-define=EVALUATION_KIND=heldout `
  "--dart-define=CASES_FILE=$out\cases.json" "--dart-define=OUTPUT_DIR=$out"
.\.venv\Scripts\python.exe tool\offline_eval\embed_ids.py --output-dir $out
flutter test tool\offline_eval\offline_eval_test.dart `
  --dart-define=MODE=eval --dart-define=EVALUATION_KIND=heldout `
  "--dart-define=CASES_FILE=$out\cases.json" "--dart-define=OUTPUT_DIR=$out"
.\.venv\Scripts\python.exe tool\offline_eval\summarize_heldout.py `
  "$out\report.json" --write-baseline tool\offline_eval\heldout_baseline.json `
  --allow-provisional
```

For subsequent runs, replace `--write-baseline ...` with
`--check-baseline tool\offline_eval\heldout_baseline.json --allow-provisional`.
This is a no-regression guard against the recorded baseline, not an absolute
quality threshold or a legal-accuracy claim. Keep the set out of training and
tuning; after final legal review, update the review statuses and deliberately
establish a new baseline.

The first provisional run (2026-11-12) found a labeled relevant article at
rank 1 for 7/27 in-corpus cases, within rank 3 for 11/27, and within rank 15
for 16/27 (MRR@15 0.363). All 15 no-match cases returned provisions in that
run. A current-code rerun after adding a conservative phrase-based unsupported-
topic check kept the positive retrieval metrics unchanged, but reduced no-match
false-positive cases to 8/15. The check is not a trained scope model and still
misses tax, privacy, and labor examples; the gate **continues to fail** its
zero-false-positive requirement. The labeled retrieval figures and no-match
judgments remain provisional and do not establish legal accuracy or
applicability. Do not tune against this held-out set; use separate development
cases to address the failures.

## Provisional abstention-model experiment

`DATA/Datasets/Abstention_Development_Dataset.xlsx` is a separate, synthetic
development set with in-scope and out-of-scope examples in English, Tagalog,
and Taglish. Its labels are explicitly provisional and need legal review. The
classifier uses the existing E5 encoder as a frozen feature extractor and
trains a separate logistic scope head; it does not retrain the encoder or
change the retrieval/ranking pipeline.

Run the grouped cross-validation experiment with:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\train_abstention_model.py
```

The report keeps all language variants of an issue family in the same fold and
reports false-abstention and missed-abstention rates. The current provisional
run has a 25.0% false-abstention rate (9/36 in-scope) and a 15.4%
missed-abstention rate (6/39 out-of-scope); the shared-corpus-term challenge
missed 6/30 out-of-scope cases. These are grouped cross-validation results on
synthetic labels, not independent legal validation. The model and report are
saved under `tool/retrieval_lab/` and are not app assets. Do not use this model
to suppress production results until independent evaluation and legal review
of its labels are complete.

For a stronger review cycle, use
`DATA/Datasets/Abstention_Development_Review_Set.xlsx` for development and keep
`DATA/Datasets/Abstention_Independent_Evaluation_Set.xlsx` sealed for final
testing. Both contain realistic English, Tagalog, and Taglish narratives,
shared-keyword challenges, unverified candidate labels, and separate fields
for retrieval relevance and legal applicability. Candidate labels are not
ground truth. I cannot obtain attorney review; a qualified legal professional
must complete the reviewer fields before the reviewed workflow will run.

After review, train only from the development workbook and evaluate once on the
independent workbook:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\reviewed_abstention_workflow.py train
.\.venv\Scripts\python.exe tool\retrieval_lab\reviewed_abstention_workflow.py evaluate `
  --model tool\retrieval_lab\abstention_model_reviewed.json
```

The workflow ignores candidate labels, requires `Review_Status=REVIEWED`,
checks positive article IDs against the bundled corpus, and rejects evaluation
sets whose issue-family groups overlap model training. Its output remains
offline and must not control user responses. For a predeclared comparison,
evaluate the existing provisional model and the reviewed-label model against
the same independent workbook, writing separate reports; do not tune either
model after inspecting those evaluation results.

To reproduce the Evaluation Dataset run with the packaged encoder and Flutter
ranking, from the project root:

```powershell
$out = 'tool\offline_eval\out\evaluation'
.\.venv\Scripts\python.exe tool\offline_eval\export_evaluation_cases.py `
  --dataset DATA\Datasets\Evaluationdataset.xlsx --output "$out\cases.json"
flutter test tool\offline_eval\offline_eval_test.dart --dart-define=MODE=dump `
  "--dart-define=CASES_FILE=$out\cases.json" "--dart-define=OUTPUT_DIR=$out"
.\.venv\Scripts\python.exe tool\offline_eval\embed_ids.py --output-dir $out
flutter test tool\offline_eval\offline_eval_test.dart --dart-define=MODE=eval `
  "--dart-define=CASES_FILE=$out\cases.json" "--dart-define=OUTPUT_DIR=$out"
.\.venv\Scripts\python.exe tool\offline_eval\summarize.py "$out\report.json"
```

The multilingual cross-encoder tested as a top-15 reranker reduced Hit@3
on both development sets, so it was not adopted. Passage-level BM25 blending
also did not improve Hit@3 on the Evaluation Dataset and reduced it on the
pilot at higher weights; it was not adopted.

The historical diagnosis below describes the former architecture and is kept
only as a record of past experiments, not as the current implementation.

Diagnosis date: 2026-11-03. "Verified" means observed by running code or the live
endpoint; "not verified" means it needs a Gemini key or a device.

## 1. Who does what

| Stage | Component | Where |
| --- | --- | --- |
| Query analysis, glossary | `QueryAnalysis`, `LegalQueryPreprocessor` | on device |
| **Retrieval** (candidate generation) | `LocalSemanticRetrievalService._matchHybrid` in `lib/services/catalyst_local_retrieval_service.dart`: multilingual-e5-small ONNX dense chunk embeddings + BM25 (`lexical_index.dart`) + a compact index of 182 labeled Training Dataset queries. Up to three same-domain examples with cosine at least 0.90 contribute reviewed article labels. Reciprocal-rank fusion generates candidates; the final score combines 70% of the prior `0.85 * dense + 0.15 * BM25` score with 30% of the normalized example vote. Article cosine gate: 0.80. | on device |
| **Reranking** (online only) | Gemini, called by the Cloudflare Worker `backend/worker.js` (`buildPrompt`). It may only reorder/select from the 40 candidates the app sends and returns at most 15 | Worker |
| **Connection explanation** (online only) | For the first three results, Gemini must explain the provision's rule, connect a named fact from the concern to a specific requirement in the article, and identify a condition or missing fact. The article text is sent up to 2,000 characters per candidate. | Worker |
| Verification | `OnlineRetrievalService._buildResponse` re-reads every returned article from the local corpus; unknown ids are dropped. Online scores are rank-derived (96, 91, 86...), not similarities | on device |
| Fallback | `OnlineRetrievalService.matchConcern` catches every proxy failure and returns the local ranking with `RetrievalMode.onDeviceFallback` | on device |

Modes: no `CATALYST_API_URL` -> `RetrievalMode.onDevice` (local only). With a URL ->
`online` (local retrieval, Gemini rerank) or `onDeviceFallback`.
The Gemini reranker can never add recall: if the right article is not in the 40
local candidates, it cannot be returned online either.

Online mode sends the concern and candidate provision text to the configured
proxy and Google Gemini. The home screen discloses this before search and warns
users not to enter names or contact details. Free-tier requests may be used by
Google to improve its models. On-device and fallback explanations explicitly
state that similarity alone does not establish a legal connection.

(The top-level README describes the e5 encoder used by the code.)

## 2. Online-to-offline fallback: verified

`test/online_retrieval_service_test.dart` (12 tests, passing) covers HTTP error,
401, timeout, no connection, malformed/empty/oversized responses and the no-URL
default. In all failure cases the user gets the on-device ranking and the mode
label `onDeviceFallback`. Follow-up answers (`followup_service.dart`) return `null`
on any failure and fall back to the on-device answer.

## 3. Cause of the Gemini quota errors

Verified:

1. **The live Worker currently rejects the app's token.** `node backend/diagnose.mjs proxy`
   returns `401 unauthorized` with the `CATALYST_API_TOKEN` in `env.json`. A build
   with that file never reaches Gemini and silently shows `onDeviceFallback`.
   Fix: `npx wrangler secret put APP_TOKEN` with the value in `env.json` (or update
   `env.json`), and rebuild.
2. **Worker request amplification** (`backend/worker.test.mjs`, mocked Gemini):
   - One search while every model is over quota = 3 Gemini calls (one per model in
     `GEMINI_MODEL`), each failing with 429.
   - One follow-up with `FOLLOWUP_SEARCH=true` = up to 4 calls (a grounded search call
     first, then each model). Grounded search has its own, smaller quota.
   - Unparseable output also moves on to the next model, so a bad reply costs more calls.
   - There is no caching, throttling or `retryDelay` handling, so a retry or a busy
     session burns the per-minute and per-day request quotas quickly.
3. Gemini limits are per project and per model (RPM, TPM, RPD; the daily quota resets at
   midnight Pacific). Free-tier values change; check AI Studio. All three model ids in
   `wrangler.toml` exist in the current model list.
4. Before this change the Worker logged Google's error but returned only
   `{"error":"upstream error"}`, so the real quota type was invisible to the app.
   The 502 body now includes `attempts: [{model, status, code, quota:{id,metric}, retryDelay}]`
   (no secrets or user text).

Not verified (no Gemini key available in this environment): the exact quota id behind
the 429s. Run, with the same key the Worker uses:

```
$env:GEMINI_API_KEY = '<key>'; node backend/diagnose.mjs direct
```

Reading the result: a `quotaId` containing `PerMinute` means a rate (RPM/TPM) problem;
`PerDay` means the daily free quota is exhausted (wait for reset or enable billing);
`limit: 0` or a missing quota for a model means that model has no free tier for this key,
so remove it from `GEMINI_MODEL`. Then redeploy (`cd backend; npx wrangler deploy`) and run
`node backend/diagnose.mjs proxy` to see per-model attempts from the live Worker.

Recommended settings while on the free tier: `FOLLOWUP_SEARCH = "false"` and one or two
models in `GEMINI_MODEL`.

## 4. Reproducible baselines

Environment note: on Windows with a space in the user profile path, `flutter test`
fails with "Building native assets failed: 'C:\Users\john' is not recognized". Work
around it with space-free junctions:

```
cmd /c mklink /J C:\fsdk "<flutter sdk dir>"
cmd /c mklink /J C:\pcache "<pub cache dir>"
$env:PUB_CACHE='C:\pcache'; $env:Path='C:\fsdk\bin;'+$env:Path; flutter pub get --offline
```

### Offline / on-device mode (no network)

```
flutter test tool/offline_eval/offline_eval_test.dart --dart-define=MODE=dump
.venv\Scripts\python tool\offline_eval\embed_ids.py
flutter test tool/offline_eval/offline_eval_test.dart --dart-define=MODE=eval
.venv\Scripts\python tool\offline_eval\summarize.py tool\offline_eval\out\report.json
```

Result on 2026-11-03 (hybrid strategy, 12 labeled queries, production e5 encoder):

| Input | Top-1 | Hit@3 | P@3 | Relevant article anywhere in candidates |
| --- | ---: | ---: | ---: | ---: |
| Original query | 1/12 | 2/12 | 0.056 | 4/12 |
| ML Kit-translated query (recorded) | 0/12 | 1/12 | 0.028 | 4/12 |

Off-topic probes: 4 of 6 return nothing; `asdf qwer zxcv uiop` returns 5 and
"Anong oras magbubukas ang mall bukas?" returns 4 (the gate is coarse).
The set is small and labels are the project's own reviewed ids, so treat it as a
regression baseline, not a quality claim. Note the ceiling: only 4/12 queries even
have a relevant article among the candidates, which also caps what online reranking
can achieve.

### Training-query index update

The app packages precomputed embeddings and article labels for 182
domain-tagged Training Dataset entries. It does not package the source
narratives. At search time, up to three same-domain neighbors above cosine 0.90
can contribute a supplemental ranking signal; E5 article similarity and BM25
remain in the final score.

On the 12-query paired regression set in `tool/offline_eval/cases.json`, the
previous configuration (0.79 cosine gate, no training-query index) produced
Top-3 hits for 2/12 original queries and 1/12 recorded translations (MRR@15
0.1271 and 0.0833). The updated configuration (0.80 gate plus the index)
produced 4/12 and 3/12 Top-3 hits (MRR@15 0.2049 and 0.1875); relevant
articles appeared in the first 15 for 5/12 queries in both modes. All six
off-topic probes now return no provisions, compared with two false-positive
probes before. This small regression set is not an independent thesis-level
test set or a legal-accuracy claim. The fine-tuned MiniLM candidate remains
experimental and is not used by the app.

Rebuild the index after changing the Training Dataset or E5 assets:

```
.venv\Scripts\python tool\retrieval_lab\export_training_query_index.py
```

### Online mode (Gemini rerank)

Same queries, through the Worker:

1. `node --test backend/worker.test.mjs` - Worker logic with mocked Gemini (no key needed; passing).
2. `node backend/diagnose.mjs direct` - per-model status, tokens, ranked output (needs key).
3. `node backend/diagnose.mjs proxy` - the deployed Worker end to end (needs matching token).

Online ranking quality has not been measured; it requires item 2 or 3 to succeed, then
running `cases.json` through the app with `--dart-define-from-file=env.json`.

### Regression checks

`flutter test`: 124 pass; `test/widget_test.dart` fails to compile (stale template
referencing a removed `MyApp`) and predates this work.
