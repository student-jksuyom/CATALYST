# CATALYST: overall status, capabilities, and limitations

**Assessment date:** 2026-11-15

**Scope:** Repository source, bundled assets, documentation, and local validation
performed for this report. This is an engineering status assessment, not a
legal or security audit.

## Executive summary

CATALYST is a Flutter mobile application that searches a bundled Philippine-law
corpus for provisions related to a user's account. Article retrieval and
evidence selection run on the device. The app also includes article detail and
explanation screens, a small bundled Supreme Court case collection, local
search history and bookmarks, a guided follow-up experience, and a Google Maps
handoff for finding legal services.

The application has a substantial working prototype and meaningful automated
coverage, but it is **not release-ready**. The principal product risk is
unproven and weak retrieval quality: current development-set results are low,
and the independent held-out gate is provisional and still fails its
no-match/abstention requirement. The corpus is limited to three statutes.
Current checkout validation also found Flutter analyzer errors and five
failing widget tests. Release signing, deployment configuration, privacy
controls for local records, and real-device performance need further work.

**Overall assessment:** usable as a research prototype for limited exploration
of the bundled sources; not suitable for asserting that a statute applies,
replacing legal advice, or making accuracy claims.

## Product and architecture

| Area | Current implementation |
| --- | --- |
| Client | Flutter / Dart application; Android and iOS project files are present. |
| Article search | On-device multilingual E5-small ONNX encoder, chunk embeddings, BM25, reciprocal-rank fusion, a labeled training-query signal, and a cosine cutoff. |
| Source content | 2,700 article rows from the Civil Code, Family Code, and Consumer Act; 44 bundled Supreme Court decisions. |
| Explanation | On-device templates show the provision text and a similar passage, wording clues, cautions, and legal-information reminders. This is not generated legal analysis. |
| Conversation | Offline, rule-driven follow-up behavior; optional Gemini-backed follow-up through the Cloudflare Worker when configured. |
| History | Search narratives, retrieved results, and favorites are persisted in an app-private JSON file. Chat messages are not saved. |
| Legal-service lookup | Google Maps preview and external Google Maps/browser searches by entered location or approximate device location. |
| Data and model experiments | Python scripts and retrieval experiments are separate from the active Flutter retrieval path. Experimental encoders are not integrated. |

Article retrieval does not require the Worker or an internet connection in its
design. Internet access is needed for optional online follow-up and Google Maps
searches. The app's actual operation on a fully disconnected physical device
has not been verified for this checkout.

## Capabilities available in the app

- Accepts legal concerns and returns up to three leading article matches plus
  additional candidates.
- Uses local E5 embeddings, lexical BM25 matching, Filipino legal-vocabulary
  expansion, and labeled training-query examples to rank candidates.
- Displays article wording, a retrieved passage, and cautionary explanations
  in English, Tagalog, and Taglish.
- Finds similar decisions from the bundled jurisprudence data and relates
  those decisions to retrieved provisions.
- Offers guided follow-up prompts, additional-fact retrieval, and optional
  online follow-up answers grounded in the provisions and cases sent to the
  proxy.
- Persists and reopens searches and bookmarks; supports deleting records and
  clearing non-favorites.
- Opens external searches for PAO offices, lawyers/law offices, or legal aid,
  using a city/municipality or user-approved approximate location.

The fixed-area map preview is not a live locator and does not display the
selected search results. Google Maps results are external, may be incomplete
or stale, and need independent verification.

## Quality evidence and confidence

### Retrieval

The current production path is the E5 hybrid retriever described in
[hybrid retrieval and evaluation notes](hybrid_retrieval.md). On the project's
46 positive-query Evaluation groups, it found a labeled article at rank 1 for
11/46 queries, within the first 3 for 16/46, and within the first 15 for 20/46
(MRR@15 0.304). These are development results from sparse, provisional labels;
unlisted articles are not necessarily irrelevant.

The separate 42-case held-out gate contains 27 retrieval-positive cases and 15
no-match cases. A documented provisional run found a labeled relevant article
at rank 1 for 7/27 positive cases, within rank 3 for 11/27, and within rank 15
for 16/27. The current documented run returned provisions for 8/15 no-match
cases, failing the gate's zero-false-positive requirement. The gate annotations
are marked as needing second review; these results are not lawyer-validated
accuracy measurements.

Consequently:

- Similarity scores and ranks are retrieval signals, not probabilities,
  relevance guarantees, or legal conclusions.
- The app may miss a relevant provision or surface an unrelated one.
- A retrieved provision does not establish that its conditions apply to the
  user's facts.
- The evaluation data is small, sparse, and has been used during development;
  it is not an untouched final test set.
- The optional online follow-up does not retrieve or rerank statute articles.
  It cannot repair an article omitted by local retrieval.

### Automated validation in this checkout

| Check | Result |
| --- | --- |
| `flutter analyze` | **Failed:** 8 diagnostics in the modified `integration_test/retrieval_preprocessing_eval_test.dart`. Its `import ;` at line 4 leaves query-preprocessor types unresolved. |
| `flutter test` | **Failed:** 139 tests passed and 5 failed. Failures: the online-processing disclosure test; two law-details follow-up input/send tests; and two XAI chat input/navigation tests. |
| `node --test backend/worker.test.mjs` | **Passed:** 7 tests, using mocked Gemini calls; this does not verify a live Worker or Gemini account. |

The affected integration-test file was already modified in the worktree when
assessment began. Other application, build, and retrieval documentation files
also have pre-existing modifications; this report does not attribute those
changes or their failures to a particular author or commit.

## Data, dependencies, and operational footprint

Bundled corpus and model counts were inspected directly:

| Asset | Approximate size |
| --- | ---: |
| E5 ONNX encoder | 470.3 MB |
| E5 tokenizer | 17.1 MB |
| Legal article JSON | 1.4 MB |
| Chunk embeddings | 6.7 MB |
| Training-query vectors and labels | 0.3 MB |
| Jurisprudence JSON | 0.2 MB |

These listed assets total roughly 496 MB before Flutter and native runtime
libraries. An existing debug APK in the workspace is about 480 MB; it was not
rebuilt as part of this assessment and should not be treated as a release-size
measurement. Startup time, peak memory, battery use, inference latency, release
APK size, and performance across supported devices remain unmeasured.

The Android application ID is still `com.example.catol`, and the Android
release build configuration currently uses the debug signing key. These are
release blockers. iOS files are present, but an iOS build and runtime were not
validated here.

## Problems, limitations, and risks

### Product quality and scope

1. **Low and uncertain retrieval quality.** The current labeled results are
   modest, the held-out gate fails no-match rejection, and annotations are
   provisional. No independent, lawyer-reviewed final evaluation supports an
   accuracy claim.
2. **Narrow source coverage.** The bundled statute collection is limited to
   Civil Code, Family Code, and Consumer Act provisions, with 44 decisions.
   Other areas of Philippine law may be absent.
3. **No fact-specific legal determination.** Passage similarity and templates
   do not interpret all requirements, exceptions, procedural rules, or the
   user's evidence. Offline follow-up behavior is rule-based and deliberately
   limited.
4. **Known source-data caveats.** The explanation code flags known issues in
   Family Code articles 176 and 213, and warns about duplicate article IDs.
   Users still need to verify statutes against authoritative current sources.
5. **Language handling is heuristic.** Filipino vocabulary expansion and
   domain classification are finite rules, not robust translation or legal
   language understanding.

### Privacy, network, and reliability

1. **Sensitive local history is not encrypted by the app.** Search narratives
   and results are stored in an app-private JSON file. Device access and
   backups may expose them. Users should avoid entering unnecessary
   identifying information.
2. **Online follow-up sends sensitive context externally.** When configured,
   the question, narrative, selected provisions, and selected decisions go to
   the configured proxy and Gemini. This is distinct from local article
   retrieval. Deployment, provider data handling, user consent, retention, and
   production privacy terms require review.
3. **The app token is not a durable secret.** A token embedded in a client
   build can be extracted. The Worker has no robust per-user authentication
   or abuse control established by this repository.
4. **Live online behavior is unverified.** Worker tests mock Gemini. No live
   endpoint, deployed token, Gemini quota, billing configuration, or current
   service availability was checked for this report. Worker source can try
   multiple models, and optional search can raise one follow-up to four
   upstream attempts when earlier attempts fail.
5. **Maps leaves the app.** A city query or approximate coordinates are sent
   to an external map app/service after confirmation. An internet connection
   is required, and results are not verified by CATALYST.

### Engineering and release readiness

1. **Validation is currently red.** Flutter analysis reports eight
   diagnostics, and five widget tests fail; see the exact output above.
2. **Large model footprint.** The FP32 encoder is about 470 MB by itself.
   Mobile memory and latency have not been profiled, and no production
   quantized model has been validated.
3. **Release configuration is incomplete.** Placeholder Android application
   ID and debug signing prevent a production release.
4. **Platform status differs.** An earlier installation report documents a
   debug Android build on a physical device, but this assessment did not
   rebuild or verify that installed revision. iOS is configured, not verified.
5. **Developer tooling is split.** Python asset-generation and retrieval
   experiments live in multiple directories; optional dependencies and
   reproducible setup are not represented by one maintained root
   requirements manifest. These tools do not form the production app runtime.

## Recommended priorities

1. Restore clean Flutter analysis, beginning with the malformed import in the
   modified retrieval integration test; then resolve the five failing widget
   tests and rerun checks.
2. Treat retrieval as the primary product blocker: review the failing and
   no-match cases with qualified legal reviewers, build a genuinely
   independent test set, and improve the system only against separate
   development data.
3. Measure inference latency, startup, memory, and install size on target
   Android devices; validate fully offline operation before making offline
   reliability claims.
4. Complete privacy and release work: decide local-history retention/backup
   behavior, make online disclosure explicit, verify proxy protections and
   quota behavior, set a production application ID, and configure release
   signing.
5. Validate iOS builds and platform-specific permission behavior, and provide
   reproducible setup instructions for Python tooling used to regenerate
   bundled assets.

## Supporting documentation

- [Project README](../README.md): user-facing behavior, privacy notes,
  retrieval assets, and validation commands.
- [Hybrid retrieval and evaluation notes](hybrid_retrieval.md): algorithm
  details, datasets, measurements, and evaluation caveats.
- [Retrieval training experiments](retrieval_training_experiments.md):
  separate MiniLM experiments; no candidate is integrated into the app.
- [Technology inventory](technology_inventory.md): component-level inventory;
  parts of this older inventory are historical and should not override the
  current code or this report.
- [Installation report](../INSTALLATION_REPORT.md): historical Android debug
  installation notes, not a current release certification.
