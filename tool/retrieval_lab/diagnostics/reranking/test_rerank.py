import unittest
from types import SimpleNamespace

import numpy as np

from correct_boundaries import corrected_logits
from final_optimization import final_ids
from rerank import MAX_LENGTH, CrossEncoder, metrics, ranked, windows


class RerankTest(unittest.TestCase):
    def test_long_document_windows_cover_all_tokens(self):
        query = [17] * 200
        document = list(range(1000, 1800))
        pairs = windows(query, document)
        self.assertGreater(len(pairs), 1)
        self.assertTrue(all(len(pair) <= MAX_LENGTH for pair in pairs))
        recovered = set(token for pair in pairs for token in pair if token >= 1000)
        self.assertEqual(recovered, set(document))
        self.assertEqual(pairs[-1][-1], 2)

    def test_direct_and_hybrid_blend_use_only_requested_candidates(self):
        candidates = [
            {"id": "a", "hybridScore": 0.9},
            {"id": "b", "hybridScore": 0.4},
            {"id": "c", "hybridScore": 0.1},
        ]
        logits = [-4.0, 3.0, 9.0]
        self.assertEqual(ranked(candidates, logits, 2, 1.0), ["b", "a"])
        self.assertEqual(ranked(candidates, logits, 2, 0.25), ["a", "b"])
        self.assertEqual(ranked([], [], 30, 1.0), [])
        with self.assertRaises(ValueError):
            ranked(candidates, logits[:2], 2, 1.0)

    def test_metrics_use_all_relevant_labels(self):
        record = {
            "datasetId": "case",
            "relevant": ["a", "b"],
            "pool50": {
                "candidates": [
                    {"id": "a", "hybridScore": 0.9},
                    {"id": "b", "hybridScore": 0.8},
                    {"id": "c", "hybridScore": 0.7},
                ],
                "logits": [0.0, 1.0, 2.0],
            },
        }
        result = metrics([record], "pool50", 3, 1.0)
        self.assertEqual((result["hitAt1"], result["hitAt3"], result["hitAt15"]), (0, 1, 1))
        self.assertAlmostEqual(result["precisionAt3"], 2 / 3)

    def test_batch_boundary_correction_matches_scoring_cutoff(self):
        class Tokenizer:
            def encode(self, text, *, add_special_tokens):
                if text == "query":
                    return SimpleNamespace(ids=[7, 8])
                index = int(text)
                return SimpleNamespace(ids=[index + 10] * (300 if index == 6 else 3))

        class Session:
            def run(self, outputs, inputs):
                rows = inputs["input_ids"].sum(axis=1).astype(float)
                return [(rows + rows.sum() * 0.01).reshape(-1, 1)]

        fake = SimpleNamespace(tokenizer=Tokenizer(), session=Session())
        candidates = [
            {"id": str(i), "text": str(i), "hybridScore": 0.5}
            for i in range(12)
        ]
        original, _, _ = CrossEncoder.score(fake, "query", candidates)
        item = {"candidates": candidates, "logits": original}
        for count in (6, 7, 9, 12):
            expected, _, _ = CrossEncoder.score(fake, "query", candidates[:count])
            self.assertEqual(corrected_logits(fake, "query", item, count), expected)

    def test_document_token_cache_preserves_scores_and_reuses_encoding(self):
        class Tokenizer:
            def __init__(self):
                self.calls = []

            def encode(self, text, *, add_special_tokens):
                self.calls.append(text)
                return SimpleNamespace(ids=[5, 6] if text == "query" else [9, 10])

        class Session:
            def run(self, outputs, inputs):
                return [inputs["input_ids"].sum(axis=1).reshape(-1, 1)]

        tokenizer = Tokenizer()
        fake = SimpleNamespace(tokenizer=tokenizer, session=Session())
        candidates = [{"id": "a", "text": "article", "hybridScore": 0.5}]
        uncached, _, _ = CrossEncoder.score(fake, "query", candidates)
        cache = {}
        first, _, _ = CrossEncoder.score(fake, "query", candidates, cache)
        second, _, _ = CrossEncoder.score(fake, "query", candidates, cache)
        self.assertEqual(uncached, first)
        self.assertEqual(first, second)
        self.assertEqual(tokenizer.calls.count("article"), 2)

    def test_short_cutoff_retains_unreranked_top_15_tail(self):
        candidates = [
            {"id": str(i), "hybridScore": 0.5} for i in range(20)
        ]
        result = final_ids({"candidates": candidates}, [0.0] * 10, 10)
        self.assertEqual(result, [str(i) for i in range(15)])


if __name__ == "__main__":
    unittest.main()
