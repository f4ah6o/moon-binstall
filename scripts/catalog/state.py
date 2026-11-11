"""State persistence, merge rules and scan selection.

The state file is an internal artifact, not a public API. It keeps the last
confirmed observation per candidate and target so that:

* a transient failure never downgrades a verified entry,
* a candidate that is missing from one discovery run is not deleted,
* a daily scan can rotate through the registry without losing results.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

from .model import (
    EXPLICIT_SOURCES,
    TARGETS,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
    AdoptionEntry,
    Candidate,
    CandidateEntry,
    State,
    TargetResult,
    derive_repository,
)


class StateError(Exception):
    """The state file exists but cannot be used safely."""


def load_state(path: Path) -> State:
    if not path.exists():
        return State()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise StateError(f"cannot read {path}: {error}") from error
    if not isinstance(data, dict):
        raise StateError(f"{path} must contain a JSON object")
    version = data.get("version", 1)
    if version != 1:
        raise StateError(f"{path} has unsupported version {version!r}")
    return State.from_dict(data)


def save_state(path: Path, state: State) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(state.to_dict(), indent=2, sort_keys=True) + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == payload:
        return
    handle, temporary = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(payload)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


@dataclass
class MergeStats:
    new_candidates: int = 0
    changed: int = 0
    retained: int = 0
    unknown: int = 0
    verified: int = 0
    unsupported: int = 0


def merge_results(
    state: State,
    candidates: Iterable[Candidate],
    results: dict[str, dict[str, TargetResult]],
    today: str,
) -> MergeStats:
    """Merge one run's observations without letting unknown erase confirmed."""

    stats = MergeStats()
    for candidate in candidates:
        key = candidate.key
        observed = results.get(key, {})
        entry = state.candidates.get(key)
        if entry is None:
            entry = CandidateEntry(
                coordinate=candidate.coordinate,
                kind=candidate.kind,
                repository=candidate.repository,
                module=candidate.module,
                description=candidate.description,
                sources=sorted(set(candidate.sources)),
                first_seen=today,
                targets={},
            )
            state.candidates[key] = entry
            stats.new_candidates += 1
        else:
            entry.repository = entry.repository or candidate.repository
            entry.module = entry.module or candidate.module
            entry.description = entry.description or candidate.description
            entry.sources = sorted(set(entry.sources) | set(candidate.sources))

        for target in TARGETS:
            result = observed.get(target)
            if result is None:
                continue
            existing = entry.targets.get(target)
            if result.status == UNKNOWN:
                if existing is not None and existing.status in (VERIFIED, UNSUPPORTED):
                    stats.retained += 1
                    continue
                if (
                    existing is not None
                    and existing.status == UNKNOWN
                    and existing.reason == result.reason
                ):
                    continue
                entry.targets[target] = TargetResult(
                    status=UNKNOWN,
                    reason=result.reason,
                    since=today,
                    detail=result.detail,
                )
                stats.unknown += 1
                continue
            if existing is not None and existing.status == result.status:
                # Same confirmed status: keep the original date and evidence so
                # an unchanged scan produces no state diff.
                continue
            entry.targets[target] = TargetResult(
                status=result.status,
                reason=result.reason,
                since=today,
                tag=result.tag,
                asset=result.asset,
                binary=result.binary,
                repository=result.repository,
                detail=result.detail,
            )
            if result.status == VERIFIED and result.repository:
                entry.repository = result.repository
            stats.changed += 1
            if result.status == VERIFIED:
                stats.verified += 1
            elif result.status == UNSUPPORTED:
                stats.unsupported += 1
    return stats


def merge_adoption(
    state: State,
    entries: dict[str, AdoptionEntry],
    today: str,
) -> int:
    """Merge adoption evidence; missing search results never delete an entry."""

    changed = 0
    for repository, entry in entries.items():
        existing = state.adoption.get(repository)
        if (
            existing is not None
            and existing.classification == entry.classification
            and sorted(set(existing.evidence)) == sorted(set(entry.evidence))
        ):
            continue
        state.adoption[repository] = AdoptionEntry(
            repository=repository,
            classification=entry.classification,
            evidence=sorted(set(entry.evidence)),
            since=today,
        )
        changed += 1
    return changed


@dataclass
class Selection:
    candidates: list[Candidate] = field(default_factory=list)
    always: int = 0
    rotate: int = 0
    skipped: int = 0


def _entry_candidate(entry: CandidateEntry) -> Candidate:
    return Candidate(
        coordinate=entry.coordinate,
        kind=entry.kind,
        repository=entry.repository,
        module=entry.module,
        description=entry.description,
        sources=tuple(entry.sources),
    )


def _is_always(entry: CandidateEntry | None, candidate: Candidate) -> bool:
    if any(source in EXPLICIT_SOURCES for source in candidate.sources):
        return True
    if entry is None:
        return False
    return any(
        entry.target(target).status == VERIFIED for target in TARGETS
    )


def select_candidates(
    state: State,
    discovered: Iterable[Candidate],
    always_budget: int = 100,
    rotate_budget: int = 100,
    full: bool = False,
    rotation_seed: int = 0,
) -> Selection:
    """Choose this run's candidates deterministically.

    Explicit-signal and currently verified candidates are checked every run.
    Registry-only candidates rotate from a date-derived window so a daily scan
    stays inside the API budget and still covers the registry over time. The
    window is derived from the date instead of a stored cursor, so an
    unchanged scan does not rewrite the state file.
    """

    by_key: dict[str, Candidate] = {}
    for candidate in discovered:
        by_key[candidate.key] = candidate
    for key, entry in state.candidates.items():
        if key not in by_key:
            by_key[key] = _entry_candidate(entry)

    always: list[Candidate] = []
    rotate: list[Candidate] = []
    for key, candidate in by_key.items():
        entry = state.candidates.get(key)
        if _is_always(entry, candidate):
            always.append(candidate)
        else:
            rotate.append(candidate)

    always.sort(key=lambda item: item.coordinate.casefold())
    rotate.sort(key=lambda item: item.coordinate.casefold())

    if not full and len(always) > always_budget:
        rotate.extend(always[always_budget:])
        always = always[:always_budget]
        rotate.sort(key=lambda item: item.coordinate.casefold())

    selection = Selection(always=len(always))
    selection.candidates.extend(always)

    if full:
        selection.candidates.extend(rotate)
        selection.rotate = len(rotate)
        return selection

    if rotate_budget <= 0 or not rotate:
        selection.skipped = len(rotate)
        return selection

    start = (max(0, rotation_seed) * rotate_budget) % len(rotate)
    chosen = rotate[start : start + rotate_budget]
    remaining = rotate_budget - len(chosen)
    if remaining > 0 and start > 0:
        chosen.extend(rotate[: min(remaining, start)])
    selection.candidates.extend(chosen)
    selection.rotate = len(chosen)
    selection.skipped = len(rotate) - len(chosen)
    return selection


def verified_keys(state: State) -> set[tuple[str, str]]:
    """One key per executable and repository, matching the catalog table."""

    keys: set[tuple[str, str]] = set()
    for entry in state.candidates.values():
        statuses = [entry.target(target).status for target in TARGETS]
        if VERIFIED not in statuses:
            continue
        repository = entry.repository or derive_repository(
            entry.coordinate, entry.kind
        )
        keys.add(
            (
                entry.binary_name().casefold(),
                repository.casefold() or entry.coordinate.casefold(),
            )
        )
    return keys


def summarize(state: State) -> dict[str, int]:
    """Stable counts derived from confirmed state, not from one run."""

    verified = len(verified_keys(state))
    unsupported = 0
    unknown = 0
    for entry in state.candidates.values():
        statuses = [entry.target(target).status for target in TARGETS]
        if VERIFIED in statuses:
            continue
        if all(status == UNSUPPORTED for status in statuses):
            unsupported += 1
        else:
            unknown += 1
    adoption = sum(
        1
        for entry in state.adoption.values()
        if entry.classification in ("adoption", "integration")
    )
    references = sum(
        1 for entry in state.adoption.values() if entry.classification == "reference"
    )
    return {
        "candidates": len(state.candidates),
        "verified": verified,
        "unsupported": unsupported,
        "unknown": unknown,
        "adoption": adoption,
        "references": references,
    }
