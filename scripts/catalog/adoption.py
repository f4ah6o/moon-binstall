"""Adoption detection from confirmed evidence.

A search hit is not usage. A repository is listed only when its own README,
workflow or manifest shows that it actually uses ``moon-binstall``. Link-only
mentions stay ``reference`` and are not presented as adoption.
"""

from __future__ import annotations

import re
from typing import Any, Iterable

from .discover import SearchHit, valid_id
from .http import Client, HttpError
from .model import ADOPTION, INTEGRATION, REFERENCE, AdoptionEntry

RAW_URL = "https://raw.githubusercontent.com/{repository}/HEAD/{path}"
README_PATHS = ("README.md", "readme.md", "README.markdown", "README")
MANIFEST_PATH = "moon-binstall.json"
MAX_README = 1024 * 1024

COMMAND = re.compile(
    r"moon\s+binstall\s+([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+){1,3})"
)
MENTION = re.compile(r"moon-binstall|f4ah6o/moon-binstall", re.IGNORECASE)
FIXTURE_PATH = re.compile(r"(^|/)(tests?|fixtures?|specs?)(/|$)", re.IGNORECASE)


def _raw(client: Client, repository: str, path: str) -> str | None:
    # get_text maps a confirmed 404 to None; any other failure propagates so
    # the caller can warn instead of silently treating it as "no evidence".
    return client.get_text(RAW_URL.format(repository=repository, path=path))


def fetch_readme(client: Client, repository: str) -> tuple[str, str] | None:
    for path in README_PATHS:
        text = _raw(client, repository, path)
        if text is not None:
            return path, text[:MAX_README]
    return None


def has_manifest(client: Client, repository: str) -> bool:
    return _raw(client, repository, MANIFEST_PATH) is not None


def _command_evidence(path: str, text: str) -> list[str]:
    evidence: list[str] = []
    for line in text.splitlines():
        match = COMMAND.match(line)
        if not match:
            continue
        coordinate = match.group(1)
        if not all(valid_id(part) for part in coordinate.split("/")):
            continue
        evidence.append(f"{path}: moon binstall {coordinate}")
        if len(evidence) >= 3:
            break
    return evidence


def _mention_evidence(path: str, text: str) -> list[str]:
    for line in text.splitlines():
        if MENTION.search(line):
            return [f"{path}: mentions moon-binstall"]
    return []


def classify(
    repository: str,
    readme: tuple[str, str] | None,
    manifest: bool,
    hits: Iterable[SearchHit],
    self_repository: str,
) -> AdoptionEntry | None:
    """Classify one repository from evidence, never from a bare hit."""

    if repository.casefold() == self_repository.casefold():
        return None

    evidence: list[str] = []
    classification = ""

    if manifest:
        classification = INTEGRATION
        evidence.append(MANIFEST_PATH)

    workflow_hits = [
        hit
        for hit in hits
        if hit.path.startswith(".github/workflows/")
        and not FIXTURE_PATH.search(hit.path)
    ]
    if workflow_hits:
        classification = classification or ADOPTION
        for hit in sorted(workflow_hits, key=lambda item: item.path)[:3]:
            evidence.append(f"{hit.path}: workflow references moon-binstall")

    if readme is not None:
        path, text = readme
        commands = _command_evidence(path, text)
        if commands:
            classification = classification or ADOPTION
            evidence.extend(commands)
        elif not classification:
            mentions = _mention_evidence(path, text)
            if mentions:
                classification = REFERENCE
                evidence.extend(mentions)

    if not classification:
        return None
    return AdoptionEntry(
        repository=repository,
        classification=classification,
        evidence=evidence,
        since="",
    )


def collect(
    client: Client,
    hits: Iterable[SearchHit],
    self_repository: str,
    log: Any = None,
) -> tuple[dict[str, AdoptionEntry], list[str]]:
    """Analyze every repository that produced a search hit."""

    grouped: dict[str, list[SearchHit]] = {}
    for hit in hits:
        grouped.setdefault(hit.repository, []).append(hit)

    entries: dict[str, AdoptionEntry] = {}
    warnings: list[str] = []
    for repository in sorted(grouped):
        try:
            readme = fetch_readme(client, repository)
            manifest = has_manifest(client, repository)
        except HttpError as error:
            warnings.append(f"adoption check failed for {repository}: {error}")
            if log is not None:
                log(warnings[-1])
            continue
        entry = classify(
            repository, readme, manifest, grouped[repository], self_repository
        )
        if entry is not None:
            entries[repository] = entry
    return entries, warnings
