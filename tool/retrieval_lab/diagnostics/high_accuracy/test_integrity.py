import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from export_training_query_index import _index_articles


class ArticleIndexTest(unittest.TestCase):
    def test_colliding_citations_are_rejected(self):
        articles = [
            {"Law": "CivilCode", "Article": "1596"},
            {"Law": "Civil Code", "Article": "1596"},
        ]
        with self.assertRaisesRegex(ValueError, "Duplicate normalized article ID"):
            _index_articles(articles)


if __name__ == "__main__":
    unittest.main()
