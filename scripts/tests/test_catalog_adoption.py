"""What: adoption requires evidence, not a search hit."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.catalog import adoption
from scripts.catalog.discover import SearchHit
from scripts.catalog.http import HttpError
from scripts.catalog.model import ADOPTION, INTEGRATION, REFERENCE

SELF = "f4ah6o/moon-binstall"


class ClassifyTests(unittest.TestCase):
    def test_readme_command_is_adoption(self):
        entry = adoption.classify(
            "f4ah6o/dsh.mbt",
            ("README.md", "Install:\n\n```sh\nmoon binstall f4ah6o/dsh.mbt\n```\n"),
            False,
            [],
            SELF,
        )
        self.assertIsNotNone(entry)
        self.assertEqual(entry.classification, ADOPTION)
        self.assertIn("README.md: moon binstall f4ah6o/dsh.mbt", entry.evidence)

    def test_link_only_is_reference(self):
        entry = adoption.classify(
            "someone/awesome-list",
            ("README.md", "- [moon-binstall](https://github.com/f4ah6o/moon-binstall)\n"),
            False,
            [],
            SELF,
        )
        self.assertIsNotNone(entry)
        self.assertEqual(entry.classification, REFERENCE)

    def test_manifest_is_integration(self):
        entry = adoption.classify("acme/tool", None, True, [], SELF)
        self.assertIsNotNone(entry)
        self.assertEqual(entry.classification, INTEGRATION)
        self.assertEqual(entry.evidence, ["moon-binstall.json"])

    def test_self_repository_is_excluded(self):
        entry = adoption.classify(
            SELF,
            ("README.md", "moon binstall f4ah6o/moon-binstall\n"),
            True,
            [],
            SELF,
        )
        self.assertIsNone(entry)

    def test_workflow_hit_is_adoption(self):
        entry = adoption.classify(
            "acme/tool",
            None,
            False,
            [
                SearchHit(
                    "acme/tool",
                    ".github/workflows/release.yml",
                    '"moon binstall"',
                    "code_search",
                )
            ],
            SELF,
        )
        self.assertIsNotNone(entry)
        self.assertEqual(entry.classification, ADOPTION)

    def test_fixture_workflow_hit_is_ignored(self):
        entry = adoption.classify(
            "acme/tool",
            None,
            False,
            [
                SearchHit(
                    "acme/tool",
                    "tests/fixtures/.github/workflows/release.yml",
                    '"moon binstall"',
                    "code_search",
                )
            ],
            SELF,
        )
        self.assertIsNone(entry)

    def test_no_evidence_is_not_listed(self):
        entry = adoption.classify("acme/tool", None, False, [], SELF)
        self.assertIsNone(entry)


class FakeClient:
    def __init__(self, files=None, errors=None):
        self.files = files or {}
        self.errors = errors or set()

    def get_text(self, url):
        if url in self.errors:
            raise HttpError("boom")
        return self.files.get(url)


class CollectTests(unittest.TestCase):
    def test_collects_readme_and_manifest(self):
        client = FakeClient(
            files={
                adoption.RAW_URL.format(repository="acme/tool", path="README.md"): (
                    "moon binstall acme/tool\n"
                ),
                adoption.RAW_URL.format(
                    repository="acme/tool", path="moon-binstall.json"
                ): "{}",
            }
        )
        entries, warnings = adoption.collect(
            client,
            [SearchHit("acme/tool", "README.md", "moon-binstall", "code_search")],
            SELF,
        )
        self.assertEqual(warnings, [])
        self.assertEqual(entries["acme/tool"].classification, INTEGRATION)

    def test_http_error_is_a_warning(self):
        client = FakeClient(
            errors={
                adoption.RAW_URL.format(repository="acme/tool", path="README.md"),
                adoption.RAW_URL.format(repository="acme/tool", path="readme.md"),
                adoption.RAW_URL.format(repository="acme/tool", path="README.markdown"),
                adoption.RAW_URL.format(repository="acme/tool", path="README"),
                adoption.RAW_URL.format(
                    repository="acme/tool", path="moon-binstall.json"
                ),
            }
        )
        entries, warnings = adoption.collect(
            client,
            [SearchHit("acme/tool", "README.md", "moon-binstall", "code_search")],
            SELF,
        )
        self.assertEqual(entries, {})
        self.assertEqual(len(warnings), 1)


if __name__ == "__main__":
    unittest.main()
