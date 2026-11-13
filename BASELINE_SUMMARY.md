# CATALYST Baseline Review - Executive Summary

**Date:** 2026-11-13  
**Status:** Baseline established & pushed to GitHub  
**Repository:** student-jksuyom/CATALYST  

---

## 📊 At a Glance

| Dimension | Status | Score |
|-----------|--------|-------|
| **Architecture Quality** | ✅ Solid | 8.5/10 |
| **Test Coverage** | ✅ Good | 8.0/10 |
| **Retrieval Accuracy** | ❌ Critical | 2.5/10 |
| **Production Readiness** | ❌ Blocked | 3.0/10 |
| **Device Performance** | ⚠️ Unknown | N/A |
| **Code Quality** | ✅ Good | 8.0/10 |

---

## 🎯 Key Findings

### 1. SYSTEM IS SOUND, BUT RETRIEVAL IS BROKEN

**Strengths:**
- ✅ Well-architected with clear separation: on-device retrieval → optional online rerank
- ✅ 124 passing Flutter tests + 5 Worker tests (mocked)
- ✅ Robust fallback paths for network failures, malformed data, timeouts
- ✅ Grounded explanations: no hallucination, all answers cite bundled corpus
- ✅ Reproducible evaluation with Python tooling and multiple test sets
- ✅ Multilingual support (E, Tagalog, Taglish) with glossary expansion

**Critical Weakness:**
- 🔴 **Retrieval recall is dangerously low**
  - Hit@1: 8-26%
  - Hit@3: 17-41%
  - Hit@15: 33-59%
  - **Users will frequently get NO relevant results**

### 2. PERFORMANCE METRICS

#### Pilot Test (12 queries)
```
Hit@1  = 1/12  (8.3%)   ← Top article rarely matches
Hit@3  = 2/12  (16.7%)  ← Even top 3 usually miss
Hit@15 = 4/12  (33.3%)  ← Only 33% have relevant in first 15
```

#### Independent Heldout (42 cases, retrieval-positive only)
```
English (9):   Hit@3 = 6/9  (67%)   MRR@15 = 0.583
Tagalog (9):   Hit@3 = 3/9  (33%)   MRR@15 = 0.320
Taglish (9):   Hit@3 = 2/9  (22%)   MRR@15 = 0.185
------
Average:       Hit@3 = 11/27 (41%)   MRR@15 = 0.363
```

**Language Disparity:** English 2x better than Tagalog/Taglish

#### Out-of-Scope False Positives
```
15/42 cases had no catalogue match
System returned results for ALL 15 (100% false positive rate)
Quality Gate Status: ❌ FAIL
```

### 3. ROOT CAUSES

**Why is recall so low?**

1. **Weak off-topic filtering**
   - 0.79 cosine gate is coarse; returns results for "random text"
   - System cannot distinguish legal from non-legal queries

2. **Possible E5 limitation for Philippine legal domain**
   - E5 trained on general web text, not legal
   - May not capture domain-specific terminology or context

3. **Missing query understanding**
   - No query expansion, stemming, or semantic augmentation
   - Evaluation labels sparse (many unlabeled articles may be relevant)
   - 0.15 BM25 weight may be suboptimal

4. **Corpus coverage**
   - Only 3 laws (Civil, Family, Consumer)
   - 36% of heldout cases had no valid catalogue match
   - Labor Code, Penal Code, etc. missing

### 4. CRITICAL BLOCKERS

| Issue | Severity | Impact |
|-------|----------|--------|
| Low retrieval recall | 🔴 Critical | Core feature doesn't work |
| Worker broken (401 auth) | 🔴 Critical | Online mode unavailable |
| No persistence | 🔴 Critical | History/bookmarks lost on close |
| Device perf unknown | 🔴 Critical | May not run on target hardware |
| Python deps missing | 🟡 High | Tooling scripts fail |
| App ID placeholder | 🟡 High | Won't pass store review |

### 5. WHAT'S WORKING WELL

✅ **On-Device Retrieval Engine**
- E5-small ONNX (470 MB, FP32)
- Chunk embeddings (6.7 MB)
- Chunk-to-article mapping (20 KB)
- Training query index (280 KB vectors + 15 KB labels)

✅ **Rank Fusion**
- Reciprocal rank fusion (k=20, pool=50)
- 85% dense + 15% BM25 blend
- Training query voting (30% weight cap)
- Configurable weights and thresholds

✅ **Multilingual Support**
- E5 multilingual encoder handles 3 languages
- Glossary expansion (legal term mappings)
- ML Kit language ID and optional translation

✅ **Fallback Paths**
- Timeouts → on-device
- 401 auth → on-device
- Malformed JSON → on-device
- Oversize response → on-device
- All paths tested, all work

✅ **Grounded Conversation**
- No hallucination: answers cite only bundled articles/cases
- Follow-up questions validated against corpus
- Jurisprudence linking (44 SC cases)

---

## 🛣️ Path to Production (8-Week Roadmap)

### Phase 1: Immediate (Weeks 1-2)

1. **Fix Worker token issue**
   ```bash
   node backend/diagnose.mjs direct
   # Redeploy with correct GEMINI_API_KEY
   # Add per-request caching & retry backoff
   ```
   - Target: Online mode working with <2% error rate

2. **Expand evaluation labels**
   - Current: 12 (pilot) + 46 (dev) + 42 (heldout, provisional)
   - Target: 100+ with second lawyer review
   - Creates independent final test for future candidates

3. **Profile on device**
   - Android: latency, memory peak, startup time
   - Compare vs targets (e.g., <2s latency, <500 MB peak RAM)
   - Decide quantization strategy (FP32 → INT8?)

**Expected Outcome:** Worker fixed, device constraints known, robust evaluation baseline

### Phase 2: Short-Term (Weeks 3-4)

4. **Systematically improve recall**
   - A/B test cosine gate: 0.79 → 0.75 / 0.70 / 0.65
   - A/B test BM25 weight: 0.15 → 0.20 / 0.25
   - Analyze 8 pilot queries with zero recall
   - Implement query expansion (synonyms, lemmatization)
   - Target: Hit@3 ≥30-35% on heldout

5. **Implement persistence layer**
   - Replace mock history with SQLite/Hive
   - Persist: search query, results, timestamp, bookmarked articles
   - Add clear/delete controls
   - Migration: history → persistent storage

6. **Create Python `requirements.txt`**
   - Audit all scripts for dependencies
   - Test Python 3.13/3.14 compatibility
   - Document tool entry points

**Expected Outcome:** Recall improved, history persisted, tooling documented

### Phase 3: Medium-Term (Weeks 5-8)

7. **Expand corpus**
   - Survey user concerns outside current scope
   - Prioritize laws by frequency (Labor, Penal, etc.)
   - Re-embed with E5
   - Measure recall improvement

8. **Finalize for release**
   - Change app ID: `com.example.catol` → `com.catalyst.legal`
   - Rotate Gemini key to server-side proxy
   - Prepare Play Store metadata
   - Add legal disclaimers, terms of service

9. **Evaluate alternative encoders (if needed)**
   - If E5 recall remains <30%, evaluate BGE-M3
   - Proper calibration with independent test set
   - Mobile latency/memory validation
   - **Only** if on independent test set

**Expected Outcome:** Release-ready APK, corpus expanded, legal compliance ready

---

## 📋 Success Criteria (Production Readiness Checklist)

### Must-Have (Blocking) ✅

- [ ] Hit@3 ≥40% on independent test set (currently 17-41%)
- [ ] Online mode working, <2% error rate (currently broken)
- [ ] Device latency <3s, memory <500 MB peak (currently unknown)
- [ ] Persistent history & bookmarks (currently mock)
- [ ] Second lawyer review on evaluation labels (currently provisional)
- [ ] App ID changed, Gemini key rotated (currently exposed)

### Should-Have (High Priority) ⚠️

- [ ] 100+ labeled evaluation cases (currently 42 + 46 dev)
- [ ] FP32 → INT8 quantization if device constraints require
- [ ] Off-topic detection ≥80% false positive reduction
- [ ] Expanded corpus (≥5 laws, currently 3)

### Nice-to-Have (Enhancement) 🎯

- [ ] BGE-M3 integration with full pipeline validation
- [ ] User telemetry (queries, relevance feedback)
- [ ] iOS launch parity
- [ ] Multi-turn case conversation UI

---

## 💡 Key Insights

### 1. Retrieval is the Bottleneck, Not Architecture

The system is well-built, but it doesn't do what it's supposed to do: find relevant legal articles. This is **not** a simple fix (better error handling, UI polish, etc.). It's a **fundamental accuracy problem** that requires:

- More labeled data (100+, not 12)
- Proper calibration (gate tuning, weight optimization)
- Better domain understanding (query expansion, corpus coverage)
- Possibly a different or fine-tuned encoder (BGE-M3, domain-specific SBERT)

### 2. Don't Ship Without Fixing Low Recall

Shipping with Hit@3 = 17-41% means:
- **50-75% of searches return no relevant results**
- Users will lose trust immediately
- Negative reviews: "App doesn't work"

### 3. Independent Test Set is Non-Negotiable

The heldout set is provisional (apprentice review, needs second lawyer review). Until you have a lawyer-reviewed, independent test set:
- **Cannot claim accuracy**
- Cannot compare encoder candidates fairly
- Cannot prove production readiness

### 4. Device Performance Must Be Measured

Currently unknown:
- Startup time (does ONNX load in <5s?)
- Memory peak (470 MB ONNX + 750 MB APK = concern)
- Search latency on Android 10 / older phones
- Inference time on CPU only

**This must be measured before shipping.**

### 5. Language Disparity is Real

English: Hit@3 = 67%  
Tagalog: Hit@3 = 33%  
Taglish: Hit@3 = 22%

**E5 may need domain-specific fine-tuning for Tagalog/Taglish.** Current multilingual model not sufficient.

---

## 📁 What's Tracked in Baseline

**Code:** 203 primary files + 74 baseline changes  
**Tests:** 124 Flutter + 5 Worker (all passing)  
**Data:**
- 2,700 legal articles (JSON)
- 44 jurisprudence cases (JSON)
- 182 labeled training queries (E5 embeddings)
- 42 independent heldout cases (provisional labels)

**Tooling:**
- Python scripts for corpus processing, embeddings, evaluation
- Offline eval harness with hit rates, MRR, precision/recall
- Controlled fine-tuning experiments (MiniLM, BGE-M3 screens)
- Config validation, dimension checks, norm verification

**Documentation:**
- Hybrid retrieval architecture (hybrid_retrieval.md)
- Technology inventory (technology_inventory.md)
- Retrieval training experiments (retrieval_training_experiments.md)
- Status report (catalyst_status_report.md)
- **NEW:** Comprehensive baseline review (BASELINE_REVIEW.md)

---

## 🚀 Next Action Items (Priority Order)

1. **TODAY:** Review this baseline report with team
2. **WEEK 1:**
   - Fix Worker (token + caching)
   - Set up device profiling
   - Plan evaluation expansion (100+ labels, lawyer review)
3. **WEEK 2-3:**
   - Measure device latency/memory
   - Begin gate tuning experiments
   - Expand evaluation labels
4. **WEEK 4-6:**
   - Implement persistence
   - Improve recall to target ≥35%
   - Expand corpus (prioritize Labor Code)
5. **WEEK 7-8:**
   - Release prep (app ID, key rotation, disclaimer)
   - Final legal review
   - Play Store submission

---

## 📞 Questions to Answer Immediately

1. **For Product Owner:**
   - What's the target Hit@3 accuracy for MVP?
   - Which laws are highest priority (beyond Civil/Family/Consumer)?
   - Budget for lawyer to review 100+ labels?

2. **For Engineering:**
   - Can we deploy quantized INT8 encoder?
   - What's the target device latency/memory?
   - Server-side proxy ready for Gemini key?

3. **For Legal/Compliance:**
   - Disclaimer language for "research tool, not legal advice"?
   - What must be in terms of service?
   - Jurisdiction restrictions?

---

## Summary

**CATALYST is architecturally solid and well-tested, but cannot ship in current form due to low retrieval accuracy.** With focused work over 4-6 weeks, production readiness is achievable:

1. Fix broken Worker
2. Expand and properly review evaluation labels
3. Measure device performance
4. Systematically improve recall (gate tuning, query expansion, corpus coverage)
5. Implement persistent storage
6. Finalize for release (app ID, keys, disclaimers)

The foundation is strong. Now refine the signal.

---

**Review completed:** 2026-11-13  
**Baseline commit:** a691918  
**Review commit:** 1b83f40  
**All changes pushed to:** https://github.com/student-jksuyom/CATALYST  
