"""What: state merge protects confirmed results and rotation stays bounded."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.catalog import state as state_module
from scripts.catalog.model import (
    REASON_NO_ASSET,
    REASON_RATE_LIMITED,
    REASON_RESOLVED,
    TARGETS,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
    Candidate,
    TargetResult,
)

TODAY = "2026-11-11"


def candidate(coordinate, sources=("mooncakes",), kind="github"):
    return Candidate(
        coordinate=coordinate,
        kind=kind,
        repository=coordinate if kind == "github" else "",
        sources=sources,
    )


def results(coordinate, status, reason, targets=TARGETS):
    return {
        coordinate.lower(): {
            target: TargetResult(status, reason, TODAY, binary="tool")
            for target in targets
        }
    }


class MergeTests(unittest.TestCase):
    def test_unknown_does_not_overwrite_verified(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", VERIFIED, REASON_RESOLVED), TODAY
        )
        stats = state_module.merge_results(
            state,
            [item],
            results("acme/tool", UNKNOWN, REASON_RATE_LIMITED, ["linux-x86_64"]),
            "2026-11-12",
        )
        self.assertEqual(stats.retained, 1)
        entry = state.candidates[item.key]
        self.assertEqual(entry.target("linux-x86_64").status, VERIFIED)
        self.assertEqual(entry.target("linux-x86_64").since, TODAY)

    def test_unsupported_overwrites_verified(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", VERIFIED, REASON_RESOLVED), TODAY
        )
        state_module.merge_results(
            state,
            [item],
            results("acme/tool", UNSUPPORTED, REASON_NO_ASSET),
            "2026-11-12",
        )
        entry = state.candidates[item.key]
        self.assertEqual(entry.target("linux-x86_64").status, UNSUPPORTED)
        self.assertEqual(entry.target("linux-x86_64").since, "2026-11-12")

    def test_verified_overwrites_unsupported(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", UNSUPPORTED, REASON_NO_ASSET), TODAY
        )
        state_module.merge_results(
            state,
            [item],
            results("acme/tool", VERIFIED, REASON_RESOLVED),
            "2026-11-12",
        )
        entry = state.candidates[item.key]
        self.assertEqual(entry.target("linux-x86_64").status, VERIFIED)

    def test_same_status_keeps_original_date(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", VERIFIED, REASON_RESOLVED), TODAY
        )
        state_module.merge_results(
            state,
            [item],
            results("acme/tool", VERIFIED, REASON_RESOLVED),
            "2026-11-12",
        )
        self.assertEqual(
            state.candidates[item.key].target("linux-x86_64").since, TODAY
        )

    def test_missing_candidate_is_retained(self):
        state = state_module.State()
        first = candidate("acme/one")
        second = candidate("acme/two")
        state_module.merge_results(
            state, [first, second], results("acme/one", VERIFIED, REASON_RESOLVED), TODAY
        )
        state_module.merge_results(
            state, [first], results("acme/one", VERIFIED, REASON_RESOLVED), "2026-11-12"
        )
        self.assertIn(second.key, state.candidates)

    def test_new_candidate_with_unknown_is_tracked(self):
        state = state_module.State()
        item = candidate("acme/tool")
        stats = state_module.merge_results(
            state,
            [item],
            results("acme/tool", UNKNOWN, REASON_RATE_LIMITED),
            TODAY,
        )
        self.assertEqual(stats.new_candidates, 1)
        self.assertEqual(stats.unknown, len(TARGETS))
        self.assertEqual(
            state.candidates[item.key].target("linux-x86_64").status, UNKNOWN
        )


class PersistenceTests(unittest.TestCase):
    def test_roundtrip(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", VERIFIED, REASON_RESOLVED), TODAY
        )
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            state_module.save_state(path, state)
            loaded = state_module.load_state(path)
        self.assertEqual(loaded.to_dict(), state.to_dict())

    def test_missing_file_is_empty_state(self):
        with tempfile.TemporaryDirectory() as directory:
            loaded = state_module.load_state(Path(directory) / "missing.json")
        self.assertEqual(loaded.candidates, {})

    def test_invalid_state_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            path.write_text("{not json", encoding="utf-8")
            with self.assertRaises(state_module.StateError):
                state_module.load_state(path)

    def test_unsupported_version_is_an_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            path.write_text('{"version": 99}', encoding="utf-8")
            with self.assertRaises(state_module.StateError):
                state_module.load_state(path)

    def test_unchanged_state_is_not_rewritten(self):
        state = state_module.State()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            state_module.save_state(path, state)
            before = path.stat().st_mtime_ns
            state_module.save_state(path, state)
            self.assertEqual(path.stat().st_mtime_ns, before)


class SelectionTests(unittest.TestCase):
    def test_explicit_sources_are_always_selected(self):
        state = state_module.State()
        discovered = [
            candidate("acme/explicit", sources=("code_search",)),
            candidate("acme/registry", sources=("mooncakes",)),
        ]
        selection = state_module.select_candidates(
            state, discovered, always_budget=10, rotate_budget=0
        )
        self.assertEqual(
            [item.coordinate for item in selection.candidates], ["acme/explicit"]
        )
        self.assertEqual(selection.skipped, 1)

    def test_verified_entries_are_always_selected(self):
        state = state_module.State()
        item = candidate("acme/tool")
        state_module.merge_results(
            state, [item], results("acme/tool", VERIFIED, REASON_RESOLVED), TODAY
        )
        selection = state_module.select_candidates(
            state, [], always_budget=10, rotate_budget=0
        )
        self.assertEqual(
            [item.coordinate for item in selection.candidates], ["acme/tool"]
        )

    def test_rotation_is_bounded_and_deterministic(self):
        state = state_module.State()
        discovered = [candidate(f"acme/tool{index:02d}") for index in range(10)]
        first = state_module.select_candidates(
            state, discovered, always_budget=0, rotate_budget=3, rotation_seed=1
        )
        second = state_module.select_candidates(
            state, discovered, always_budget=0, rotate_budget=3, rotation_seed=1
        )
        self.assertEqual(len(first.candidates), 3)
        self.assertEqual(
            [item.coordinate for item in first.candidates],
            [item.coordinate for item in second.candidates],
        )
        self.assertEqual(first.skipped, 7)

    def test_rotation_advances_with_the_seed(self):
        state = state_module.State()
        discovered = [candidate(f"acme/tool{index:02d}") for index in range(10)]
        first = state_module.select_candidates(
            state, discovered, always_budget=0, rotate_budget=3, rotation_seed=1
        )
        second = state_module.select_candidates(
            state, discovered, always_budget=0, rotate_budget=3, rotation_seed=2
        )
        self.assertNotEqual(
            [item.coordinate for item in first.candidates],
            [item.coordinate for item in second.candidates],
        )

    def test_full_selection_ignores_budgets(self):
        state = state_module.State()
        discovered = [candidate(f"acme/tool{index:02d}") for index in range(10)]
        selection = state_module.select_candidates(
            state, discovered, always_budget=1, rotate_budget=1, full=True
        )
        self.assertEqual(len(selection.candidates), 10)

    def test_always_overflow_moves_to_rotation(self):
        state = state_module.State()
        discovered = [
            candidate(f"acme/explicit{index:02d}", sources=("code_search",))
            for index in range(5)
        ]
        selection = state_module.select_candidates(
            state, discovered, always_budget=2, rotate_budget=10
        )
        self.assertEqual(selection.always, 2)
        self.assertEqual(len(selection.candidates), 5)


class SummaryTests(unittest.TestCase):
    def test_counts(self):
        state = state_module.State()
        verified = candidate("acme/verified")
        unsupported = candidate("acme/unsupported")
        unknown = candidate("acme/unknown")
        state_module.merge_results(
            state, [verified], results("acme/verified", VERIFIED, REASON_RESOLVED), TODAY
        )
        state_module.merge_results(
            state,
            [unsupported],
            results("acme/unsupported", UNSUPPORTED, REASON_NO_ASSET),
            TODAY,
        )
        state_module.merge_results(
            state,
            [unknown],
            results("acme/unknown", UNKNOWN, REASON_RATE_LIMITED),
            TODAY,
        )
        counts = state_module.summarize(state)
        self.assertEqual(counts["candidates"], 3)
        self.assertEqual(counts["verified"], 1)
        self.assertEqual(counts["unsupported"], 1)
        self.assertEqual(counts["unknown"], 1)


if __name__ == "__main__":
    unittest.main()
