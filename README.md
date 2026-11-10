# CATALYST

CATALYST is a Flutter application for retrieving Philippine legal articles
related to a user's concern.

## Finding legal services

The home menu's Map screen includes an experimental Google shared-map preview
of a fixed area. It does not update to the selected city, category, or device
location, and does not add legal-office search markers. Users can pan and zoom
if the preview loads. Google controls the embedded content and its availability
in a native WebView is not guaranteed. The app attempts to prevent preview
links from navigating away, but not all interactions can be intercepted;
use the search buttons for reliable navigation.

The screen searches for Public Attorney's Office locations,
lawyers and law offices, or legal aid services. Users can enter a city or
choose to share their approximate device location; the app asks for permission
only when location is selected and does not save it. A search opens Google Maps
or a browser outside CATALYST, after confirmation, and sends the selected search
and area to Google.
An internet connection is required. Listings may be incomplete or out of date;
users should verify details and credentials. This uses Google Maps URLs, not a
Maps API key or billing account. Google determines how the search area is
interpreted and ranks results.
On Android the location search first uses a map intent centered on the rounded
coordinates, falling back to a Google Maps URL if no map app handles it. On iOS
the URL includes the coordinates in the search text; search interpretation can
vary. For iOS Swift Package Manager builds set
`BYPASS_PERMISSION_LOCATION_ALWAYS=1` in the build environment so the
geolocator plugin is compiled for foreground-only location permission.

## Local semantic retrieval

Legal matching runs locally. It does not call the Python Flask API. The
retrieval path is:

1. Preserve the user's trimmed concern for display and record it alongside the
   processed query.
2. Identify the query language on device. English queries pass through
   unchanged; Tagalog and Taglish queries are translated from Tagalog to
   English before retrieval.
3. Tokenize the query (prefixed with `query: `) with the packaged
   `e5_tokenizer.json`, truncating to 128 tokens.
4. Run the multilingual-e5-small ONNX encoder (`catalyst_encoder_e5.onnx`) with
   the ONNX Runtime Android CPU provider to produce a 384-dimensional,
   L2-normalized query embedding.
5. Score the query against the chunk embeddings (`chunk_embeddings_e5.f32`,
   mapped to articles by `chunk_owners_e5.json`), keeping the best chunk per
   article, and also rank articles with BM25.
6. Fuse both rankings with reciprocal rank fusion, apply the minimum-cosine
   gate, and display the top results.

The model session and corpus resources are initialized lazily and reused across
searches. Similarity scores are retrieval signals, not probabilities or legal
advice. Optional online reranking (Cloudflare Worker + Gemini) and the
on-device fallback are described in `docs/hybrid_retrieval.md`. The Python
corpus-processing pipeline and embedded `.pkl` remain available for offline
experiments; the source `.xlsx` files are the prepared datasets described
below. None of these files are used by the active Flutter search path.

## Tagalog and Taglish preprocessing

The app uses the MIT-licensed `google_mlkit_language_id` and
`google_mlkit_translation` Flutter bridges to Google's ML Kit on-device
language identification and Tagalog-to-English translation. The bridge
packages are MIT-licensed; Google's ML Kit model/runtime is proprietary and
governed by the [ML Kit Terms of Service](https://developers.google.com/ml-kit/terms).
ML Kit processes query text on-device and says it does not send the text or
translation to Google, though the SDK can report usage metrics and contact
Google for model updates.

The Tagalog and English translation models are downloaded on demand (ML Kit
estimates about 30 MB per language model, or about 60 MB total). The app
requests downloads over Wi-Fi. After the models are available, translation
works offline. If models cannot be downloaded or translation fails, the app
logs the failure and continues retrieval using the original query; the
original query remains the one shown to the user. This keeps search available
offline, but translation is not available on a fresh/offline installation
until the models have been downloaded. ML Kit supports Tagalog (`tl`) and
English (`en`); it does not guarantee translation quality for Taglish or legal
terminology. Translations are preprocessing aids, not certified translations
or legal advice.

The Flutter ML Kit bridge requires iOS 15.5 or later; the Xcode project minimum
deployment target is therefore 15.5. The translation plugins target Android
API 21 or later. The Android debug APK built successfully and is
767,544,390 bytes, 74,802,316 bytes larger than the previously recorded
692,742,074-byte APK. The translation model packs are not bundled in that APK.
Translation latency and runtime memory have not been measured on a physical
device.

No before/after legal-relevance evaluation has been performed. The existing
`scripts/mobile_retrieval_validation.json` checks ONNX conversion parity, not
retrieval accuracy. Its unprocessed Tagalog defective-phone query ranked
CivilCode articles 1946 and 1939 (Commodatum), then 2140 (Chattel Mortgage);
the separate Taglish sample ranked articles 2018 (Gambling), 1616, and 1484.
These results show that the existing multilingual encoder alone can return
irrelevant articles for those examples. The added unit tests verify
preprocessing, original-query fallback, and which text reaches the encoder;
they do not exercise Google's translator or demonstrate that translated
queries improve the Top 3. A matched on-device evaluation against labeled
queries is still needed before claiming relevance improvement.

## Packaged retrieval assets

| Asset | Purpose | Size |
| --- | --- | ---: |
| `assets/models/catalyst_encoder_e5.onnx` | FP32 multilingual-e5-small encoder | 470,269,025 bytes |
| `assets/models/e5_tokenizer.json` | e5 tokenizer configuration and vocabulary | 17,082,730 bytes |
| `assets/data/legal_articles.json` | Article metadata for 2,700 corpus rows | 1,408,463 bytes |
| `assets/data/chunk_embeddings_e5.f32` | float32 e5 chunk embedding matrix (384 dims) | 6,709,248 bytes |
| `assets/data/chunk_owners_e5.json` | Chunk-to-article mapping | 20,246 bytes |
| `assets/data/jurisprudence.json` | 44 jurisprudence cases | 190,993 bytes |

Together these assets are about 495 MB, before Flutter and ONNX Runtime
libraries. Device installation size, peak memory, startup time, and Android
inference latency have not yet been measured.

The earlier MiniLM encoder, its tokenizer and its article embeddings were
removed from `assets/`. `scripts/export_mobile_corpus.py` and
`scripts/export_mobile_model.py` still write those legacy MiniLM outputs
(`article_embeddings.f32`, `catalyst_encoder.onnx`); do not re-run them into
`assets/` unless you intend to restore the old encoder. The e5 assets are
produced by the scripts under `tool/retrieval_lab`.

## Re-exporting and checking assets

`scripts/export_mobile_corpus.py` converts the preserved embedded corpus pickle
to the JSON metadata and float32 matrix consumed by Flutter. It validates
dimensions, finite values, and normalization before writing.

`scripts/export_mobile_model.py` exports the locally cached SentenceTransformer
checkpoint to ONNX and compares FP32 and dynamic-int8 variants with the Python
baseline. It records embedding dimensions/norms, embedding and score deltas,
ordered top-three results, and desktop warm-inference timings in
`scripts/mobile_retrieval_validation.json`. It selects a quantized model only
if all controlled top-three rankings match; otherwise it selects FP32 only
when its rankings match.

The recorded FP32 comparison preserved the ordered top three for English,
Tagalog, Taglish, and the defective-phone concern
`Binili ko yung phone pero sira agad kahit kakabili ko lang`. Across those
queries, maximum absolute embedding difference was about `1.63e-7` and
maximum top-three score difference was about `2.68e-7`. The reported warm
inference median of about 14.7 ms is from desktop CPU ONNX Runtime, not an
Android device. This parity check is not an evaluation of legal relevance;
that requires the labeled testing dataset.

## SBERT fine-tuning experiment

The prepared workbooks are stored in `DATA/Datasets/` as
`Trainingdataset.xlsx`, `Evaluationdataset.xlsx`, and `Testingdataset.xlsx`;
the prepared 2,700-article source is `DATA/Corpus/MasterCorpus.xlsx`.
The source corpus has the same article order and text as the currently bundled
corpus, so the existing E5 article and chunk embeddings remain valid. The app
also builds BM25 from `Article Text`; a separate keyword-extraction step is not
needed for the current retrieval path.

The active Flutter app still uses multilingual-e5-small. To experiment without
changing production assets, `tool/retrieval_lab/finetune_sbert.py` fine-tunes
the cached `paraphrase-multilingual-MiniLM-L12-v2` SentenceTransformer using
the training pairs and cosine-similarity loss. It compares the starting and
final model on the full corpus using the Evaluation Dataset, reports
Hit@1/3/5/10 and MRR@10. For manual-review training, it checks query overlap
with the old Testing split and retires it if any reviewed narratives were in
that split; its labels are never used as evaluation metrics. The
candidate and evaluation report are written to the ignored
`tool/retrieval_lab/out/sbert_finetune/` directory. These cosine-only
experimental scores do not by themselves establish that the candidate
outperforms the complete hybrid E5 app. Results reported before manual-review
training are historical, not final metrics for the updated candidate.

Evaluation Dataset comparison (46 positive query groups):

| Metric | Base MiniLM | Previous SBERT | Reviewed-hard-negative SBERT |
| --- | ---: | ---: | ---: |
| Hit@1 | 2/46 (4.3%) | 2/46 (4.3%) | 5/46 (10.9%) |
| Hit@3 | 3/46 (6.5%) | 5/46 (10.9%) | 11/46 (23.9%) |
| Hit@5 | 5/46 (10.9%) | 7/46 (15.2%) | 14/46 (30.4%) |
| Hit@10 | 8/46 (17.4%) | 11/46 (23.9%) | 16/46 (34.8%) |
| MRR@10 | 0.0702 | 0.1002 | 0.1882 |

The reviewed-hard-negative candidate improves ranking metrics over the prior
SBERT candidate on Evaluation. This split still has only one explicitly
non-relevant pair, so it is insufficient to establish robust quality or justify
migrating the app. The active Flutter E5 model is unchanged.

Historical pre-review Testing comparison (50 queries, 116 labeled relevant
query-article pairs; valid only for the earlier candidate):

| Metric | Base MiniLM | Fine-tuned SBERT | Current E5 hybrid* |
| --- | ---: | ---: | ---: |
| Hit@1 | 6.0% | 4.0% | 8.0% |
| Hit@3 | 8.0% | 14.0% | 10.0% |
| Precision@3 | 2.7% | 4.7% | 3.3% |
| Recall@3 | 3.4% | 6.0% | 4.3% |
| F1@3 | 3.0% | 5.3% | 3.8% |
| Recall@10 | 8.6% | 7.8% | 9.5% |
| MRR@10 | 0.082 | 0.079 | 0.106 |

These results predate the manual-review training and do not evaluate the
reviewed-hard-negative candidate. `*` E5 was run with raw queries and omits the
app's query normalization, glossary expansion, and on-device translation.
Retrieval precision/recall/F1 count only labeled relevant article IDs;
unjudged articles are treated as non-relevant.

Pair-classification accuracy, precision, and F1 are not reliable on the old
test split because it contains only positive pairs (116/116). On Evaluation,
which has 51 positive pairs and only one negative pair, the previous candidate
got 98.1% accuracy and 99.0% F1 at cosine threshold 0.5 but 0% specificity
(balanced accuracy 50%). This tiny negative sample is insufficient for
trustworthy classification metrics.

The per-query rankings, classification confusion matrices, and full retrieval
metrics are in the ignored
`tool/retrieval_lab/out/sbert_finetune/20261110_003421/testing_retrieval_report.json`.

To try arbitrary concerns from a PowerShell terminal, run:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\sbert_console.py
```

Enter a concern and compare up to 10 results each from Base MiniLM, fine-tuned
SBERT, and the current E5 hybrid; enter `:quit` to exit. The E5 approximation
may return fewer than 10 results when candidates do not pass its cosine gate.
You can change the number displayed with `--top`. To try one query directly:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\sbert_console.py --query "Pede ba kasuhan yung nag false advertise ng buy1 take3?"
```

To populate a manual relevance-review workbook with each narrative's top 10
results from the three retrievers, run:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\export_manual_review.py "C:\path\to\CATALYST-Manual-Relevance-Review.xlsx"
```

The exporter writes a separate `-Completed.xlsx` copy, fills retrieval model,
rank, article ID, cosine, and full article text, and preserves existing manual
labels and reasons. E5 results are from the raw-query approximation and can be
fewer than 10 if candidates do not pass its cosine gate.

After reviewing results, train an experimental SBERT candidate with the
judgments using:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\finetune_sbert.py `
  --model-path tool\retrieval_lab\out\sbert_finetune\20261110_003421\candidate_model `
  --manual-review "C:\path\to\CATALYST-Manual-Relevance-Review-Completed.xlsx" `
  --manual-review-label-override "CA-RR-016|consumeract:25|1" `
  --manual-review-label-override "CA-RR-016|consumeract:40|0" `
  --retire-existing-test
```

Reviewed query/article pairs are deduplicated across retrievers; `U` and blank
labels are excluded, and the reviewed 0/1 pairs are class-balanced during
sampling. The manual-review narratives used above overlap the previous Testing
split, so that split is retired; use a new unseen test set before reporting
final performance. The run report still compares the candidate on the separate
Evaluation split, which has very few negative judgments.

Using the project virtual environment, install the optional Python experiment
dependencies and run the structural/reference checks and experiment:

```powershell
.\.venv\Scripts\python.exe -m pip install sentence-transformers openpyxl
.\.venv\Scripts\python.exe scripts\validate_datasets.py
.\.venv\Scripts\python.exe tool\retrieval_lab\finetune_sbert.py
.\.venv\Scripts\python.exe tool\retrieval_lab\sbert_console.py
```

Run `sbert_console.py --evaluate` only for a candidate whose
`evaluation_report.json` has `final_test_metrics_valid: true`; manual-review
training retires the previous Testing split and the console blocks its reuse.
The updated candidate is compared on Evaluation until a fresh unseen test set
is prepared.

The console compares full-corpus Base MiniLM cosine, fine-tuned SBERT cosine,
and the current E5/BM25 hybrid; it accepts free-text concerns until `:quit`.
The first run computes corpus vectors and caches them under the selected
fine-tuning run. The E5 baseline uses raw queries, so its results approximate
production but omit Flutter-side normalization, glossary expansion, and
on-device Tagalog translation.

The original Testing Dataset has been retired for candidates trained with the
manual-review workbook. Prepare a new unseen test set before final performance
claims. Do not copy this candidate into `assets/` or change the Flutter
encoder without a separate end-to-end comparison against the active hybrid E5
retrieval path.

## Validation

Run Flutter analysis and the focused local retrieval/navigation tests:

```powershell
flutter analyze
flutter test test/local_tokenizer_test.dart test/legal_query_preprocessor_test.dart test/local_semantic_retrieval_service_test.dart test/production_navigation_test.dart
```

Run `flutter test` for the full suite.

The Android app has not been installed or exercised on a physical device with
network access disabled. Before claiming verified offline device operation,
build and install the app manually, disable Wi-Fi and mobile data, and test
English, Tagalog, Taglish, and the defective-phone concern. Compare the returned
article identities with the Python baseline and record device startup, memory,
and inference timings. This migration has not installed or launched the app on
any physical device.

## Retrieval diagnosis and baselines

Who retrieves vs. reranks, the Gemini quota analysis, the fallback verification and reproducible baselines for both modes are in [docs/hybrid_retrieval.md](docs/hybrid_retrieval.md).
