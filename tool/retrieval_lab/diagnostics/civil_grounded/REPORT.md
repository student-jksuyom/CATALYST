# Civil Code retrieval and grounded answers

## Decision

The production hybrid ranking and 0.80 cosine gate remain unchanged. None of
the tested retrieval changes improved Civil Code Hit@3; several also failed
the existing co-ownership regression. The earlier citation and chunk repairs
remain in place. The active change is deterministic, citation-grounded
conversation output, not a new retrieval model.

Statutory follow-ups now stay on-device even when an online answerer is
configured. Explicit jurisprudence questions retain the existing optional
online path, but its output is labeled unverified and is not guaranteed to be
corpus-grounded. Without a retrieved provision, this path does not call the
online answerer.

## Development results

The same 46 queries and 50 expected labels were evaluated through the Flutter
service with cached E5 query vectors. No labels were changed.

| Fixed configuration | Hit@1 | Hit@3 | Hit@15 | Precision@3 | Civil / Family / Consumer Hit@3 | Co-ownership regression |
|---|---:|---:|---:|---:|---|---|
| Production baseline | 13/46 | 17/46 | 21/46 | 12.32% | 2/23 / 8/13 / 7/10 | Pass |
| Training signal disabled | 4/46 | 6/46 | 14/46 | 4.35% | 0/23 / 3/13 / 3/10 | Pass |
| Experimental concept expansion | 13/46 | 17/46 | 23/46 | 12.32% | 2/23 / 8/13 / 7/10 | Pass |
| Average top two chunk scores | 13/46 | 17/46 | 24/46 | 12.32% | 2/23 / 8/13 / 7/10 | Fail |
| Guarded gate recovery | 13/46 | 17/46 | 21/46 | 12.32% | 2/23 / 8/13 / 7/10 | Pass |
| Term-overlap reranking | 13/46 | 18/46 | 22/46 | 13.04% | 2/23 / 9/13 / 7/10 | Fail |
| Combined experimental changes | 13/46 | 17/46 | 25/46 | 12.32% | 2/23 / 8/13 / 7/10 | Fail |
| Combined, training disabled | 5/46 | 7/46 | 20/46 | 5.07% | 0/23 / 2/13 / 5/10 | Fail |

Baseline and active production accuracy are therefore the same: Hit@3 is
37.0%, not 70%. All six off-topic probes returned no candidates in every
configuration; six probes are not enough to establish false-positive safety.
The experimental synonym list is not lawyer-reviewed. It expands lexical
search and has no article mappings.

The baseline union of the per-source top-50 lists contained at least one
expected label for 34/46 queries and 36/50 labels before gating, and 32/46
queries and 34/50 labels after gating. Civil-only coverage was 12/23 queries
and 13 labels before, versus 11/23 and 12 labels after. Results after the
experiment are unchanged in production. A prior pool-500 experiment found
37/46 queries and 39/50 labels in the gated top 200, but did not improve
Hit@3; the older pre-gate pool-500 figure is not directly comparable.

The service already unions semantic and lexical candidates, uses original and
normalized/glossary query representations, and takes the best chunk per
article. The fixed experiments add lexical concept terms, compare a top-two
chunk average, test guarded gate recovery, and add bounded term overlap.
They do not require new neural inference. Per-query stage lists, cosines,
ranks, results and probe outcomes are in [results.json](./results.json).
Baseline top-15 ordering matched the previously recorded repaired production
results for all 46 queries.

## Dense, lexical and training-example ablations

The actual Flutter service was evaluated on the same 46 development queries,
with the same corpus, cached E5 query vectors, reviewed labels and 50-item
candidate pool. Cross-encoder reranking was disabled for every run. The
baseline uses the selected hybrid weights (BM25 0.15, training examples 0.30,
RRF k=20). When only one corpus retriever is active, it receives the full
corpus weight; training examples receive the full weight when they are the
only active source. The article cosine gate applies only when dense retrieval
is enabled. E5 query encoding is still used for matching training examples
and selecting passage evidence, but article dense scores do not affect
lexical-only ranking. This is a ranking ablation, not a latency comparison.

| Enabled retrieval sources | Hit@1 | Hit@3 | Hit@15 | Precision@3 |
|---|---:|---:|---:|---:|
| Baseline: dense + lexical + training examples | 13/46 | 17/46 | 21/46 | 12.32% |
| Dense only | 2/46 | 5/46 | 15/46 | 3.62% |
| Lexical only | 2/46 | 3/46 | 8/46 | 2.17% |
| Training examples only | 11/46 | 13/46 | 13/46 | 9.42% |
| Dense + lexical | 4/46 | 6/46 | 14/46 | 4.35% |
| Dense + training examples | 12/46 | 16/46 | 20/46 | 11.59% |
| Lexical + training examples | 5/46 | 9/46 | 14/46 | 6.52% |

These are development-set metrics, not independent generalization results.
The six existing negative probes returned results in three cases for lexical
only and lexical + training; the other ablations returned none. The
co-ownership regression passed for the baseline and dense + lexical, and
failed for the other five ablations. These small guardrail sets are not
comprehensive safety evaluations. Full per-query outputs are in
[results.json](./results.json); reproduce with the command below.

## Civil Code failure breakdown

Among the 21 queries without an expected top-three article, categories are
assigned in order: no expected article in the union, expected article in the
union but none survives the gate, or an expected article survives but ranks
below three. Multiple expected labels count as one query.

* **Missing before the gate (11):** CC-EV-001, 004, 008, 011, 012, 015,
  016, 020, 022, 023, 024.
* **Gate rejection (1):** CC-EV-010, expected Civil Code 694, cosine about
  0.778.
* **Ranking (9):** CC-EV-002, 006, 007, 009, 013, 017, 019, 021, 025.
* **Expected top-three hit (2):** CC-EV-005, 014.

Domain inference was unknown for 005, 004, 008, 020 and 021; it returned
Consumer for 011, 013, 015 and 016, and Family for 017 and 022. A different
domain is not proof of misunderstanding: concerns can span codes, and the
current training-query matching is domain-independent. These observations do
not establish a cause for any individual miss.

The integrity regression checks unique citations, ownership and complete
chunk coverage for the packaged corpus; it does not prove that article text,
each expected label, or missing labels are legally correct. The expected
articles exist, but adequacy of the representation and legal applicability
of each label remain unadjudicated. No label was silently corrected.

## Grounded response example

For development case CC-EV-014, about a verbal loan-interest agreement, the
actual local retrieval ranked CivilCode 1956 first and produced:

> CivilCode 1956: "Article 1956. No interest shall be due unless it has been
> expressly stipulated in writing. (1755a)" Possible connection: your concern
> and this provision share wording related to interest. This does not
> establish that the provision applies.

The answer identifies each returned provision and quotes retrieved corpus
text, flags that the corpus may not cover every relevant law, and gives a
legal-information-not-advice notice. Connections are word-overlap clues,
not legal reasoning; unrelated candidates can still appear. Missing provision
text is explicitly reported rather than replaced with a generated claim.
Truncated excerpts do not replace the full article.

## Runtime, validation and limitations

This run measured a 48.91 ms/query mean for the baseline cached-vector service
and a 419.7 MiB peak for the whole Flutter test process. These are Windows
host measurements including diagnostic work and the test harness, excluding
E5 inference, startup and mobile overhead. A prior separate repaired
baseline run measured 92.3 ms/query and 420.4 MiB; different runs and
harness conditions make them unsuitable for claiming a speed or memory
improvement. Conversation-response overhead was not isolated. Android
latency, memory and Flutter ONNX inference on a device remain unverified.

The deterministic conversation path was tested with an injected cached-vector
encoder and no online calls. A prior local Python ONNX smoke test succeeded
offline; this does not prove Android deployment. Targeted retrieval,
conversation, co-ownership, corpus-integrity and jurisprudence tests were run;
the previous full Flutter suite had unrelated widget failures and was not
rerun here.

The development set is small and may have incomplete labels. A prior audit
found a possible near-duplicate between CA-EV-004 and the existing
training-query index. Disabling that index is a leakage-controlled ablation,
not an independent generalization evaluation. Earlier grouped
cross-validation did not rebuild the training index per fold and was not
fully leakage-free. No held-out cases were used or evaluated for this sprint.
Expert-reviewed independent concerns, broader negative probes and device
measurements remain necessary.

## Reproduction

```powershell
flutter test --no-pub tool\retrieval_lab\diagnostics\civil_grounded\experiment_test.dart
flutter test --no-pub test\grounded_conversation_test.dart test\hybrid_retrieval_and_conversation_test.dart test\local_semantic_retrieval_service_test.dart test\coownership_ranking_regression_test.dart test\retrieval_corpus_integrity_test.dart
dart analyze lib\services\case_conversation.dart lib\services\catalyst_local_retrieval_service.dart lib\services\query_analysis.dart test\grounded_conversation_test.dart tool\retrieval_lab\diagnostics\civil_grounded\experiment_test.dart
```

The experiment rewrites its own [results.json](./results.json); timings vary.
It reads the development cases and cached vectors and does not access the
held-out set.
