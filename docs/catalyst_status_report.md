# CATALYST status report

Historical snapshot: the online article reranker described below has since
been removed from the app. Current article retrieval is on-device, and the
Worker source is restricted to XAI follow-up. See
[hybrid_retrieval.md](hybrid_retrieval.md) for updated limitations.

Date: 2026-11-04. Based on the code, assets, tests and runs in this repository (see
[hybrid_retrieval.md](hybrid_retrieval.md) for the retrieval diagnosis). Items marked
*unmeasured* have no evidence yet.

## 1. What CATALYST is

A Flutter mobile app (Android primary; iOS configured) that takes a person's legal concern
in English, Tagalog or Taglish and returns the most relevant Philippine statute articles,
with plain-language explanations and related Supreme Court decisions. It is an
information/research tool, not legal advice.

## 2. Current capabilities

| Area | State |
| --- | --- |
| Corpus | 2,700 articles: Civil Code 2,270, Family Code 257, Consumer Act 173 (`assets/data/legal_articles.json`) |
| Jurisprudence | 44 Supreme Court cases (`assets/data/jurisprudence.json`), searched on device and linked to the retrieved articles |
| Offline retrieval | multilingual-e5-small (ONNX, FP32, ~470 MB) with chunk-level embeddings + BM25, rank fusion, blended score, cosine gate. Works with no network |
| Language handling | Glossary-based Filipino-to-English keyword expansion; ML Kit language ID and Tagalog translation (models downloaded on demand) |
| Online mode | Optional Cloudflare Worker proxy calls Gemini to rerank the 40 local candidates; the key never ships in the app. Every returned article is re-verified against the local corpus |
| Fallback | Any online failure returns the on-device ranking, labelled as fallback (tested) |
| Conversation | Follow-up questions, new-fact handling, clarifying question for non-legal input, grounded follow-up answers citing only supplied cases |
| Explanations | Per-article plain-language bullets in English, Tagalog, Taglish, with language toggle and reminders |
| UI | Landing, Home, Processing, Results (top 3 + others, mode banner), Law Details, History/bookmarks, Chat, About |
| Quality gates | 124 passing Flutter tests plus 5 Worker tests (mocked Gemini) |

## 3. Retrieval quality (the central issue)

- Measured on 12 labelled queries (3 English, 6 Tagalog, 3 Taglish):
  Top-1 1/12, Hit@3 2/12, P@3 0.056. A relevant article is anywhere in the 40 candidates
  for only 4/12 queries.
- Recorded ML Kit translation did not help (Hit@3 1/12, Top-1 0/12).
- Off-topic gating is coarse: random text and an unrelated Filipino question still
  returned 4-5 articles.
- Online reranking can only reorder those candidates, so it cannot fix a recall of 4/12.
- Caveats: only 12 labels, self-reviewed, one reviewer; it is a regression baseline, not
  a statistically meaningful accuracy number. Online ranking quality is *unmeasured*.

## 4. Problems and struggles

**Critical**
1. **Low retrieval recall** (above). It dominates user-visible quality in both modes.
2. **Online mode is not working today.** The live Worker returns 401 for the app's token,
   so builds with `env.json` silently run in fallback. Separately, Gemini 429 quota errors
   were reported but their exact type (per-minute, per-day, or no free tier) is
   unconfirmed because no Gemini key was available.
3. **Quota amplification in the Worker:** up to 3 Gemini calls per search and 4 per
   follow-up, no caching or retry-delay handling. Not yet mitigated (only made diagnosable).
4. **Silent fallback:** users see only a mode label; there is no in-app or telemetry signal
   explaining why online failed.

**Significant**
5. **App size:** debug APK ~750 MB, dominated by the 470 MB FP32 e5 ONNX encoder. The
   stale MiniLM model files were never packaged and have since been deleted from the repo.
   Release size, install friction and startup/memory on low-end phones are *unmeasured*.
6. **No device measurements:** latency, memory and translation speed on a physical device
   have never been recorded.
7. **Small, narrow data:** 44 cases and three laws. Other laws (Labor Code, Revised
   Penal Code, etc.) are out of scope, so many real concerns have no valid answer.
8. **Translation dependency:** ML Kit models (~60 MB) must be downloaded; fresh offline
   installs get no translation, and it did not improve measured results.
9. **Privacy:** in online mode narratives go to Gemini; free-tier requests may be used
   by Google for training. The app token is embedded in the APK, so it only deters
   casual abuse.

**Housekeeping**
10. No git commit exists yet (everything is untracked). `env.json` (holds the app token)
    is already git-ignored; confirm `.venv/` is too before the first commit.
11. *(Resolved in cleanup)* the stale `test/widget_test.dart` was rewritten as a
    `CatalystApp` smoke test and `lib/COPYmain.dart` was deleted.
12. *(Resolved in cleanup)* README now describes the e5 encoder and chunk embeddings.
13. On Windows, a space in the user path breaks `flutter test` (native assets hook);
    needs junction workaround documented in `hybrid_retrieval.md`.
14. Python tooling (`scripts/`, `tool/`, Flask `temporary_api.py`) is partly legacy
    reference code with no single documented entry point.

## 5. What is solid

- Clear separation: on-device retrieval, optional online rerank, strict corpus verification.
- Fallback paths are well tested (timeouts, bad JSON, oversize, 401, offline).
- Answers are grounded: no article or case can appear unless it exists in the bundled data.
- Reproducible offline evaluation harness exists (`tool/offline_eval`).

## 6. Recommended priorities before further development

1. Fix the Worker token, run `node backend/diagnose.mjs direct`, set
   `FOLLOWUP_SEARCH=false` and trim `GEMINI_MODEL`; add per-request caching/backoff.
2. Grow the labelled evaluation set (target 100+, mixed languages, second reviewer) and
   make the baseline a CI/regression gate; add an online column.
3. Improve recall: inspect the 8 queries with no relevant candidate (chunking, query
   expansion, larger candidate pool, tuning the 0.79 cosine gate and 0.15 BM25 weight).
4. Reduce size: quantize the encoder (INT8), remove stale model files, measure on device.
5. Housekeeping: make the first commit (`.venv/` is now git-ignored).
