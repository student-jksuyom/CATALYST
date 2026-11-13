# CATALYST

CATALYST is a Flutter application for retrieving Philippine legal articles
related to a user's concern.

## Search history

Completed searches, their returned matches and bookmarks are stored on the
device as an unencrypted app-private file. They may contain sensitive legal
details; anyone with access to the app or a device backup may be able to read
them. History is not synced between devices. Open History to revisit a search,
favorite or delete it. Clear All removes non-favorites and keeps favorites;
delete favorites individually to remove them. Chat messages are not saved.

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
2. Analyze the query on device and expand recognized Filipino legal terms with
   an offline glossary. The original query is retained; no translation model
   is downloaded or called.
3. Tokenize the query (prefixed with `query: `) with the packaged
   `e5_tokenizer.json`, truncating to 128 tokens.
4. Run the multilingual-e5-small ONNX encoder (`catalyst_encoder_e5.onnx`) with
   the ONNX Runtime Android CPU provider to produce a 384-dimensional,
   L2-normalized query embedding.
5. Score the query against the chunk embeddings (`chunk_embeddings_e5.f32`,
   mapped to articles by `chunk_owners_e5.json`), keeping the best chunk per
   article, and also rank articles with BM25. Recognized everyday terms such
   as "landlord" add legal vocabulary such as "lessor" to the BM25 query only.
6. Compare the query embedding with the packaged embeddings of labeled
   Training Dataset queries from the same detected legal domain. Up to three
   neighbors can contribute their reviewed relevant and non-relevant article
   labels; neighbors below cosine 0.90 are ignored.
7. Fuse dense, BM25, and eligible example rankings. The example signal
   contributes at most 30% of the final ranking score; it supplements rather
   than replaces the provision text match. A 0.80 article-cosine gate filters
   candidates before the top results are displayed.

The model session and corpus resources are initialized lazily and reused across
searches. Similarity scores are retrieval signals, not probabilities or legal
advice. Article retrieval and the evidence shown with matches are always
on-device. XAI follow-up and Near Legal Services may use the internet; XAI
follow-up may send the narrative, question, provisions and selected cases to
the configured proxy and Gemini. The Python
corpus-processing pipeline and embedded `.pkl` remain available for offline
experiments. The Training Dataset is used offline to build the compact query
example index; the app packages only its normalized vectors and article labels,
not the source narratives or workbooks.

## Offline explanation and limitations

The app compares the narrative with precomputed article passages using the
local multilingual E5 encoder. It displays a concern excerpt and the most
similar passage as evidence, together with a warning to check conditions and
exceptions. This is a similarity-based aid, not a generated fact-to-rule legal
analysis. The encoder cannot generate prose or decide whether a provision
applies. The app does not download additional translation models.

The 12-query paired regression run is documented in
[`docs/hybrid_retrieval.md`](docs/hybrid_retrieval.md); it is a limited app
pipeline check, not an independent legal-relevance evaluation or an on-device
accuracy claim. The existing `scripts/mobile_retrieval_validation.json` checks
ONNX conversion parity, not retrieval accuracy. Earlier E5-only probes ranked
the unprocessed Tagalog defective-phone concern with CivilCode articles 1946
and 1939 (Commodatum), then 2140 (Chattel Mortgage); the separate Taglish
sample ranked articles 2018 (Gambling), 1616, and 1484. The paired regression
run exercises the recorded translations, not Google's translator itself.
Independent, lawyer-reviewed test data is still needed before making broader
accuracy claims. On the 46 positive query groups exported from the project's
Evaluation Dataset, the current app pipeline finds a labeled article at rank 1
for 11 queries, in the first 3 for 16, and in the first 15 for 20. This split
has been used for experimentation and has sparse labels; these counts do not
establish that other results are irrelevant or that returned provisions apply.

## Packaged retrieval assets

| Asset | Purpose | Size |
| --- | --- | ---: |
| `assets/models/catalyst_encoder_e5.onnx` | FP32 multilingual-e5-small encoder | 470,269,025 bytes |
| `assets/models/e5_tokenizer.json` | e5 tokenizer configuration and vocabulary | 17,082,730 bytes |
| `assets/data/legal_articles.json` | Article metadata for 2,700 corpus rows | 1,408,463 bytes |
| `assets/data/chunk_embeddings_e5.f32` | float32 e5 chunk embedding matrix (384 dims) | 6,709,248 bytes |
| `assets/data/chunk_owners_e5.json` | Chunk-to-article mapping | 20,246 bytes |
| `assets/data/training_query_embeddings_e5.f32` | E5 vectors for 182 labeled training queries | 279,552 bytes |
| `assets/data/training_query_labels_e5.json` | Domain and reviewed article labels for those queries | 14,683 bytes |
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

Rebuild the local, narrative-free supervised query index after changing the
Training Dataset, corpus, or E5 assets:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\export_training_query_index.py
```

The exporter rejects unknown article references, conflicting labels, invalid
domains, and non-normalized embeddings. The app validates the index dimensions
and corpus version again when it loads the assets.

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
with the old Testing split and also inherits any previous test-retirement flag
from the starting checkpoint. Retired-test labels are never reused as final
evaluation metrics. The
candidate and evaluation report are written to the ignored
`tool/retrieval_lab/out/sbert_finetune/` directory. These cosine-only
experimental scores do not by themselves establish that the candidate
outperforms the complete hybrid E5 app. Results reported before manual-review
training are historical, not final metrics for the updated candidate.

Evaluation Dataset comparison (46 positive query groups):

| Metric | Base MiniLM | Previous SBERT | First reviewed SBERT | Latest reviewed SBERT |
| --- | ---: | ---: | ---: | ---: |
| Hit@1 | 2/46 (4.3%) | 2/46 (4.3%) | 5/46 (10.9%) | 5/46 (10.9%) |
| Hit@3 | 3/46 (6.5%) | 5/46 (10.9%) | 11/46 (23.9%) | 12/46 (26.1%) |
| Hit@5 | 5/46 (10.9%) | 7/46 (15.2%) | 14/46 (30.4%) | 12/46 (26.1%) |
| Hit@10 | 8/46 (17.4%) | 11/46 (23.9%) | 16/46 (34.8%) | 17/46 (37.0%) |
| MRR@10 | 0.0702 | 0.1002 | 0.1882 | 0.1979 |

The latest candidate adds 1 Hit@3 and 1 Hit@10 query over the first reviewed
candidate, while Hit@1 is unchanged and Hit@5 is lower by 2 queries. This is a
small, mixed change—not a broad improvement. Evaluation has only one explicitly
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
app's query normalization and glossary expansion.
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

The latest experimental candidate, trained from the first reviewed SBERT
candidate with the second manual-review workbook, is in
`tool/retrieval_lab/out/sbert_finetune/20261112_121812/candidate_model`.
Its report is `tool/retrieval_lab/out/sbert_finetune/20261112_121812/evaluation_report.json`.
The 1,200-row workbook contributed 1,068 deduplicated binary judgments
(107 relevant, 961 non-relevant); one blank was excluded. `IRRELEVANT` text
labels were treated as 0. The adopted overrides were
`NTC-FC-009|familycode:183|1`, `NTC-FC-009|familycode:188|1`, and
`NTC-CC-017|civilcode:1167|1`. To reproduce the run from the prior reviewed
candidate:

```powershell
.\.venv\Scripts\python.exe tool\retrieval_lab\finetune_sbert.py `
  --model-path tool\retrieval_lab\out\sbert_finetune\20261110_160322\candidate_model `
  --manual-review tool\retrieval_lab\out\sbert_finetune\review_source_20261112.xlsx `
  --manual-review-label-override "NTC-FC-009|familycode:183|1" `
  --manual-review-label-override "NTC-FC-009|familycode:188|1" `
  --manual-review-label-override "NTC-CC-017|civilcode:1167|1"
```

Reviewed query/article pairs are deduplicated across retrievers; `U` and blank
labels are excluded, and the reviewed 0/1 pairs are class-balanced during
sampling. This latest review has no exact narrative overlap with Training,
Evaluation, or Testing. However, the candidate descends from a model trained
on the earlier review of Testing narratives, so the old Testing split remains
retired throughout this model lineage. Obtain a new unseen test set for final
performance claims. The run report compares against the separate Evaluation
split, which has very few negative judgments.

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
production but omit Flutter-side normalization and glossary expansion.

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

The updated debug app was installed and launched on an Android device, and a
retrieved result with local passage evidence was observed. A search with both
Wi-Fi and mobile data disabled has not been verified. Before claiming verified
offline device operation, test English, Tagalog, Taglish, and the defective-phone
concern with both connections disabled; compare article identities with the
baseline and record device startup, memory, and inference timings.

## Retrieval diagnosis and baselines

Offline retrieval and its measured limitations are described in [docs/hybrid_retrieval.md](docs/hybrid_retrieval.md).
