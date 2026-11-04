# CATALYST technology inventory

Date: 2026-11-04. Versions come from `pubspec.lock`, `wrangler.toml`, the `.venv` and
the code. Status: **Working** = implemented and tested here; **Working (untested on
device)** = implemented, no physical-device evidence; **Broken**; **Legacy** = not in the
active path.

## 1. Summary by component

| Component | Technology | Status |
| --- | --- | --- |
| Mobile app shell and UI | Flutter 3.47.6 / Dart ^3.13.5, Material 3 | Working |
| Dense retrieval (encoder) | multilingual-e5-small exported to ONNX (FP32, 384-dim), run by `flutter_onnxruntime` 1.9.0 | Working (untested on device) |
| Tokenization | `dart_sentencepiece_tokenizer` 1.4.1, `e5_tokenizer.json`, max 128 tokens | Working |
| Vector search | Brute-force dot product over chunk embeddings (`chunk_embeddings_e5.f32`, ~6.7 MB) in Dart | Working |
| Lexical search | Custom BM25 (k1 1.2, b 0.75) in `lexical_index.dart` | Working |
| Fusion and scoring | Reciprocal rank fusion (k 20, pool 50) + blend 0.85 dense / 0.15 BM25, cosine gate 0.79 | Working, weak accuracy |
| Query understanding | Rule/glossary analysis (`query_analysis.dart`, `legal_query_preprocessor.dart`) | Working |
| Language ID and translation | `google_mlkit_language_id` 0.15.1, `google_mlkit_translation` 0.15.1 (on-device ML Kit) | Working (untested on device); no measured benefit |
| Explanations | Template builder in Dart (`explanation_builder.dart`, `explanation_language.dart`) | Working |
| Conversation and follow-ups | `case_conversation.dart`, `followup_service.dart`, `jurisprudence_service.dart` | Working |
| Online rerank proxy | Cloudflare Workers (JS ES module, `wrangler`), Gemini REST `generateContent` | Deployed, **Broken** (401 on token; quota cause unconfirmed) |
| LLM | Gemini: `gemini-3.5-flash-lite`, `gemini-3.6-flash`, `gemini-3.8-flash` (fallback in that order) | Unconfirmed (no key tested) |
| Local data | Bundled JSON assets (articles, jurisprudence, chunk owners); no database | Working |
| Persistence | None: History screen shows hard-coded mock entries (`lib/data/mock_history_entries.dart`); no storage package in `pubspec.yaml`, so real searches and bookmarks are not saved | **Not implemented** |
| Data pipeline (Python) | Python 3.14.6 venv; numpy 2.5.4, onnx 1.23.2, onnxruntime 1.31.0, pypdf 6.21.2; scripts also import pandas, sentence_transformers, Flask | Working for tools; partly Legacy |
| Evaluation | `flutter_test` harness + Python `onnxruntime` embedder (`tool/offline_eval`) | Working |
| Tests | `flutter_test`, `integration_test`, Node `node:test` | 124 Flutter + 5 Worker pass; 1 stale test fails |

## 2. Component detail

### 2.1 Mobile app (Flutter)
- **Tech:** Flutter 3.47.6, Dart, Material 3. App id `com.example.catol`
  (placeholder, change before release). Android min/target SDK come from Flutter defaults;
  iOS deployment target 15.5 (ML Kit requirement).
- **Screens:** Landing, Home, Processing, Match Results, Law Details, History, Chat
  (`xai_chatbot_screen`), About.
- **Capabilities:** search by narrative, top 3 plus other candidates, mode banner
  (on-device / online / fallback), per-article explanations in 3 languages, bookmark toggle
  (session only).
- **Limits:** debug APK ~750 MB; no device latency or memory data; History screen is
  mock data and bookmarks are not persisted.

### 2.2 On-device retrieval engine
- **Tech:** ONNX Runtime via `flutter_onnxruntime`; encoder `catalyst_encoder_e5.onnx`
  (~470 MB FP32); pooling and L2 normalization are inside the ONNX graph; e5 `query: `
  prefix; chunk-level article scoring (best chunk per article); 2,700 articles.
- **Capabilities:** fully offline multilingual semantic and keyword retrieval, ties kept
  stable, embedding and index validation at load, lazy model load.
- **Status/limits:** correct and deterministic, but accuracy is low (Top-1 1/12, Hit@3 2/12,
  candidate recall 4/12). The 0.79 cosine gate is coarse. CPU only; FP32 is large and not
  quantized.

### 2.3 Language preprocessing
- **Tech:** Google ML Kit (proprietary runtime, MIT Flutter bridges); keyword glossary for
  Filipino-to-English legal terms.
- **Capabilities:** language ID, Tagalog-to-English translation after a ~30 MB per language
  model download (Wi-Fi), glossary expansion; falls back to the original query on failure.
- **Limits:** translation unavailable on fresh offline installs; measured translated
  queries were not better than originals.

### 2.4 Online rerank (Worker + Gemini)
- **Tech:** Cloudflare Workers free plan, `worker.js` (ES module), secrets `GEMINI_API_KEY`
  and `APP_TOKEN`, vars `GEMINI_MODEL`, `USE_SEARCH=false`, `FOLLOWUP_SEARCH=true`.
  Client: `dart:io` `HttpClient` with 45 s (search) and 40 s (follow-up) timeouts, 256 KB
  response cap.
- **Capabilities:** rerank up to 40 candidates to at most 15, bilingual bullet
  explanations, grounded follow-up answers citing only supplied cases, optional Google
  Search grounding, model fallback chain, per-model error diagnostics (new).
- **Limits:** token mismatch (401) on the deployed Worker; up to 3 Gemini calls per search
  and 4 per follow-up; no caching; narratives leave the device; token embedded in APK.

### 2.5 Data and corpus
- **Tech:** JSON assets: `legal_articles.json` (Civil 2,270 / Family 257 / Consumer 173),
  `jurisprudence.json` (44 cases), `chunk_owners_e5.json`. Source material in `DATA/`
  (52 PDFs, 4 .xlsx, 1 .pkl).
- **Pipeline:** `pypdf` text extraction (`tool/jurisprudence`), corpus export scripts,
  `generate_corpus_embeddings.py` / `tool/retrieval_lab/build_pooled_e5.py` for embeddings.
- **Limits:** three laws only, 44 cases, self-reviewed evaluation labels.

### 2.6 Python tooling
- **Tech:** `.venv` Python 3.14.6; `sentence_transformers` and `pandas` are used by scripts
  but are not installed in the current venv, so those scripts cannot run as-is.
- **Status:** `export_mobile_model.py`, `embed_ids.py`, `summarize.py` work with the
  installed packages. `temporary_api.py` (Flask) is a legacy reference baseline.
  There is no `requirements.txt`.

### 2.7 Testing and tooling
- **Tech:** `flutter_test`, `integration_test`, `flutter_lints` 6, Node built-in test
  runner, `wrangler` via `npx`.
- **Coverage:** retrieval, online fallback (HTTP, 401, timeout, malformed, oversize),
  preprocessing, explanations, navigation, history, chat, Worker logic with mocked Gemini.
- **Gaps:** no real-Gemini or on-device automated test; stale `widget_test.dart`; Windows
  paths with spaces break `flutter test`.

## 3. Key risks by technology
1. ONNX FP32 encoder (size and speed) and low retrieval accuracy.
2. Gemini free-tier quota plus the Worker's multi-call fallback design.
3. ML Kit dependency (proprietary, model downloads, unproven benefit).
4. Missing Python dependency manifest (`requirements.txt`) and Python 3.14 compatibility
   of ML libraries (reinstall may need an older Python).
5. No persistence layer (history is mock data) and the placeholder app id for release.
