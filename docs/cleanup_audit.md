# CATALYST cleanup audit (Phase 1, read-only)

Date: 2026-11-04. Nothing was deleted, moved, renamed or edited. This file is the only
addition. Classes: **R** Required - Keep, **S** Confirmed Safe to Remove, **O** Likely
Obsolete - Needs Review, **U** Uncertain - Keep for Now, **G** Generated/Local Artifact -
Ignore/Exclude Instead.

## 0. Headline findings

1. **The APK already excludes the stale model files.** I opened the existing
   `app-debug.apk` (built 2026-10-26, after the last `pubspec.yaml` edit). Its
   `flutter_assets` hold only six data/model files: `catalyst_encoder_e5.onnx`,
   `e5_tokenizer.json`, `chunk_embeddings_e5.f32`, `chunk_owners_e5.json`,
   `legal_articles.json`, `jurisprudence.json`. `catalyst_encoder.onnx`, `tokenizer.json`
   and `article_embeddings.f32` are **not** in the APK. Deleting them reduces repository
   size only, never APK size.
2. **The APK is dominated by things cleanup cannot remove:** the E5 encoder, 3 CPU
   architectures of `libflutter`/`libonnxruntime`/`libtranslate_jni`, and
   a Khronos validation layer (debug builds only).
3. **Git is in a bad state.** There are zero commits and zero tracked files, yet `.git` is
   2.4 GB: 1.05 GiB of loose objects plus **1.29 GiB of `tmp_obj_*` garbage** from an
   interrupted `git add`. `.venv/`, `DATA/`, `tool/retrieval_lab/e5/model.onnx` (448 MB)
   and the model assets are **not git-ignored**, so a normal first commit would include
   them.
4. **Dead Dart code is minimal.** Only `lib/COPYmain.dart` is dead. A scan of public
   symbols in `lib/` found nothing unreferenced outside its own file that is also unused
   inside it. The analyzer reports exactly 3 issues (see section 5).
5. All 12 pubspec dependency entries resolve to real use except `cupertino_icons`.

## 1. Item audit

| Item | Type | Current purpose | Evidence | Risk if removed | Class / Recommendation |
| --- | --- | --- | --- | --- | --- |
| `lib/COPYmain.dart` | Dart | Untouched Flutter counter template copy | Zero imports from lib/test/integration/tool; defines its own `MyApp`; causes the only `file_names` lint; README already calls it "pre-existing" | None | **S** - delete. Repo clutter and lint only |
| `lib/*_preview.dart` (about, history, match_results, xai_chatbot) | Dart | Standalone `main()` entry points to run one screen (`flutter run -t`) | No imports anywhere; not referenced by README or scripts; each imports mock data | Lose a dev shortcut | **O** - ask whether you use them; not packaged beyond tree-shaken code |
| `lib/data/mock_history_entries.dart` | Dart | Hard-coded History screen content | Imported by `history_screen.dart:3,28,35` (runtime default) and `history_screen_test.dart` | **History screen breaks** | **R** - it is live behaviour, not clutter (real history persistence does not exist yet) |
| `lib/data/mock_law_match_results.dart` | Dart | Default `results` for `MatchResultsScreen` | `match_results_screen.dart:93`; used by previews and `xai_chatbot_screen_test` | Screen constructor/tests break | **R** |
| `lib/data/mock_xai_chat_content.dart` | Dart | Chat prompt/FAQ/response text | `xai_chatbot_screen.dart:122,242,573,577`; tests | Chat UI breaks | **R** |
| `test/widget_test.dart` | Test | Flutter starter test | Instantiates removed `MyApp` (analyzer error, `widget_test.dart:16`) | Lose nothing real | **O** - do not just delete; replace with a smoke test pumping `CatalystApp` or remove after approval. Neither changes APK |
| `tool/retrieval_lab/dump_ids_test.dart` unused import `lexical_index.dart` | Dart | Lab tokenization dump | Analyzer warning `unused_import` line 7 | None | **S** - remove the one import line |
| `assets/models/catalyst_encoder_e5.onnx` (448.5 MB) | Asset | Production encoder | pubspec; `catalyst_local_retrieval_service.dart:46`; in APK; produced by `build_pooled_e5.py` | App cannot search | **R** |
| `assets/models/e5_tokenizer.json` (16.3 MB) | Asset | Production tokenizer | pubspec; in APK; tests | App cannot search | **R** |
| `assets/data/chunk_embeddings_e5.f32`, `chunk_owners_e5.json`, `legal_articles.json`, `jurisprudence.json` | Asset | Retrieval index, corpus, case dataset | pubspec; loaded in `catalyst_local_retrieval_service.dart` / `jurisprudence_service.dart`; in APK | App cannot search | **R** |
| `assets/images/*` (14 listed) and 4 font files | Asset | UI | Each referenced in `lib` or `pubspec` (fonts: Fredoka 4, Inter 58, Montserrat 10 uses) | Broken UI | **R** |
| `assets/images/details_bookmark_states.png` (5 KB) | Asset | Declared in pubspec | **Zero references** in `lib` | Trivial | **O** - possible spare design sheet; 5 KB, low value either way |
| `assets/models/catalyst_encoder.onnx` (448.5 MB) | Asset (MiniLM) | Old encoder | **Not in pubspec, not in APK.** Referenced by `scripts/export_mobile_model.py:32` (output), `tool/retrieval_lab/embed.py:14` (minilm lab arm), README tables | Lab "minilm" arm and old-vs-new comparison can't re-run; README stale | **O** - regenerable by script only if the cached SentenceTransformer exists. Saves ~449 MB repo, 0 APK. Do not delete before confirming you will not rerun the minilm comparison |
| `assets/models/tokenizer.json` (8.7 MB) | Asset (MiniLM) | Old tokenizer | Not in pubspec/APK. Referenced by `tool/retrieval_lab/dump_ids_test.dart:20` (MODEL=minilm), `lib` regex hit is only the e5 name | Same as above | **O**, same decision as the MiniLM model |
| `assets/data/article_embeddings.f32` (4 MB) | Asset (MiniLM) | Old 2,700x384 matrix | Not in pubspec/APK. Written by `export_mobile_corpus.py:54`; README row | Reproducible from the pickle by the script | **O** |
| `tool/retrieval_lab/e5/model.onnx` (448.5 MB) + `tokenizer.json` (16.3 MB) | Model | Raw E5 export | **Source input** of `build_pooled_e5.py:SRC`; `dump_ids_test.dart:20`; `embed.py` | Cannot regenerate production encoder or index | **R for reproducibility** but **G**: not git-ignored; add to `.gitignore` or document a download step |
| `tool/retrieval_lab/out/*_minilm.*` (ids, chunks, passages, queries ~14 MB) | Generated | MiniLM lab inputs | `lab.py` loads both `e5` and `minilm` unconditionally (`for m in ("e5","minilm")`); removing them breaks `lab.py` | `lab.py` fails | **U** - keep until you decide to retire the MiniLM comparison, then drop with `lab.py` edit |
| `tool/retrieval_lab/out/*_e5.*`, `chunk_owner.json`, `analyses.json` | Generated | Lab outputs | `lab.py`, `embed.py` | Lab fails | **U**/**G** |
| `tool/retrieval_lab/*.py`, `extra_queries.json` | Scripts | Retrieval experiments, E5 pooling | `build_pooled_e5.py` creates a shipped asset | Lose reproducibility | **R** (`build_pooled_e5.py`), **U** (lab) |
| `tool/offline_eval/out/report_minilm_old.json`, `report_before_rerank.json`, `lex_debug.txt`, `regkeys.txt` | Output | Old experiment outputs | No code reads them (only `report.json`/`ids.json`/`vectors.json` are read by the harness/`summarize.py`) | Lose historical comparison numbers | **O** (0.06 MB, clutter only) |
| `tool/offline_eval/out/report.json, offtopic.json, demo.json, ids.json, vectors.json` | Generated | Current baseline run output (regenerated each run) | Written/read by `offline_eval_test.dart`, `embed_ids.py` | Re-run needed | **G** - ignore, keep report.json as a recorded baseline if wanted |
| `tool/offline_eval/*` (test, cases.json, embed_ids.py, summarize.py) | Tooling | Reproducible baseline | Ran successfully this week | Lose baseline | **R** |
| `tool/jurisprudence/*.py` | Scripts | Builds `jurisprudence.json` from PDFs | `build_cases.py:16` writes shipped asset | Cannot regenerate dataset | **R** |
| `tool/jurisprudence/out/raw/*.txt` | Generated | Text extracted from `DATA/Sources/*.pdf` | Input of `build_cases.py` | Re-extract needed | **G** - regenerable from PDFs; keep or ignore |
| `scripts/export_mobile_corpus.py` | Script | Writes `legal_articles.json` (+ old `article_embeddings.f32`) | Output is a shipped asset | Cannot regenerate corpus JSON | **R** (note: still writes the MiniLM matrix, see recommendations) |
| `scripts/export_mobile_model.py` + `mobile_retrieval_validation.json` | Script/report | Builds the **old MiniLM** `catalyst_encoder.onnx`; README cites the JSON | Output not packaged; `export` uses the MiniLM checkpoint | Lose MiniLM re-export | **O** |
| `scripts/generate_corpus_embeddings.py` | Script | Builds `MasterCorpus_Embedded.pkl/.xlsx` with MiniLM | Pickle is the input of both export scripts and `query_legal_articles.py` | Corpus pipeline breaks | **U** (MiniLM-era, but the pickle chain still feeds `legal_articles.json` metadata) |
| `scripts/query_legal_articles.py`, `scripts/temporary_api.py` (Flask) | Scripts | MiniLM CLI search and demo API | README calls them "reference baselines"; no app/test use | Lose baseline reference | **O** |
| `scripts/validate_datasets.py` | Script | Read-only checks of the xlsx datasets | Not referenced elsewhere | Lose a validator | **U** |
| `DATA/Corpus/MasterCorpus.xlsx` | Data | Source corpus | Input of `generate_corpus_embeddings.py` | Cannot rebuild corpus | **R** |
| `DATA/Corpus/MasterCorpus_Embedded.pkl` (6.9 MB) | Data | MiniLM-embedded corpus | Input of `export_mobile_corpus.py`, `export_mobile_model.py`, `query_legal_articles.py`, `temporary_api.py` | Corpus export breaks | **U** (only `Law/Article/Title/Chapter Title/Article Text` are consumed by the app JSON; embeddings column is MiniLM) |
| `DATA/Corpus/MasterCorpus_Embedded.xlsx` (10.5 MB) | Data | Excel copy of the embedded pickle | Written by `generate_corpus_embeddings.py:69`; **no reader found** | Regenerable | **O** - largest pure duplicate in `DATA` |
| `DATA/Datasets/*.xlsx` | Data | Training/testing queries | `validate_datasets.py`; README "labeled testing dataset" | Lose eval source | **R** |
| `DATA/Sources/*.pdf` (52) | Data | Jurisprudence source | Input of `extract_text.py` | Cannot rebuild cases | **R** |
| `backend/worker.js`, `wrangler.toml` | Worker | Gemini proxy | Deployed; tests | Online mode gone | **R** |
| `backend/worker.test.mjs`, `diagnose.mjs`, `load-worker.mjs` | Worker tooling | Mocked tests, quota diagnosis | Added this month; tests pass | Lose diagnostics | **R** |
| Worker vars `USE_SEARCH`, `FOLLOWUP_SEARCH`, `GEMINI_MODEL` | Config | All read in `worker.js` | Used | - | **R** (none unused) |
| `backend/.wrangler/` | Cache | Wrangler account cache | Ignored already | - | **G** (already ignored) |
| `docs/*.md`, `README.md` | Docs | Documentation | See section 7 | - | README needs update, not deletion |
| `build/` (5.4 GB), `.dart_tool/` (0.6 GB) | Artifact | Flutter build/cache | Already git-ignored | Rebuild time | **G** - safe to `flutter clean` locally; no repo effect |
| `.venv/` (135 MB) | Local env | Python venv | **Not ignored**; missing `sentence_transformers`/`pandas`/`torch` so MiniLM scripts cannot run here anyway | Reinstall | **G** - add to `.gitignore`; never commit |
| `.flutter-plugins-dependencies`, `.idea/`, `catol.iml`, `env.json` | Local | IDE/secrets | Already ignored (`env.json` also contains a real token) | - | **G** (ignored; keep ignored) |
| `.git/objects/*/tmp_obj_*` (1.29 GiB) | Git garbage | Interrupted `git add` | `git count-objects -vH` reports 7 garbage files | None; unreferenced | **G** - removable by git itself (`git gc` / delete tmp files) after you approve; huge local disk win |

## 2. Files actually packaged into the app (from the APK)

- Data/model: `legal_articles.json` (1.4 MB), `jurisprudence.json` (0.19 MB),
  `chunk_embeddings_e5.f32` (6.7 MB), `chunk_owners_e5.json` (20 KB),
  `catalyst_encoder_e5.onnx` (470 MB raw, 281.5 MB compressed), `e5_tokenizer.json`
  (17 MB raw, 4.1 MB compressed).
- 14 PNGs and 4 TTFs (`Fredoka-SemiBold/Bold`, `Inter-SemiBold`, `Montserrat-SemiBold`,
  about 0.9 MB). `details_bookmark_states.png` is declared but unreferenced.
- Native libraries per ABI (arm64-v8a, armeabi-v7a, x86_64): `libflutter`,
  `libonnxruntime`, `libtranslate_jni` (ML Kit), plus debug-only validation layer.

## 3. Large contributors to APK size (debug APK ~750 MB)

| Contributor | Uncompressed | Removable by cleanup? |
| --- | ---: | --- |
| `catalyst_encoder_e5.onnx` | 448.5 MB (281.5 MB zipped) | No (required). Only INT8 quantization would shrink it, and that is a behaviour change |
| `e5_tokenizer.json` | 16.3 MB | No (required) |
| `libflutter.so` x3 ABIs | ~107 MB | Not by deletion; release `--split-per-abi` would cut it |
| `libonnxruntime.so` x3 | ~80 MB | Same |
| `libtranslate_jni.so` x3 (ML Kit) | ~43 MB | Only if ML Kit were dropped (design decision) |
| `kernel_blob.bin` (debug) | 51.5 MB | Release build removes it |
| Khronos validation layer | 14.5 MB | Debug only |
| `chunk_embeddings_e5.f32`, `legal_articles.json`, others | ~8.5 MB | No |

The real levers for APK size are build choices (release mode, `--split-per-abi`, shrinking
the encoder), not file deletion. Those are outside this cleanup's scope and I have not
changed them.

## 4. Repository-clutter-only items (no APK effect)

`COPYmain.dart`; MiniLM files (`catalyst_encoder.onnx`, `tokenizer.json`,
`article_embeddings.f32`); `MasterCorpus_Embedded.xlsx`; old `tool/offline_eval/out`
reports; `tool/retrieval_lab/out/*minilm*`; `mobile_retrieval_validation.json`;
Flask/CLI baseline scripts; `.git` temp garbage; ~0.4 MB `vectors.json`.
Approximate potential repository saving: ~461 MB (MiniLM assets) + ~15 MB (lab minilm
outputs) + 10.5 MB (`MasterCorpus_Embedded.xlsx`) + 1.29 GiB git garbage.

## 5. Unused or stale code

- Analyzer (`flutter analyze --no-pub`) gives 3 issues: `COPYmain.dart` file-name lint;
  `widget_test.dart` `MyApp` error; unused import in `dump_ids_test.dart`.
- Private unused members: the analyzer found none. Public-symbol scan: no dead classes
  or functions in `lib/` (14 symbols have no outside reference but each is used inside
  its own file: `ChatMessage`, `CaseHit`, `OnlineFollowUpAnswerer`, `stemToken`, etc.).
  They could be made private, which is a style change, not cleanup.
- Hand-written preview entry points: see item above.

## 6. Dependencies

Dart (`pubspec.yaml`):

| Package | Evidence | Class |
| --- | --- | --- |
| `flutter_onnxruntime` | 1 import (retrieval) | R |
| `dart_sentencepiece_tokenizer` | `local_tokenizer.dart`, lab test | R |
| `google_mlkit_language_id`, `google_mlkit_translation` | `legal_query_preprocessor.dart` | R |
| `cupertino_icons` | **No `Cupertino` reference in `lib/`** | **O** - likely removable (tiny; the Flutter template default). Verify no `CupertinoIcons` use in tests/iOS before removing |
| `flutter_lints`, `flutter_test`, `integration_test` | analysis_options, 21 test imports, 1 integration test | R |

Python: `.venv` has `numpy`, `onnx`, `onnxruntime`, `pypdf`. Active, installed need:
`numpy`, `onnx`, `onnxruntime` (offline eval, E5 pooling), `pypdf` (jurisprudence).
`pandas`, `torch`, `sentence_transformers`, `flask` are imported only by MiniLM-era
scripts (`export_*`, `generate_corpus_embeddings`, `query_legal_articles`,
`temporary_api`) and are **not installed**; they are removable from any future
`requirements.txt` only if those scripts are retired. There is no requirements file, so
nothing to remove today.

Worker: no `package.json`/npm dependencies; all env vars used.

## 7. Stale documentation

- `README.md` "Packaged retrieval assets" table lists the MiniLM encoder, `tokenizer.json`
  and `article_embeddings.f32` as packaged (false) and says ~484.9 MB; the opening
  section describes MiniLM and 2,700 article vectors, but code uses E5 chunk embeddings.
  Also claims 2,700-article dot-product search and that the Flask API is the baseline.
  Needs rewriting, not deletion.
- README says `widget_test.dart` failure is "unrelated"; true, but it is fixable.
- `docs/catalyst_status_report.md` item 5 says the MiniLM files "ship only if referenced";
  the APK check shows they do not ship. Item about history/bookmarks needs correcting
  to match `technology_inventory.md`.

## 8. Retain for reproducibility, testing or model generation

`DATA/` (corpus xlsx, datasets, PDFs), `tool/retrieval_lab/e5/` (source model, with
`.gitignore` or documented fetch), `tool/retrieval_lab/build_pooled_e5.py`,
`tool/jurisprudence/*.py`, `tool/offline_eval/{*.py,*.dart,cases.json}`,
`scripts/export_mobile_corpus.py`, all of `backend/`, all of `test/` and
`integration_test/`.

## 9. Risks and limitations of this audit

- Static analysis plus one APK inspection; I did not run the app or the Python scripts.
- The APK I inspected is from 2026-10-26; I confirmed `pubspec.yaml` is older, but did
  not rebuild.
- "Not referenced" was established by text search over `lib`, `test`, `integration_test`,
  `tool`, `scripts`, `backend`, docs and `pubspec.yaml`; Android/iOS native folders and
  build scripts were checked only for asset names via grep (none found), not read fully.
- `lab.py` and `export_mobile_model.py` need the MiniLM checkpoint/pickle; I could not
  verify that the cached SentenceTransformer exists, so MiniLM assets are classed **O**,
  not **S**.
- Whether you use the `*_preview.dart` files and the Flask/CLI baselines is a workflow
  question the code cannot answer.
- `.git` garbage and ignore changes affect only the local repo/first commit.

## 10. Proposed approval batches (for Phase 2)

| Batch | Items | Effect |
| --- | --- | --- |
| A (low risk) | Delete `lib/COPYmain.dart`; remove unused import in `dump_ids_test.dart` | Clutter, 1 lint + 1 warning fewer |
| B (ignore rules) | Add `.venv/`, `tool/retrieval_lab/e5/`, `tool/*/out/`, `DATA/Corpus/*_Embedded.*` (if desired) to `.gitignore`; clean `.git` tmp garbage and decide initial commit contents | Prevents committing ~1 GB; frees ~1.3 GiB locally |
| C (decision needed) | MiniLM assets, `report_minilm_old.json`, `*_minilm.*` lab outputs, `mobile_retrieval_validation.json`, `MasterCorpus_Embedded.xlsx` | ~490 MB repo, 0 APK |
| D (decision needed) | `widget_test.dart` (update to `CatalystApp` rather than delete), `cupertino_icons`, `details_bookmark_states.png`, `*_preview.dart` | Small; `cupertino_icons`/png would shave KBs of APK |
| E (docs) | Rewrite README asset table and architecture text; correct status report | Accuracy only |

Nothing will be changed until you approve specific batches or items.

## Phase 2 status

Batches A-E were executed as approved: COPYmain.dart, stale MiniLM assets, stale eval outputs, preview entry points, unused PNG and cupertino_icons removed; widget_test.dart rewritten; .gitignore and README updated. Items deliberately kept (MiniLM scripts, *_minilm lab outputs, MasterCorpus_Embedded.pkl, mobile_retrieval_validation.json) remain candidates awaiting approval.
