"""Deterministic CATALOG.md generation.

The rendered body excludes the date line; the date is only advanced when the
body changes. An unchanged scan therefore produces byte-identical output and
no repository diff.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

from .model import (
    ADOPTION,
    INTEGRATION,
    REASON_TEXT,
    TARGETS,
    TARGET_LABELS,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
    State,
    derive_repository,
)
from .state import summarize

DATE_PLACEHOLDER = "Last updated: 0000-00-00 UTC"

DETECTION = {
    VERIFIED: "✓",
    UNSUPPORTED: "—",
    UNKNOWN: "?",
}

LIMITATIONS = """\
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


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ").strip()


def _verified_rows(state: State) -> list[tuple[str, str, list[str], str]]:
    rows: list[tuple[str, str, list[str], str]] = []
    for entry in state.candidates.values():
        statuses = [entry.target(target).status for target in TARGETS]
        if VERIFIED not in statuses:
            continue
        repository = entry.repository or derive_repository(
            entry.coordinate, entry.kind
        )
        rows.append(
            (
                entry.binary_name(),
                repository,
                [DETECTION[status] for status in statuses],
                entry.coordinate,
            )
        )
    rows.sort(key=lambda row: (row[0].casefold(), row[3].casefold()))
    # The same CLI can verify through both a GitHub and a Mooncakes
    # coordinate. Keep one row per executable and repository; the shorter
    # coordinate (the GitHub one) sorts first and wins.
    unique: list[tuple[str, str, list[str], str]] = []
    seen: set[tuple[str, str]] = set()
    for row in rows:
        key = (row[0].casefold(), row[1].casefold())
        if row[1] and key in seen:
            continue
        seen.add(key)
        unique.append(row)
    return unique


def _unknown_rows(state: State) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    for entry in state.candidates.values():
        statuses = [entry.target(target).status for target in TARGETS]
        if VERIFIED in statuses or all(status == UNSUPPORTED for status in statuses):
            continue
        reason = ""
        for target in TARGETS:
            result = entry.target(target)
            if result.status == UNKNOWN:
                reason = f"{target}: {REASON_TEXT.get(result.reason, result.reason)}"
                break
        rows.append((entry.binary_name(), entry.coordinate, reason))
    rows.sort(key=lambda row: (row[0].casefold(), row[1].casefold()))
    return rows


def _adoption_rows(state: State) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    for entry in state.adoption.values():
        if entry.classification not in (ADOPTION, INTEGRATION):
            continue
        evidence = "; ".join(sorted(set(entry.evidence)))
        rows.append((entry.repository, entry.classification, evidence))
    rows.sort(key=lambda row: row[0].casefold())
    return rows


def render_body(state: State) -> str:
    """Render everything except the date value, for change detection."""

    counts = summarize(state)
    lines: list[str] = [
        "# moon-binstall Catalog",
        "",
        "Automatically discovered MoonBit CLI binaries.",
        "",
        "Compatibility is determined by `moon binstall --dry-run`.",
        "",
        DATE_PLACEHOLDER,
        "",
        "## Verified CLIs",
        "",
    ]
    rows = _verified_rows(state)
    if rows:
        header = ["CLI", "Repository"] + [
            TARGET_LABELS[target] for target in TARGETS
        ] + ["Install"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "|".join(["---"] * len(header)) + "|")
        for binary, repository, cells, coordinate in rows:
            values = [binary, repository or "—"] + cells + [
                f"`moon binstall {coordinate}`"
            ]
            lines.append("| " + " | ".join(_cell(value) for value in values) + " |")
    else:
        lines.append("No CLI has been verified yet.")
    lines.extend(
        [
            "",
            "## Detection",
            "",
            "- ✓ Resolved successfully",
            "- — Confirmed unsupported",
            "- ? Could not determine",
            "",
            "## Scan Summary",
            "",
            f"- Candidates tracked: {counts['candidates']}",
            f"- Verified CLIs: {counts['verified']}",
            f"- Unsupported candidates: {counts['unsupported']}",
            f"- Unknown results: {counts['unknown']}",
            f"- Adoption entries: {counts['adoption']}",
            f"- Reference mentions: {counts['references']}",
            "",
        ]
    )
    adoption = _adoption_rows(state)
    if adoption:
        lines.extend(
            [
                "## Adoption",
                "",
                "| Repository | Class | Evidence |",
                "|---|---|---|",
            ]
        )
        for repository, classification, evidence in adoption:
            lines.append(
                "| "
                + " | ".join(
                    _cell(value)
                    for value in (repository, classification, evidence)
                )
                + " |"
            )
        lines.append("")
    unknown = _unknown_rows(state)
    if unknown:
        lines.extend(
            [
                "## Unknown",
                "",
                "| CLI | Coordinate | Reason |",
                "|---|---|---|",
            ]
        )
        for binary, coordinate, reason in unknown:
            lines.append(
                "| "
                + " | ".join(_cell(value) for value in (binary, coordinate, reason))
                + " |"
            )
        lines.append("")
    lines.extend(["## Limitations", "", LIMITATIONS])
    return "\n".join(lines).rstrip("\n") + "\n"


def render_catalog(state: State, today: str) -> str:
    date = state.catalog_updated or today
    return render_body(state).replace(
        DATE_PLACEHOLDER, f"Last updated: {date} UTC", 1
    )


def body_digest(state: State) -> str:
    return hashlib.sha256(render_body(state).encode("utf-8")).hexdigest()


def update_catalog(state: State, path: Path, today: str) -> bool:
    """Write the catalog only when its content changed."""

    digest = body_digest(state)
    if digest != state.body_sha256:
        state.body_sha256 = digest
        state.catalog_updated = today
    text = render_catalog(state, today)
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def check_catalog(state: State, path: Path, today: str) -> bool:
    """Whether the file already matches the state exactly."""

    if not path.exists():
        return False
    return path.read_text(encoding="utf-8") == render_catalog(state, today)
