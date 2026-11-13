# CATALYST Baseline Performance & Specifications Review

*Generated: 2026-11-13*

## Executive Summary

CATALYST is a Flutter-based legal research application targeting Philippine law, currently at a critical development junction. The system is **architecturally sound** with clear separation of concerns and solid fallback paths, but **retrieval accuracy remains the primary blocker** for production readiness. The baseline establishes a functional prototype with extensive tooling and a comprehensive evaluation framework, though deployment and device performance remain unmeasured.

---

## 1. PROJECT SPECIFICATIONS

### 1.1 Core Mission
- **Purpose:** Mobile application for retrieving Philippine legal articles relevant to user concerns
- **Target Audience:** Filipino citizens seeking legal information
- **Scope:** Civil Code (2,270 articles), Family Code (257 articles), Consumer Act (173 articles) = 2,700 total
- **Jurisprudence:** 44 Supreme Court cases bundled for reference
- **Languages:** English, Tagalog, Taglish (mixed Filipino-English)
- **Architecture:** On-device retrieval + optional online reranking fallback

### 1.2 Technical Stack

| Component | Technology | Version | Status |
|-----------|-----------|---------|--------|
| **Frontend** | Flutter | 3.47.6 | ✓ Working |
| **Language** | Dart | ^3.13.5 | ✓ Working |
| **Dense Retrieval** | multilingual-e5-small (ONNX FP32) | 470 MB | ✓ Working (device untested) |
| **Tokenizer** | SentencePiece | e5 config | ✓ Working |
| **Sparse Retrieval** | Custom BM25 | k1=1.2, b=0.75 | ✓ Working |
| **Vector DB** | In-memory float32 matrix | 6.7 MB | ✓ Working |
| **UI Framework** | Material 3 | Latest | ✓ Working |
| **Online Backend** | Cloudflare Workers | ES modules | ⚠️ Broken (401 auth) |
| **LLM** | Google Gemini | 3.5/3.6/3.8 Flash | ⚠️ Untested |
| **Persistence** | JSON assets | Local only | ⚠️ Not Implemented |

### 1.3 Application Screens

| Screen | Purpose | Status |
|--------|---------|--------|
| Landing | App intro & login | ✓ Working |
| Home | Search entry & menu | ✓ Working |
| Processing | Loading state | ✓ Working |
| Results | Top 3 + other candidates | ✓ Working |
| Law Details | Article + evidence + chat | ✓ Working |
| History | Search history (mock data) | ⚠️ Mock only |
| Chat (XAI) | Follow-up questions | ✓ Working |
| About | App information | ✓ Working |
| Services Map | Google Maps integration | ⚠️ Preview only |

---

## 2. BASELINE PERFORMANCE METRICS

### 2.1 Retrieval Accuracy (12-Query Pilot)

**Test Set:** 12 labeled queries (3 English, 6 Tagalog, 3 Taglish)  
**Evaluation Metric:** Can system find a labeled relevant article?

| Metric | Value | Assessment |
|--------|-------|------------|
| **Hit@1** | 1/12 (8.3%) | 🔴 Critical |
| **Hit@3** | 2/12 (16.7%) | 🔴 Critical |
| **Hit@15** | 4/12 (33.3%) | 🔴 Critical |
| **Recall (40 candidates)** | 4/12 (33.3%) | 🔴 Article not in pool |
| **Precision@3** | 0.056 (6.7 per query) | 🔴 Very Low |

### 2.2 Independent Heldout Test (42 Cases)

**Status:** Provisional (apprentice-reviewed, NEEDS_SECOND_REVIEW)  
**Dataset:** 42 narratives (14 English, 14 Tagalog, 14 Taglish)

#### Retrieval-Positive Cases (27/42)

| Metric | Count | Rate |
|--------|-------|------|
| Hit@1 | 7/27 | 25.9% |
| Hit@3 | 11/27 | 40.7% |
| Hit@15 | 16/27 | 59.3% |
| MRR@15 | 0.363 | - |

**Language Breakdown (Retrieval-Positive Only):**

| Language | Hit@1 | Hit@3 | Hit@15 | MRR@15 | Cases |
|----------|-------|-------|--------|--------|-------|
| English | 4/9 | 6/9 | 7/9 | 0.583 | 9 |
| Tagalog | 2/9 | 3/9 | 6/9 | 0.320 | 9 |
| Taglish | 1/9 | 2/9 | 3/9 | 0.185 | 9 |

#### No-Catalogue-Match Cases (15/42)

| Issue | Count | Rate |
|-------|-------|------|
| False positive retrievals | 15/15 | 100% |
| **Quality Gate Status** | ❌ FAIL | - |

**Interpretation:** System returns results even for 15 out-of-scope cases, indicating weak off-topic detection.

### 2.3 Development Dataset Evaluation (46 Positive Groups)

**Dataset:** Project's Evaluation Dataset  
**Status:** Provisional, used during development, NOT independent

| Metric | Production E5 Hybrid | MiniLM (Best - Epoch 10) | BGE-M3 (Dense Only) |
|--------|---------------------|------------------------|--------------------|
| Hit@1 | 11/46 (23.9%) | 4/46 (8.7%) | 7/46 (15.2%) |
| Hit@3 | 16/46 (34.8%) | 8/46 (17.4%) | 14/46 (30.4%) |
| Hit@15 | 20/46 (43.5%) | N/A | 24/46 (52.2%) |
| MRR@15 | 0.304 | 0.141 | 0.247 |

**Key Finding:** Production E5 hybrid still leads on development data. Alternative encoders (BGE-M3, fine-tuned MiniLM) did not improve results in isolated testing.

### 2.4 Applicability Judgments (Independent Heldout)

| Category | Count |
|----------|-------|
| APPLIES | 3 |
| POSSIBLY_APPLIES | 19 |
| INSUFFICIENT_FACTS | 5 |
| NO_CATALOGUE_MATCH | 15 |

**Implication:** 19/27 (70%) even of retrieved cases were only "possibly applicable," indicating limitation in evaluating legal applicability (encoding cannot perform fact-to-rule analysis).

---

## 3. SYSTEM ARCHITECTURE & IMPLEMENTATION QUALITY

### 3.1 On-Device Retrieval Pipeline (Production)

```
User Query
    ↓
[Query Analysis] → Glossary expansion (Filipino→English legal terms)
    ↓
[Tokenization] → e5_tokenizer.json, max 128 tokens, add "query: " prefix
    ↓
[E5 Encoder] → ONNX FP32, 384-dim, L2-normalized
    ↓
┌──────────────────────────────────┬─────────────────────────────────┐
│ Dense Score                      │ BM25 Score                      │
│ (query vs chunks)                │ (expanded query)                │
│ Best chunk per article           │ Keyword match                   │
└──────────────────────────────────┴─────────────────────────────────┘
    ↓
[Training Query Neighbor Voting]
    ↓ Query embedding vs 182 labeled training queries
    ↓ Cosine >0.90 → contribute article labels (30% weight max)
    ↓
[Fusion & Scoring]
    ├─ Reciprocal Rank Fusion (k=20, pool=50)
    ├─ Blend: 85% dense + 15% BM25
    ├─ Cosine gate: 0.79 (filters candidates)
    └─ Returns top N candidates
    ↓
[Display with Evidence]
    ├─ Top 3 highlighted
    ├─ Mode banner (on-device/fallback/online)
    ├─ Passage evidence via E5 similarity
    └─ 44 linked jurisprudence cases
```

**Strengths:**
- ✓ Fully offline, no server dependency
- ✓ Deterministic and reproducible
- ✓ Multiple ranking signals (dense, sparse, training-query votes)
- ✓ Robust fallback to on-device mode
- ✓ Clear corpus validation

**Weaknesses:**
- 🔴 Low recall (33% on pilot, 59% on heldout Hit@15)
- 🔴 Weak off-topic detection (0.79 cosine gate is coarse)
- 🔴 0.15 BM25 weight appears sub-optimal
- 🔴 No query expansion or stemming
- ⚠️ Multilingual handling assumes query analysis + ML Kit, both untested on device

### 3.2 Test Coverage

**Flutter Tests:** 124 passing + 1 stale

```
Core Retrieval
  ✓ local_tokenizer_test
  ✓ legal_query_preprocessor_test
  ✓ local_semantic_retrieval_service_test
  ✓ hybrid_retrieval_and_conversation_test

Navigation & Screens
  ✓ production_navigation_test
  ✓ home_screen_test
  ✓ user_input_screen_test
  ✓ match_results_screen_test
  ✓ law_details_screen_test
  ✓ history_screen_test
  ✓ xai_chatbot_screen_test

Online Fallback
  ✓ HTTP errors, timeouts, malformed JSON
  ✓ 401 auth failure
  ✓ Response oversized

Jurisprudence & Follow-up
  ✓ jurisprudence_followup_test
  ✓ query_scope_test
  ✓ explanation_language_test

Backend (Worker)
  ✓ 5 Node tests (mocked Gemini)

⚠️ Gaps
  ✗ Real Gemini integration test
  ✗ On-device latency/memory measurement
  ✗ Real-time performance under load
  ✗ Multi-language codec tests
```

### 3.3 Code Quality

| Aspect | Status | Notes |
|--------|--------|-------|
| **Separation of Concerns** | ✓ Excellent | Clean service layer, no cross-cutting logic |
| **Error Handling** | ✓ Good | Fallbacks tested, graceful degradation |
| **Navigation** | ✓ Good | Production nav test covers major flows |
| **State Management** | ⚠️ Minimal | No provider/bloc; history is mock data |
| **Comments** | ✓ Appropriate | Minimal but clear where needed |
| **Type Safety** | ✓ Good | Dart null-safety enabled |

---

## 4. KNOWN ISSUES & BLOCKERS

### Critical 🔴

1. **Online Mode Broken**
   - Worker deployed but returns 401 on token auth
   - Gemini quota limits unconfirmed (free tier, per-minute, per-day?)
   - Multi-call amplification: 3 calls per search, 4 per follow-up (no caching)
   - **Impact:** Online reranking unavailable; app falls back to on-device
   - **Fix:** Redeploy Worker with corrected token, add caching & retry backoff

2. **Low Retrieval Recall**
   - Hit@3: 17-40% across datasets
   - Only 33% of queries have relevant article in top 15 candidates
   - **Impact:** Many valid user concerns return no relevant results
   - **Root Causes:**
     - Weak off-topic filtering (returns results for "random text")
     - 0.79 cosine gate too permissive or ranking fundamentally misses domain
     - Missing query expansion, stemming, or semantic query augmentation
     - Evaluation labels sparse; many unlabeled articles may be relevant
   - **Fix:** Expand labeled evaluation set (target 100+), tune gate, improve query understanding, consider BGE-M3 with proper calibration

3. **No Persistence**
   - History screen shows mock data
   - Search history not saved to device
   - Bookmarks lost on app close
   - **Impact:** Users cannot persist results between sessions
   - **Fix:** Implement `HistoryStore` database backend (SQLite or Hive)

### Significant ⚠️

4. **Unmeasured Device Performance**
   - No latency/memory/startup measurements on physical Android/iOS
   - FP32 ONNX encoder is 470 MB; debug APK ~750 MB
   - **Impact:** Unknown if deployment meets production constraints
   - **Fix:** Profile on target devices; quantize to INT8 if needed

5. **Missing Python Dependency Manifest**
   - `requirements.txt` not provided
   - `sentence_transformers`, `pandas` not installed in venv
   - Python 3.14 compatibility unconfirmed
   - **Impact:** Reproduction and tooling scripts may fail
   - **Fix:** Create `requirements.txt`, test Python 3.13/3.14 compatibility

6. **Translation Dependency Not Validated**
   - ML Kit models downloaded on demand (~60 MB per language)
   - No offline translation fallback
   - Measured benefit is zero (Hit@3 same with/without translation)
   - **Impact:** Fresh installs have degraded experience; unnecessary dependency
   - **Fix:** Remove translation from retrieval pipeline or make it optional

7. **Corpus Scope Limited**
   - Only 3 laws (Civil, Family, Consumer); Labor Code, Penal Code missing
   - Many user concerns fall outside scope (no catalogue match)
   - **Impact:** 15/42 (36%) of independent heldout cases return irrelevant results
   - **Fix:** Expand corpus or add clear out-of-scope messaging

### Housekeeping

8. **App ID is Placeholder**
   - `com.example.catol` will not pass Play Store/App Store review
   - **Fix:** Change to `com.catalyst.legal` or similar before release

9. **Token Embedded in APK**
   - `env.json` contains Gemini API key
   - Deters casual abuse only; production keys should use server-side proxy
   - **Fix:** Rotate key, use backend authentication

10. **No Git History**
    - Just established baseline; earlier work is now committed
    - `.venv/` needs to be gitignored (already done)
    - **Fix:** None needed; baseline now established

---

## 5. STRENGTHS & SOLID FOUNDATIONS

✓ **Clear Architecture**
- On-device retrieval fully separated from optional online reranking
- Fallback paths well-tested
- Service layer cleanly organized

✓ **Reproducible Evaluation**
- Offline eval harness with Python tooling
- Labeled datasets (training, evaluation, heldout)
- Controlled experiments (MiniLM fine-tuning, BGE-M3 screen)

✓ **Comprehensive Retrieval Pipeline**
- Multiple ranking signals (dense, sparse, training-query votes)
- Rank fusion with configurable weights
- Chunk-level embeddings for fine-grained matching

✓ **Multi-Language Support**
- E5 multilingual encoder
- Glossary-based keyword expansion
- Three languages tested (English, Tagalog, Taglish)

✓ **Grounded Explanations**
- No hallucination: answers cite only supplied articles/cases
- Plain-language templates in 3 languages
- Follow-up questions validated against corpus

---

## 6. PRIORITIZED RECOMMENDATIONS

### Immediate (Weeks 1-2)

1. **Fix Worker token issue**
   - `node backend/diagnose.mjs direct` to verify
   - Redeploy with corrected `GEMINI_API_KEY`
   - Measure Gemini quota errors and add per-request caching

2. **Expand evaluation set**
   - Current: 12 pilot + 46 dev + 42 heldout (provisional)
   - Target: 100+ with second lawyer review
   - Unlock independent final test for future candidates

3. **Measure device performance**
   - Android: latency, memory, startup time
   - Compare against target (e.g., <2s latency, <500 MB RAM peak)
   - Decide INT8 quantization priority

### Short-term (Weeks 3-4)

4. **Improve recall**
   - Analyze 8 pilot queries with no relevant candidate
   - A/B test cosine gate (0.79 → 0.75/0.70?)
   - A/B test BM25 weight (0.15 → 0.20/0.25?)
   - Consider query expansion (synonyms, lemmatization)

5. **Implement persistence**
   - Replace mock history with SQLite/Hive
   - Persist bookmarks, search history, timestamp
   - Add clear/delete controls in history screen

6. **Implement Python `requirements.txt`**
   - Audit all scripts for dependencies
   - Test Python 3.13/3.14 compatibility
   - Document tool entry points

### Medium-term (Weeks 5-8)

7. **Expand corpus**
   - Survey user concerns not in scope
   - Prioritize laws (Labor, Penal, etc.)
   - Measure recall improvement

8. **Finalize release config**
   - Change app ID to `com.catalyst.legal`
   - Rotate Gemini key to server-side proxy
   - Prepare Play Store/App Store metadata

9. **Candidate encoder evaluation**
   - If E5 recall remains <40%, evaluate BGE-M3
   - Proper calibration with independent test set
   - Mobile latency/memory validation

---

## 7. RISK MATRIX

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Worker remains broken at launch | Medium | Critical | Fix + test before release |
| Recall stays low (Hit@3 <25%) | High | Critical | Expand corpus, tune gate, improve query analysis |
| Device won't run ONNX on older phones | Medium | High | Quantize FP32→INT8, profile on target hardware |
| Users expect legal advice; app gives info only | High | Medium | Clear disclaimers, terms, limit explanation scope |
| Corpus update breaks embeddings | Low | High | Version corpus hash, validate on load |
| Python scripts unmaintainable | Medium | Low | Add `requirements.txt`, document entry points |

---

## 8. SUCCESS CRITERIA FOR PRODUCTION READINESS

### Must-Have ✓

- [ ] Hit@3 retrieval ≥40% on independent test set
- [ ] Online mode working with <2% error rate
- [ ] Device latency <3s per search on target hardware
- [ ] Persistent history/bookmarks
- [ ] Fixed app ID, rotated keys
- [ ] Second lawyer review on evaluation labels

### Should-Have ⚠️

- [ ] 100+ labeled evaluation cases
- [ ] FP32→INT8 quantization (reduce size)
- [ ] Off-topic detection rate ≥80%
- [ ] Expanded corpus (≥5 laws)

### Nice-to-Have

- [ ] BGE-M3 encoder with full pipeline validation
- [ ] User telemetry (queries, relevance feedback)
- [ ] Multi-turn case conversation
- [ ] iOS launch parity

---

## 9. CONCLUSION

CATALYST demonstrates solid engineering fundamentals with a well-architected retrieval system, comprehensive test coverage, and extensive evaluation tooling. The codebase is clean, the fallback paths are robust, and the vision is clear.

**However, retrieval accuracy remains the primary blocker.** Current Hit@3 of 17-40% is insufficient for production; users will frequently encounter searches with no relevant results. This is not a simple tuning problem—it reflects either a fundamental architectural limitation (0.79 cosine gate too strict or E5 insufficient for legal domain) or missing domain knowledge (query expansion, stopword handling, corpus coverage).

**Immediate path forward:**
1. Fix the broken Worker (online mode)
2. Expand and properly review evaluation labels (100+, lawyer-reviewed)
3. Profile on device hardware
4. Systematically improve recall via gate tuning, query expansion, corpus expansion
5. Only then pursue new encoders (BGE-M3) after establishing independent test set

With focused effort on recall and persistent storage, CATALYST can reach production readiness in 4-6 weeks. The foundation is solid; now scale and refine the signal.
