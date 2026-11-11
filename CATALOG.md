# moon-binstall Catalog

Automatically discovered MoonBit CLI binaries.

Compatibility is determined by `moon binstall --dry-run`.

Last updated: 2026-11-11 UTC

## Verified CLIs

| CLI | Repository | Linux x64 | Linux ARM64 | macOS x64 | macOS ARM64 | Install |
|---|---|---|---|---|---|---|
| dsh | f4ah6o/dsh.mbt | ✓ | ✓ | — | ✓ | `moon binstall f4ah6o/dsh.mbt` |
| moon-binstall | f4ah6o/moon-binstall | ✓ | ✓ | — | ✓ | `moon binstall f4ah6o/moon-binstall` |
| moon-release | dijdzv/moon-release | ✓ | — | — | — | `moon binstall dijdzv/moon-release` |
| turtles | gpui-mbt/turtles.mbt | ✓ | ✓ | — | ✓ | `moon binstall gpui-mbt/turtles.mbt` |

## Detection

- ✓ Resolved successfully
- — Confirmed unsupported
- ? Could not determine

## Scan Summary

- Candidates tracked: 332
- Verified CLIs: 4
- Unsupported candidates: 327
- Unknown results: 0
- Adoption entries: 2
- Reference mentions: 0

## Adoption

| Repository | Class | Evidence |
|---|---|---|
| f4ah6o/dsh.mbt | adoption | README.md: moon binstall f4ah6o/dsh.mbt; README.md: moon binstall f4ah6o/dsh/cmd/dsh |
| f4ah6o/electron.mbt | integration | moon-binstall.json |

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
