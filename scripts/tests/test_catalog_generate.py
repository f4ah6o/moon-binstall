"""What: CATALOG.md is deterministic and only changes when results change."""

from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.catalog import generate
from scripts.catalog import state as state_module
from scripts.catalog.model import (
    ADOPTION,
    INTEGRATION,
    REASON_NO_ASSET,
    REASON_NO_RELEASE,
    REASON_RATE_LIMITED,
    REASON_RESOLVED,
    REFERENCE,
    TARGETS,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
    AdoptionEntry,
    Candidate,
    TargetResult,
)

TODAY = "2026-11-11"

GOLDEN = """\
# moon-binstall Catalog

Automatically discovered MoonBit CLI binaries.

Compatibility is determined by `moon binstall --dry-run`.

Last updated: 2026-11-11 UTC

## Verified CLIs

| CLI | Repository | Linux x64 | Linux ARM64 | macOS x64 | macOS ARM64 | Install |
|---|---|---|---|---|---|---|
| tool | acme/tool | ✓ | — | ? | ✓ | `moon binstall acme/tool` |

## Detection

- ✓ Resolved successfully
- — Confirmed unsupported
- ? Could not determine

## Scan Summary

- Candidates tracked: 3
- Verified CLIs: 1
- Unsupported candidates: 1
- Unknown results: 1
- Adoption entries: 2
- Reference mentions: 1

## Adoption

| Repository | Class | Evidence |
|---|---|---|
| acme/integration | integration | moon-binstall.json |
| f4ah6o/dsh.mbt | adoption | README.md: moon binstall f4ah6o/dsh.mbt |

## Unknown

| CLI | Coordinate | Reason |
|---|---|---|
| pending | acme/pending | linux-x86_64: GitHub API rate limit |

## Limitations

- `verified` means the resolver matched a GitHub release asset for that
  target. It does not mean the binary was downloaded, its SHA-256 was
  checked, an archive was extracted, ELF compatibility was verified, or the
  CLI was installed or executed.
- Candidates come from the public Mooncakes module list, GitHub code search,
  GitHub repository search and the `moon binstall` examples in this
  repository's README. GitHub code search is authenticated-only and rate
  limited, so a failed search can hide a repository until a later scan.
- The Mooncakes registry API does not expose package paths, so
  registry-discovered modules are verified through their GitHub `owner/repo`
  coordinate. A module whose release assets only match a Mooncakes
  `owner/module/package` coordinate is not detected.
- The same CLI can be discovered through both a GitHub `owner/repo`
  coordinate and a Mooncakes `owner/module/package` coordinate. The table
  lists one row per executable and repository, so the verified CLI count can
  be smaller than the number of verified coordinates.
- Registry-only candidates rotate: each scan checks a bounded subset, so a
  candidate may be re-checked days after its last verification. Explicit
  search hits and currently verified CLIs are checked every run.
- `?` means the resolver could not decide (rate limit, network failure,
  timeout or an unexpected response). It is never treated as supported, and
  it never replaces a previously confirmed result.
- The date above changes only when the catalog content changes. Scans that
  confirm the same results do not rewrite this file.
- Adoption entries require evidence in the repository itself (a README
  install command, a workflow step or a `moon-binstall.json`). A search hit
  alone is not listed.
"""


def build_state() -> state_module.State:
    state = state_module.State()

    def add(coordinate, statuses):
        item = Candidate(coordinate, "github", coordinate, sources=("code_search",))
        observed = {item.key: {}}
        for target, (status, reason) in statuses.items():
            observed[item.key][target] = TargetResult(
                status,
                reason,
                TODAY,
                tag="v1.0.0",
                asset="tool-" + target,
                binary=coordinate.split("/")[-1].replace(".mbt", ""),
            )
        state_module.merge_results(state, [item], observed, TODAY)

    add(
        "acme/tool",
        {
            "linux-x86_64": (VERIFIED, REASON_RESOLVED),
            "linux-aarch64": (UNSUPPORTED, REASON_NO_ASSET),
            "darwin-x86_64": (UNKNOWN, REASON_RATE_LIMITED),
            "darwin-aarch64": (VERIFIED, REASON_RESOLVED),
        },
    )
    add("acme/other", {target: (UNSUPPORTED, REASON_NO_RELEASE) for target in TARGETS})
    add("acme/pending", {target: (UNKNOWN, REASON_RATE_LIMITED) for target in TARGETS})
    state.adoption["f4ah6o/dsh.mbt"] = AdoptionEntry(
        "f4ah6o/dsh.mbt",
        ADOPTION,
        ["README.md: moon binstall f4ah6o/dsh.mbt"],
        TODAY,
    )
    state.adoption["acme/integration"] = AdoptionEntry(
        "acme/integration", INTEGRATION, ["moon-binstall.json"], TODAY
    )
    state.adoption["acme/reference"] = AdoptionEntry(
        "acme/reference", REFERENCE, ["README.md: mentions moon-binstall"], TODAY
    )
    state.catalog_updated = TODAY
    return state


class RenderTests(unittest.TestCase):
    def test_golden(self):
        self.assertEqual(generate.render_catalog(build_state(), "2026-11-12"), GOLDEN)

    def test_deterministic(self):
        first = generate.render_catalog(build_state(), "2026-11-12")
        second = generate.render_catalog(build_state(), "2026-11-12")
        self.assertEqual(first, second)

    def test_unsupported_only_is_not_listed(self):
        text = generate.render_catalog(build_state(), "2026-11-12")
        self.assertNotIn("acme/other", text)

    def test_reference_is_not_adoption(self):
        text = generate.render_catalog(build_state(), "2026-11-12")
        self.assertNotIn("acme/reference", text)
        self.assertIn("Reference mentions: 1", text)

    def test_empty_state(self):
        text = generate.render_catalog(state_module.State(), "2026-11-12")
        self.assertIn("No CLI has been verified yet.", text)
        self.assertIn("Last updated: 2026-11-12 UTC", text)


class UpdateTests(unittest.TestCase):
    def test_unchanged_scan_keeps_the_date(self):
        state = build_state()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CATALOG.md"
            self.assertTrue(generate.update_catalog(state, path, TODAY))
            first = path.read_text(encoding="utf-8")
            self.assertFalse(generate.update_catalog(state, path, "2026-11-20"))
            self.assertEqual(path.read_text(encoding="utf-8"), first)
            self.assertEqual(state.catalog_updated, TODAY)

    def test_changed_result_advances_the_date(self):
        state = build_state()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CATALOG.md"
            generate.update_catalog(state, path, TODAY)
            item = Candidate("acme/tool", "github", "acme/tool")
            observed = {
                item.key: {
                    "linux-aarch64": TargetResult(
                        VERIFIED, REASON_RESOLVED, "2026-11-20", binary="tool"
                    )
                }
            }
            state_module.merge_results(state, [item], observed, "2026-11-20")
            self.assertTrue(generate.update_catalog(state, path, "2026-11-20"))
            text = path.read_text(encoding="utf-8")
            self.assertIn("Last updated: 2026-11-20 UTC", text)
            self.assertIn("| tool | acme/tool | ✓ | ✓ | ? | ✓ |", text)

    def test_check_detects_stale_file(self):
        state = build_state()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "CATALOG.md"
            self.assertFalse(generate.check_catalog(state, path, TODAY))
            generate.update_catalog(state, path, TODAY)
            self.assertTrue(generate.check_catalog(state, path, TODAY))
            path.write_text("stale\n", encoding="utf-8")
            self.assertFalse(generate.check_catalog(state, path, TODAY))


if __name__ == "__main__":
    unittest.main()
