"""Dry-run verification.

The existing ``moon binstall --dry-run`` resolver is the only judge of
compatibility. This module runs it once per candidate and target, parses the
stable ``Resolved`` line and the classified ``error[stage]`` output, and maps
them to ``verified``, ``unsupported`` or ``unknown``.

A non-zero exit status alone is never treated as unsupported: only a
structured resolve error that confirms a missing release or a missing asset
is. Transport failures, rate limits, timeouts and unexpected responses stay
unknown so they cannot erase a previously verified entry.
"""

from __future__ import annotations

import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from typing import Any, Callable, Iterable

from .model import (
    REASON_HTTP_ERROR,
    REASON_INVALID_RESPONSE,
    REASON_MODULE_NOT_FOUND,
    REASON_NO_ASSET,
    REASON_NO_GITHUB_RELEASE,
    REASON_NO_RELEASE,
    REASON_RATE_LIMITED,
    REASON_RESOLVED,
    REASON_TIMEOUT,
    REASON_TRANSPORT,
    REASON_UNCLASSIFIED,
    TARGETS,
    UNKNOWN,
    UNSUPPORTED,
    VERIFIED,
    Candidate,
    TargetResult,
)

RESOLVED_LINE = re.compile(
    r"^Resolved (?P<coordinate>.+?): source=(?P<source>.+?) "
    r"tag=(?P<tag>\S+) asset=(?P<asset>\S+) binary=(?P<binary>\S+) "
    r"target=(?P<target>\S+)$",
    re.MULTILINE,
)
ERROR_LINE = re.compile(
    r"^moon-binstall: error\[(?P<stage>[a-z]+)\]: (?P<what>.*)$", re.MULTILINE
)
REASON_LINE = re.compile(r"^  reason: (?P<reason>.*)$", re.MULTILINE)


@dataclass
class DryRunOutcome:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False
    launch_error: str = ""

    @property
    def ok(self) -> bool:
        return self.returncode == 0 and not self.timed_out and not self.launch_error


def _text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def run_dry_run(
    binary: str,
    coordinate: str,
    target: str,
    bin_dir: str,
    timeout: float,
    env: dict[str, str] | None = None,
) -> DryRunOutcome:
    """Run one dry-run. Never downloads, extracts or executes an asset."""

    command = [
        binary,
        coordinate,
        "--target",
        target,
        "--dry-run",
        "--bin-dir",
        bin_dir,
    ]
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            env=env,
        )
        return DryRunOutcome(
            returncode=completed.returncode,
            stdout=completed.stdout or "",
            stderr=completed.stderr or "",
        )
    except subprocess.TimeoutExpired as error:
        return DryRunOutcome(
            returncode=-1,
            stdout=_text(error.stdout),
            stderr=_text(error.stderr),
            timed_out=True,
        )
    except OSError as error:
        return DryRunOutcome(
            returncode=-1,
            stdout="",
            stderr="",
            launch_error=str(error),
        )


def repository_from_source(source: str) -> str:
    """Extract ``owner/repo`` from the resolver's source label."""

    marker = "(repository "
    if marker in source and source.endswith(")"):
        return source.split(marker, 1)[1][:-1]
    prefix = "github-releases "
    if source.startswith(prefix):
        return source[len(prefix) :]
    return ""


def _failure(stage: str, reason: str, today: str, detail: str) -> TargetResult:
    if stage == "resolve":
        if "no release was confirmed for" in reason:
            return TargetResult(UNSUPPORTED, REASON_NO_RELEASE, today)
        if "no matching prebuilt asset in release" in reason:
            return TargetResult(UNSUPPORTED, REASON_NO_ASSET, today)
        if "the Mooncakes module release was not found" in reason:
            return TargetResult(UNSUPPORTED, REASON_MODULE_NOT_FOUND, today)
        if "no GitHub release was found for" in reason:
            return TargetResult(UNSUPPORTED, REASON_NO_GITHUB_RELEASE, today)
        if "invalid GitHub release response" in reason:
            return TargetResult(
                UNKNOWN, REASON_INVALID_RESPONSE, today, detail=detail
            )
        return TargetResult(UNKNOWN, REASON_UNCLASSIFIED, today, detail=detail)
    if stage == "transport":
        if "rate limit" in reason or "429" in reason:
            return TargetResult(UNKNOWN, REASON_RATE_LIMITED, today, detail=detail)
        if "communication failed" in reason:
            return TargetResult(UNKNOWN, REASON_TRANSPORT, today, detail=detail)
        if "server error" in reason or "HTTP 403" in reason:
            return TargetResult(UNKNOWN, REASON_HTTP_ERROR, today, detail=detail)
        return TargetResult(UNKNOWN, REASON_TRANSPORT, today, detail=detail)
    return TargetResult(UNKNOWN, REASON_UNCLASSIFIED, today, detail=detail)


def classify(
    outcome: DryRunOutcome,
    coordinate: str,
    target: str,
    today: str,
) -> TargetResult:
    """Map one dry-run outcome to a target result."""

    if outcome.timed_out:
        return TargetResult(
            UNKNOWN, REASON_TIMEOUT, today, detail=f"timed out after the limit"
        )
    if outcome.launch_error:
        return TargetResult(
            UNKNOWN, REASON_UNCLASSIFIED, today, detail=outcome.launch_error
        )
    if outcome.ok:
        matches = list(RESOLVED_LINE.finditer(outcome.stdout))
        for match in reversed(matches):
            if (
                match.group("coordinate") == coordinate
                and match.group("target") == target
            ):
                return TargetResult(
                    VERIFIED,
                    REASON_RESOLVED,
                    today,
                    tag=match.group("tag"),
                    asset=match.group("asset"),
                    binary=match.group("binary"),
                    repository=repository_from_source(match.group("source")),
                )
        return TargetResult(
            UNKNOWN,
            REASON_UNCLASSIFIED,
            today,
            detail="dry-run succeeded without a matching Resolved line",
        )
    error = ERROR_LINE.search(outcome.stderr)
    reason = REASON_LINE.search(outcome.stderr)
    if error is None:
        return TargetResult(
            UNKNOWN,
            REASON_UNCLASSIFIED,
            today,
            detail="dry-run failed without a classified error",
        )
    reason_text = reason.group("reason") if reason else ""
    detail = f"{error.group('what')}: {reason_text}".strip(": ")
    return _failure(error.group("stage"), reason_text, today, detail)


def verification_env(base: dict[str, str] | None = None) -> dict[str, str]:
    """Environment for a dry-run: keep API auth, drop debug noise."""

    env = dict(os.environ if base is None else base)
    env.pop("MOON_BINSTALL_DEBUG", None)
    return env


def verify_candidates(
    binary: str,
    candidates: Iterable[Candidate],
    targets: Iterable[str] = TARGETS,
    jobs: int = 4,
    timeout: float = 180.0,
    today: str = "",
    bin_root: str = "",
    env: dict[str, str] | None = None,
    log: Callable[[str], None] | None = None,
) -> dict[str, dict[str, TargetResult]]:
    """Verify every candidate and target, returning results by coordinate key."""

    target_list = list(targets)
    candidate_list = list(candidates)
    results: dict[str, dict[str, TargetResult]] = {
        candidate.key: {} for candidate in candidate_list
    }
    environment = verification_env(env)
    tasks: list[tuple[Candidate, str, str]] = []
    for index, candidate in enumerate(candidate_list):
        bin_dir = os.path.join(bin_root, f"c{index}") if bin_root else ""
        for target in target_list:
            tasks.append((candidate, target, bin_dir))

    def work(task: tuple[Candidate, str, str]) -> tuple[Candidate, str, TargetResult]:
        candidate, target, bin_dir = task
        outcome = run_dry_run(
            binary, candidate.coordinate, target, bin_dir, timeout, environment
        )
        return candidate, target, classify(outcome, candidate.coordinate, target, today)

    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futures = [pool.submit(work, task) for task in tasks]
        for future in as_completed(futures):
            candidate, target, result = future.result()
            results[candidate.key][target] = result
            if log is not None:
                log(
                    f"{candidate.coordinate} {target}: "
                    f"{result.status} ({result.reason})"
                )
    return results
