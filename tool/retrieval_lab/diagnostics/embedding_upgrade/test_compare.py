import unittest

import numpy as np

from compare import evaluate, validate_vectors
from full_hybrid import rank_bge


class ComparisonTest(unittest.TestCase):
    def test_candidate_union_respects_enabled_sources(self):
        case = {
            "variants": ["q"],
            "preemptiveAbstention": False,
        }
        common = (
            case,
            {"q": np.array([1.0, 0.0], dtype=np.float32)},
            np.array([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32),
            np.array([0, 1]),
            [f"article-{index}" for index in range(52)],
            [{"index": 50, "score": 1.0}],
            [{"positive": [51], "negative": []}],
            np.array([[1.0, 0.0]], dtype=np.float32),
        )

        def pre_gate(bm25_weight, train_weight):
            return rank_bge(
                *common,
                train_threshold=0.5,
                train_weight=train_weight,
                bm25_weight=bm25_weight,
                ranking="rank",
                gate=None,
            )["preGate"]

        dense_only = pre_gate(0.0, 0.0)
        self.assertEqual(len(dense_only), 50)
        self.assertNotIn("article-50", dense_only)
        self.assertNotIn("article-51", dense_only)
        self.assertIn("article-50", pre_gate(0.15, 0.0))
        self.assertIn("article-51", pre_gate(0.0, 0.30))

    def test_gate_and_candidate_coverage_use_article_owners(self):
        cases = [
            {
                "datasetId": domain,
                "domain": domain,
                "negative": False,
                "expected": ["article-a"],
                "variants": ["positive"],
                "lexical": [{"index": 1, "score": 2.0}],
                "preemptiveAbstention": False,
            }
            for domain in ("Civil", "Family", "Consumer")
        ] + [
            {
                "datasetId": "negative",
                "domain": None,
                "negative": True,
                "expected": [],
                "variants": ["negative"],
                "lexical": [],
                "preemptiveAbstention": False,
            }
        ]
        result = evaluate(
            cases,
            ["article-a", "article-b"],
            np.array([0, 0, 1]),
            np.array([[0, -1], [1, 0], [0, 1]], dtype=np.float32),
            np.array([[1, 0], [-1, 0]], dtype=np.float32),
            {"positive": 0, "negative": 1},
        )
        self.assertEqual(result["metrics"]["hybrid_gated"]["all"]["hit1"], 3)
        self.assertEqual(result["metrics"]["hybrid_gated"]["all"]["preGateLabels"], 3)
        self.assertEqual(result["metrics"]["hybrid_gated"]["negativeReturned"], 0)
        self.assertEqual(result["metrics"]["hybrid_ungated"]["negativeReturned"], 1)

    def test_invalid_embedding_norm_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "L2-normalized"):
            validate_vectors(np.array([[2, 0]], dtype=np.float32), (1, 2))


if __name__ == "__main__":
    unittest.main()
