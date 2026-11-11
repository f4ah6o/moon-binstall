"""What: candidate discovery normalizes coordinates and survives partial failure."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.catalog import discover
from scripts.catalog.http import HttpError, RateLimited


class FakeClient:
    def __init__(self, responses=None, failures=None):
        self.responses = responses or {}
        self.failures = failures or {}

    def get_json(self, url, params=None, accept=None):
        if url in self.failures:
            raise self.failures[url]
        return self.responses[url]

    def paginate(self, url, params=None, max_pages=3):
        if url in self.failures:
            raise self.failures[url]
        yield self.responses[url]


def module(name, repository, description="", yanked=False):
    return {
        "name": name,
        "repository": repository,
        "description": description,
        "yanked": yanked,
    }


class NormalizeTests(unittest.TestCase):
    def test_github_repository_variants(self):
        cases = {
            "https://github.com/owner/repo": "owner/repo",
            "https://github.com/owner/repo.git": "owner/repo",
            "https://github.com/owner/repo/": "owner/repo",
            "https://github.com/owner/repo.mbt": "owner/repo.mbt",
        }
        for value, expected in cases.items():
            with self.subTest(value=value):
                self.assertEqual(discover.normalize_github_repository(value), expected)

    def test_reject_non_github_and_unsafe_urls(self):
        for value in (
            "https://gitlab.com/owner/repo",
            "http://github.com/owner/repo",
            "https://github.com/owner",
            "https://github.com/owner/repo?tab=readme",
            "https://github.com/owner/repo#readme",
            "https://github.com/../repo",
            "",
        ):
            with self.subTest(value=value):
                self.assertIsNone(discover.normalize_github_repository(value))

    def test_coordinate_kinds(self):
        self.assertEqual(
            discover.normalize_coordinate("gpui-mbt/turtles.mbt"),
            ("github", "gpui-mbt/turtles.mbt"),
        )
        self.assertEqual(
            discover.normalize_coordinate("f4ah6o/moon-binstall/cmd/main"),
            ("mooncakes", "f4ah6o/moon-binstall/cmd/main"),
        )

    def test_coordinate_drops_tag(self):
        self.assertEqual(
            discover.normalize_coordinate("gpui-mbt/turtles.mbt@v0.4.0"),
            ("github", "gpui-mbt/turtles.mbt"),
        )

    def test_coordinate_rejects_unsafe_values(self):
        for value in ("turtles", "owner/repo;rm", "owner/../repo", "a/b/c/d/e/f"):
            with self.subTest(value=value):
                self.assertIsNone(discover.normalize_coordinate(value))


class CandidateTests(unittest.TestCase):
    def test_mooncakes_filters_yanked_and_non_github(self):
        found = discover.candidates_from_mooncakes(
            [
                module("gpui-mbt/turtles", "https://github.com/gpui-mbt/turtles.mbt", "turtles"),
                module("z/w", "https://github.com/z/w", yanked=True),
                module("x/y", "https://gitlab.com/x/y"),
                module("bad", "https://github.com/owner/repo/extra"),
            ]
        )
        self.assertEqual([item.coordinate for item in found], ["gpui-mbt/turtles.mbt"])
        self.assertEqual(found[0].module, "gpui-mbt/turtles")
        self.assertEqual(found[0].sources, ("mooncakes",))

    def test_search_items_support_both_shapes(self):
        code_items = [
            {"repository": {"full_name": "owner/repo"}, "path": "README.md"},
            {"repository": {"full_name": "bad name/repo"}, "path": "x"},
        ]
        found, hits = discover.candidates_from_search_items(
            code_items, "code_search", '"moon binstall"'
        )
        self.assertEqual([item.coordinate for item in found], ["owner/repo"])
        self.assertEqual(hits[0].path, "README.md")

        repo_items = [{"full_name": "owner/tool", "description": "tool"}]
        found, hits = discover.candidates_from_search_items(
            repo_items, "repo_search", "moon-binstall in:readme"
        )
        self.assertEqual([item.coordinate for item in found], ["owner/tool"])
        self.assertEqual(hits[0].path, "README.md")

    def test_readme_examples(self):
        text = """
        ```sh
        moon binstall gpui-mbt/turtles.mbt
        moon binstall gpui-mbt/hotpath.mbt@v0.2.0
        moon binstall f4ah6o/moon-binstall/cmd/main@0.1.4
        ```
        """
        found = discover.candidates_from_readme(text)
        self.assertEqual(
            [item.coordinate for item in found],
            [
                "gpui-mbt/turtles.mbt",
                "gpui-mbt/hotpath.mbt",
                "f4ah6o/moon-binstall/cmd/main",
            ],
        )

    def test_merge_deduplicates_and_unions_sources(self):
        merged = discover.merge_candidates(
            [
                discover.Candidate("Owner/Repo", "github", sources=("mooncakes",)),
                discover.Candidate("owner/repo", "github", sources=("code_search",)),
                discover.Candidate("owner/repo", "github", sources=("readme",)),
            ]
        )
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0].coordinate, "Owner/Repo")
        self.assertEqual(
            merged[0].sources, ("code_search", "mooncakes", "readme")
        )

    def test_mooncakes_coordinates_are_case_sensitive(self):
        merged = discover.merge_candidates(
            [
                discover.Candidate("owner/Module", "mooncakes"),
                discover.Candidate("owner/module", "mooncakes"),
            ]
        )
        self.assertEqual(len(merged), 2)


class DiscoverTests(unittest.TestCase):
    def test_partial_failure_keeps_other_sources(self):
        client = FakeClient(
            responses={
                discover.MOONCAKES_MODULES_URL: [
                    module("a/b", "https://github.com/a/b")
                ],
                discover.GITHUB_REPO_SEARCH_URL: {"items": []},
            },
            failures={discover.GITHUB_CODE_SEARCH_URL: HttpError("boom")},
        )
        result = discover.discover(client, readme_text="moon binstall c/d.mbt\n")
        self.assertEqual(
            [item.coordinate for item in result.candidates], ["a/b", "c/d.mbt"]
        )
        self.assertGreaterEqual(result.sources_ok, 2)
        self.assertGreaterEqual(result.sources_failed, 1)
        self.assertTrue(any("code search" in warning for warning in result.warnings))

    def test_rate_limit_stops_code_search_but_not_repo_search(self):
        client = FakeClient(
            responses={
                discover.MOONCAKES_MODULES_URL: [],
                discover.GITHUB_REPO_SEARCH_URL: {"items": [{"full_name": "a/b"}]},
            },
            failures={discover.GITHUB_CODE_SEARCH_URL: RateLimited("limited")},
        )
        result = discover.discover(client)
        self.assertEqual([item.coordinate for item in result.candidates], ["a/b"])
        self.assertTrue(any("rate limited" in warning for warning in result.warnings))

    def test_all_sources_failed(self):
        client = FakeClient(
            failures={
                discover.MOONCAKES_MODULES_URL: HttpError("down"),
                discover.GITHUB_CODE_SEARCH_URL: HttpError("down"),
                discover.GITHUB_REPO_SEARCH_URL: HttpError("down"),
            }
        )
        result = discover.discover(client)
        self.assertEqual(result.sources_ok, 0)
        self.assertEqual(result.candidates, [])


if __name__ == "__main__":
    unittest.main()
