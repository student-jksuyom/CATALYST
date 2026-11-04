# Hybrid retrieval pipeline: diagnosis and baseline

Diagnosis date: 2026-11-03. "Verified" means observed by running code or the live
endpoint; "not verified" means it needs a Gemini key or a device.

## 1. Who does what

| Stage | Component | Where |
| --- | --- | --- |
| Query analysis, glossary | `QueryAnalysis`, `LegalQueryPreprocessor` | on device |
| **Retrieval** (candidate generation) | `LocalSemanticRetrievalService._matchHybrid` in `lib/services/catalyst_local_retrieval_service.dart`: multilingual-e5-small ONNX dense chunk embeddings + BM25 (`lexical_index.dart`), reciprocal-rank fusion, blended score `0.85 * dense + 0.15 * BM25`, cosine gate 0.79 | on device |
| **Reranking** (online only) | Gemini, called by the Cloudflare Worker `backend/worker.js` (`buildPrompt`). It may only reorder/select from the 40 candidates the app sends and returns at most 15 | Worker |
| Verification | `OnlineRetrievalService._buildResponse` re-reads every returned article from the local corpus; unknown ids are dropped. Online scores are rank-derived (96, 91, 86...), not similarities | on device |
| Fallback | `OnlineRetrievalService.matchConcern` catches every proxy failure and returns the local ranking with `RetrievalMode.onDeviceFallback` | on device |

Modes: no `CATALYST_API_URL` -> `RetrievalMode.onDevice` (local only). With a URL ->
`online` (local retrieval, Gemini rerank) or `onDeviceFallback`.
The Gemini reranker can never add recall: if the right article is not in the 40
local candidates, it cannot be returned online either.

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
