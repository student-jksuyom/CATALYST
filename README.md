# CATALYST

CATALYST is a Flutter application for retrieving Philippine legal articles
related to a user's concern.

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
Flask API and original `.xlsx`/`.pkl` corpus files remain available as
reference baselines and are not used by the active Flutter search path.

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

