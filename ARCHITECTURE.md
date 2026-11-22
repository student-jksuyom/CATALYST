# CATALYST System Architecture

## Overview

CATALYST is a **Flutter mobile application** that provides offline legal article retrieval for Philippine legal queries. It uses a hybrid semantic search approach combining dense embeddings, BM25 lexical ranking, and supervised training-query signals—all running **entirely on-device** for article retrieval.

**Key Principle:** No external services are required for core retrieval; the app is designed for offline operation. Optional XAI follow-up can use a Cloudflare Worker proxy to access Gemini API.

---

## System Layers

### 1. **Presentation Layer** (Flutter UI)

#### Screens
- **[LandingScreen](lib/landing_screen.dart)** - Entry point with onboarding
- **[HomeScreen](lib/home_screen.dart)** - Main menu with 4 navigation options
  - Search (user input)
  - History (saved searches)
  - Chat (XAI follow-up)
  - Map (legal services locator)
  - About
- **[UserInputScreen](lib/user_input_screen.dart)** - Query input form
- **[ProcessingScreen](lib/processing_screen.dart)** - Loading state during retrieval
- **[MatchResultsScreen](lib/match_results_screen.dart)** - List of top matched articles
- **[LawDetailsScreen](lib/law_details_screen.dart)** - Full article text + passage evidence + bookmarking
- **[XaiChatbotScreen](lib/xai_chatbot_screen.dart)** - Follow-up Q&A with optional Gemini
- **[HistoryScreen](lib/history_screen.dart)** - Saved searches (favorites & full history)
- **[LegalServicesScreen](lib/legal_services_screen.dart)** - Map & location-based legal service finder
- **[AboutScreen](lib/about_screen.dart)** - App info & disclaimers

#### Key UI Features
- Material Design 3 with custom branding colors
- Custom fonts (Fredoka, Inter, Montserrat)
- Asset images for icons and branding
- Responsive layout for mobile

---

### 2. **Core Retrieval Service** (On-Device)

#### [CatalystLocalRetrievalService](lib/services/catalyst_local_retrieval_service.dart)

This is the heart of CATALYST's offline search engine.

**Initialization (Lazy):**
1. Load ONNX encoder model (`catalyst_encoder_e5.onnx` - 470 MB, multilingual-e5-small)
2. Load article corpus metadata (`legal_articles.json` - 2,700 articles)
3. Load chunk embeddings matrix (`chunk_embeddings_e5.f32` - 384-dim vectors)
4. Load chunk-to-article mappings (`chunk_owners_e5.json`)
5. Load training query embeddings (`training_query_embeddings_e5.f32`)
6. Load training query labels (`training_query_labels_e5.json`)
7. Build BM25 lexical index from corpus

**Retrieval Pipeline (Per Query):**

1. **Query Analysis & Preprocessing** → [LegalQueryPreprocessor](lib/services/legal_query_preprocessor.dart)
   - Detect legal domain (family, civil, commercial, etc.)
   - Expand everyday terms to legal equivalents (glossary-based)
   - Store original query for display
   - Store processed query for logging

2. **Tokenization** → [LocalTokenizer](lib/services/local_tokenizer.dart)
   - Use bundled `e5_tokenizer.json`
   - Prefix query with `"query: "` (E5 training convention)
   - Truncate to 128 tokens

3. **Dense Embedding** → ONNX Runtime
   - Run multilingual-e5-small encoder
   - Produce 384-dimensional vector
   - L2-normalize to unit length

4. **Lexical Search** → [LexicalIndex](lib/services/lexical_index.dart)
   - BM25 scoring of expanded query terms
   - Expanded terms (glossary only) used for BM25, not encoder

5. **Candidate Scoring**
   - **Dense Signal:** Cosine similarity (query embedding vs. chunk embeddings)
   - **Lexical Signal:** BM25 score
   - **Training Signal:** Find up to 3 nearest labeled training queries (cosine > 0.90)
     - Inherit their reviewed relevant/non-relevant article labels
     - Contributes max 30% to final score

6. **Ranking & Fusion** → Reciprocal-Rank-Fusion (RRF) with K=20
   - Combine ranks from dense, BM25, and training signals
   - Keep best chunk per article
   - Filter: Minimum cosine 0.80 (heuristic gate)
   - Normalize dense scores: floor=0.75, ceiling=0.90 for display

7. **Output**
   - Top 3 results (displayed as "best matches")
   - Remaining 12 (displayed as "other candidates") up to 15 total

**Constants:**
```
_embeddingDimensions = 384
_topResultCount = 3
_allResultCount = 15
_candidatePoolSize = 50
_fusionK = 20
_defaultMinimumCosine = 0.80
_displayFloorCosine = 0.75
_displayCeilingCosine = 0.90
_lexicalWeight = 0.15
_trainingSignalWeight = 0.30
```

---

### 3. **Query Processing** (Pre-Retrieval)

#### [LegalQueryPreprocessor](lib/services/legal_query_preprocessor.dart)
- Detects legal domain from query text
- Expands everyday terms to legal equivalents
- Returns processed query object with metadata

#### [QueryAnalysis](lib/services/query_analysis.dart)
- Helper functions for query domain detection
- Glossary lookup for term expansion

#### [LocalTokenizer](lib/services/local_tokenizer.dart)
- Tokenizes text using bundled `e5_tokenizer.json`
- Handles special tokens and vocabulary
- Respects 128-token truncation limit

---

### 4. **Post-Retrieval Services**

#### [ExplanationBuilder](lib/services/explanation_builder.dart)
- Compares narrative text with retrieved article chunks
- Finds passage-level semantic similarity (local E5 encoder)
- Displays relevant excerpt + matching chunk as evidence
- Shows similarity score (mapped to 0-100% display scale)
- Includes disclaimer: *"Similarity is a retrieval signal, not a probability or legal conclusion"*

#### [ExplanationLanguage](lib/services/explanation_language.dart)
- Manages display text for evidence and explanations
- Language-aware formatting

#### [JurisprudenceService](lib/services/jurisprudence_service.dart)
- Loads precomputed jurisprudence cases (`jurisprudence.json` - 44 cases)
- Provides relevant cases as supporting context for articles

---

### 5. **Follow-Up Chat Service** (Optional Online)

#### [CaseConversation](lib/services/case_conversation.dart)
- Manages multi-turn conversation context
- Tracks narrative, retrieved articles, user questions
- Can route to online or on-device follow-up

#### [FollowUpService](lib/services/followup_service.dart)
- **On-Device Fallback:** Similarity-based answer from article text
- **Online Path:** (Optional) Calls Cloudflare Worker → Gemini API
- Returns `RetrievalMode` enum: `onDevice`, `online`, `onDeviceFallback`

**Online Stack (Optional):**
1. App sends: narrative + question + article context
2. Cloudflare Worker validates token (`APP_TOKEN`)
3. Worker calls Google Gemini API (free tier, no billing)
4. Gemini uses Google Search grounding
5. Response returned to app, marked as `online`
6. If online fails, falls back to on-device similarity

---

### 6. **Local Storage**

#### [HistoryStore](lib/services/history_store.dart)
- Persists searches as unencrypted app-private files
- Stores:
  - Original query + processed query
  - Retrieved results (up to 15)
  - Passage evidence
  - Bookmarks (favorites)
- Operations:
  - `addSearch()` - Record new search
  - `getHistory()` - List searches
  - `setFavorite()` - Mark/unmark article
  - `deleteSearch()` - Remove entry
  - `clearNonFavorites()` - Bulk delete

#### Models
- [HistoryEntry](lib/models/history_entry.dart) - Search record
- [LawMatchResult](lib/models/law_match_result.dart) - Article + metadata

---

### 7. **Connectivity**

#### [ConnectivityService](lib/services/connectivity_service.dart)
- Checks internet availability
- Used to determine if online follow-up is possible
- Gracefully handles offline operation

---

### 8. **Asset Data** (~495 MB total)

| Asset | Purpose | Size |
|-------|---------|------|
| `assets/models/catalyst_encoder_e5.onnx` | FP32 multilingual-e5-small encoder | 470 MB |
| `assets/models/e5_tokenizer.json` | E5 tokenizer vocab + config | 17 MB |
| `assets/data/legal_articles.json` | 2,700 corpus articles + metadata | 1.4 MB |
| `assets/data/chunk_embeddings_e5.f32` | 384-dimensional chunk vectors | 6.7 MB |
| `assets/data/chunk_owners_e5.json` | Chunk ↔ article mapping | 20 KB |
| `assets/data/training_query_embeddings_e5.f32` | 182 labeled training query vectors | 280 KB |
| `assets/data/training_query_labels_e5.json` | Domain + article labels | 15 KB |
| `assets/data/jurisprudence.json` | 44 jurisprudence cases | 191 KB |

---

## Data Flow Diagram

### Search Flow
```
User Input
    ↓
[LegalQueryPreprocessor] → analyze domain, expand terms
    ↓
[LocalTokenizer] → tokenize with e5_tokenizer.json (128 tokens max)
    ↓
[ONNX Runtime] → multilingual-e5-small encoder → 384-dim embedding
    ↓
┌────────────────────────────────────────────────────────┐
│ Hybrid Ranking                                         │
├────────────────────────────────────────────────────────┤
│ Dense Signal: query embedding vs. chunk embeddings     │
│ Lexical Signal: BM25 of expanded terms                 │
│ Training Signal: 3-NN labeled queries (cosine > 0.90)  │
│ → Fusion with RRF (K=20)                               │
│ → Filter: cosine > 0.80                                │
│ → Top 3 + other 12 candidates (15 total)               │
└────────────────────────────────────────────────────────┘
    ↓
[MatchResultsScreen] → display results
    ↓
User selects article
    ↓
[ExplanationBuilder] → passage-level E5 similarity
    ↓
[LawDetailsScreen] → full article + evidence + jurisprudence cases
    ↓
[HistoryStore] → save search
```

### Follow-Up Chat Flow
```
User Question
    ↓
[CaseConversation] → context (narrative, article, question)
    ↓
Is internet available? [ConnectivityService]
    ├─ YES → Online path
    │   ├─ [Cloudflare Worker] (validates APP_TOKEN)
    │   │   ├─ [Gemini API] (Google Search grounding)
    │   │   └─ Response
    │   └─ Mark as "online"
    │
    └─ NO or online failed → On-Device path
        ├─ [ExplanationBuilder] → passage similarity
        └─ Mark as "onDevice" or "onDeviceFallback"
    ↓
Display answer
```

---

## Dependencies

### Flutter Packages
```yaml
flutter_onnxruntime: ^1.9.0          # ONNX model inference
dart_sentencepiece_tokenizer: ^1.4.1 # Tokenization
geolocator: ^14.1.2                  # Device location
path_provider: ^2.1.5                # Local file storage
url_launcher: ^6.3.3                 # Open maps/browser
webview_flutter: ^4.14.1             # Embedded map preview
connectivity_plus: ^4.0.0            # Network status
```

### Dev Dependencies
```yaml
flutter_test: (SDK)
integration_test: (SDK)
flutter_lints: ^6.0.0
```

---

## Backend (Optional XAI Proxy)

### Cloudflare Workers ([backend/worker.js](backend/worker.js))

**Deployment:**
1. Get free Gemini API key (https://aistudio.google.com)
2. Deploy: `npx wrangler deploy`
3. Set secrets: `GEMINI_API_KEY`, `APP_TOKEN`, `GEMINI_MODEL`

**Function:**
- Receives: `{narrative, question, articles, passages}`
- Validates: `APP_TOKEN`
- Calls: Google Gemini API with Search grounding
- Returns: Generated explanation
- Keeps Gemini key off-device

**Configuration (wrangler.toml):**
```toml
GEMINI_MODEL = "gemini-2.0-flash"  # or latest free-tier model
```

---

## Evaluation & Testing

### On-Device Validation
- **Flutter Analysis:** `flutter analyze`
- **Unit Tests:** `test/`
  - `local_tokenizer_test.dart`
  - `legal_query_preprocessor_test.dart`
  - `local_semantic_retrieval_service_test.dart`
  - `production_navigation_test.dart`
- **Integration Tests:** `integration_test/`

### Retrieval Benchmarks

#### Development Evaluation Dataset (46 query groups)
| Metric | Result |
|--------|--------|
| Hit@1 | 11/46 (23.9%) |
| Hit@3 | 16/46 (34.8%) |
| Hit@15 | 20/46 (43.5%) |
| MRR@15 | 0.304 |

#### Independent Heldout Test (27 positive + 15 no-match cases)
| Metric | Result |
|--------|--------|
| Hit@1 (positive) | 7/27 (25.9%) |
| Hit@3 (positive) | 11/27 (40.7%) |
| Hit@15 (positive) | 16/27 (59.3%) |
| False Positives (no-match) | 8/15 (53%) |

**Note:** These are development metrics on provisional labels. A fresh held-out test with lawyer-reviewed applicability judgments is needed before legal deployment claims.

### Offline Validation Tools
- `tool/retrieval_lab/export_training_query_index.py` - Rebuild labeled query index
- `tool/retrieval_lab/sbert_console.py` - Compare retrieval models
- `tool/offline_eval/offline_eval_test.dart` - Run heldout evaluation
- `scripts/export_mobile_corpus.py` - Validate corpus export
- `scripts/export_mobile_model.py` - ONNX model validation & quantization

---

## Key Design Decisions

### 1. **Offline-First Architecture**
- All core retrieval runs on-device
- No backend required for article search
- XAI follow-up is optional; fails gracefully to on-device answers

### 2. **Hybrid Ranking**
- **Why combine signals?**
  - Dense (E5): Semantic understanding across languages
  - Lexical (BM25): Exact term matching for legal codes/numbers
  - Supervised (Training Queries): Domain-specific labeling
- **Why RRF fusion?** Rank-independent, parameter-light, empirically robust

### 3. **Multilingual-E5-Small**
- Chosen for: mobile inference speed, 384-dim efficiency, multilingual support
- Alternatives screened (E5-base, BGE-M3) but not deployed due to:
  - Larger model size / longer inference time
  - Calibration needed for cosine gates
  - Development-set performance gains not independent-test validated

### 4. **Asset Versioning**
- Assets bundled at build time
- Heuristic: corpus version in JSON metadata
- Old MiniLM encoder removed from `assets/` (legacy assets available in `tool/retrieval_lab/`)

### 5. **Passage Evidence**
- Not a legal analysis—a similarity-based retrieval signal
- Compares narrative excerpt with article chunk using same E5 encoder
- Always displayed with disclaimers

### 6. **Privacy**
- Search history stored as unencrypted app-private file
- Device location shared only on explicit user action
- No telemetry or tracking
- Sensitive legal details may be extractable from device backups

---

## Future Considerations

### Planned Improvements
1. **Abstention Model:** Detect out-of-scope queries (tax, privacy, labor) with high confidence
   - Logistic regression on E5 features (frozen encoder)
   - Development set prepared; awaiting legal review

2. **Model Updates:** BGE-M3 encoder screening complete but not deployed
   - Requires re-calibration of cosine gates
   - Needs independent heldout validation

3. **Performance Profiling:** Device startup, memory peak, inference latency not yet measured

4. **Quantization:** Dynamic int8 quantization tested in lab (parity maintained)
   - Not deployed; would reduce model from 470 MB to ~120 MB

### Known Limitations
1. **Retrieval limitations:**
   - No support for complex legal reasoning or applicability analysis
   - Cosine gates are heuristic; off-topic probes may slip through
   - No-match cases still returning articles (53% false-positive rate on heldout)

2. **Training data:**
   - 46 development queries (sparse labels)
   - 27 heldout positive + 15 no-match cases (provisional review)
   - No independent, lawyer-reviewed gold-standard test set

3. **UX:**
   - Map preview fixed to one area; does not update with user location or search
   - Passage evidence is similarity-based, not a rule-application tool

---

## Running the App

### Development
```bash
# Analyze code
flutter analyze

# Run tests
flutter test

# Run on device (debug)
flutter run

# Build APK
flutter build apk --debug --dart-define-from-file=env.json
```

### Configuration (Optional Gemini Follow-Up)
```json
// env.json
{
  "CATALYST_API_URL": "https://catalyst-proxy.<user>.workers.dev",
  "CATALYST_API_TOKEN": "<APP_TOKEN>"
}
```

Without this, follow-up uses on-device fallback.

---

## Repository Structure

```
CATALYST/
├── lib/
│   ├── main.dart                          # App entry point
│   ├── landing_screen.dart
│   ├── home_screen.dart
│   ├── user_input_screen.dart
│   ├── processing_screen.dart
│   ├── match_results_screen.dart
│   ├── law_details_screen.dart
│   ├── xai_chatbot_screen.dart
│   ├── history_screen.dart
│   ├── legal_services_screen.dart
│   ├── about_screen.dart
│   ├── map_preview.dart
│   │
│   ├── services/
│   │   ├── catalyst_local_retrieval_service.dart    # Core retrieval
│   │   ├── legal_query_preprocessor.dart            # Query preprocessing
│   │   ├── local_tokenizer.dart                     # Tokenization
│   │   ├── lexical_index.dart                       # BM25 indexing
│   │   ├── explanation_builder.dart                 # Passage evidence
│   │   ├── jurisprudence_service.dart               # Case lookup
│   │   ├── case_conversation.dart                   # Chat context
│   │   ├── followup_service.dart                    # Online/offline Q&A
│   │   ├── history_store.dart                       # Local storage
│   │   ├── connectivity_service.dart                # Network check
│   │   ├── query_analysis.dart                      # Domain detection
│   │   └── explanation_language.dart                # Display text
│   │
│   ├── models/
│   │   ├── history_entry.dart
│   │   └── law_match_result.dart
│   │
│   └── data/
│       ├── mock_history_entries.dart
│       ├── mock_law_match_results.dart
│       └── mock_xai_chat_content.dart
│
├── assets/
│   ├── models/
│   │   ├── catalyst_encoder_e5.onnx                 # 470 MB
│   │   └── e5_tokenizer.json                        # 17 MB
│   │
│   ├── data/
│   │   ├── legal_articles.json                      # Corpus metadata
│   │   ├── chunk_embeddings_e5.f32                  # Embedding matrix
│   │   ├── chunk_owners_e5.json                     # Mappings
│   │   ├── training_query_embeddings_e5.f32         # Training vectors
│   │   ├── training_query_labels_e5.json            # Training labels
│   │   └── jurisprudence.json                       # Cases
│   │
│   ├── images/                                      # UI assets
│   └── fonts/                                       # Custom fonts
│
├── backend/
│   ├── worker.js                                    # Cloudflare Worker
│   ├── worker.test.mjs
│   ├── wrangler.toml                                # Worker config
│   └── README.md
│
├── tool/
│   ├── retrieval_lab/                               # Retrieval experiments
│   │   ├── export_training_query_index.py
│   │   ├── finetune_sbert.py
│   │   ├── sbert_console.py
│   │   ├── screen_multilingual_models.py
│   │   └── ...
│   │
│   └── offline_eval/                                # Heldout evaluation
│       ├── offline_eval_test.dart
│       ├── export_heldout_cases.py
│       └── ...
│
├── test/                                            # Unit tests
├── integration_test/                                # Integration tests
├── docs/                                            # Architecture docs
├── pubspec.yaml                                     # Dependencies
└── README.md
```

---

## Summary

CATALYST is a **locally-executed legal retrieval system** combining:
- **UI Layer:** Flutter material design screens
- **Retrieval Core:** Hybrid ranking (dense E5 + BM25 + supervised signals)
- **Storage:** On-device history with bookmarks
- **Optional Online:** Cloudflare Worker proxy for Gemini follow-up (with graceful fallback)

All article retrieval, evidence generation, and core functionality runs **entirely on-device** without internet. The optional XAI follow-up can use a backend proxy if configured, but seamlessly falls back to on-device similarity-based answers.

This architecture prioritizes **privacy, offline usability, and transparency** about the system's capabilities and limitations.
