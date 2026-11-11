"""Candidate discovery from public information.

Discovery is intentionally broad and cheap: it never decides whether a CLI is
supported. It only produces coordinates that the existing resolver will judge
with ``moon binstall --dry-run``.

Sources:

* the Mooncakes registry module list (one public JSON document),
* GitHub code search for manifest and usage strings,
* GitHub repository search for README mentions,
* ``moon binstall`` examples in this repository's README.

GitHub code search is authenticated-only and heavily rate limited, so a
failure there is a warning, not a fatal error. The registry list is the only
source that can enumerate every published module.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any, Iterable

from .http import Client, HttpError, RateLimited
from .model import Candidate, candidate_key

MOONCAKES_MODULES_URL = "https://mooncakes.io/api/v0/modules"
GITHUB_CODE_SEARCH_URL = "https://api.github.com/search/code"
GITHUB_REPO_SEARCH_URL = "https://api.github.com/search/repositories"

CODE_SEARCH_QUERIES = (
    '"moon binstall"',
    "f4ah6o/moon-binstall",
    "moon-binstall",
    "moon-binstall.json",
)

REPO_SEARCH_QUERIES = (
    "moon-binstall in:readme",
    '"moon binstall" in:readme',
    "moon-binstall.json in:readme",
    "moonbit binstall in:readme",
)

README_COMMAND = re.compile(
    r"moon\s+binstall\s+([A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+){1,3})"
)
GITHUB_URL = re.compile(
    r"^https://github\.com/(?P<owner>[A-Za-z0-9._-]+)/(?P<repo>[A-Za-z0-9._-]+?)(?:\.git)?/?$"
)


def valid_id(value: str) -> bool:
    """Mirror the CLI's ``valid_id``: no path separators or shell syntax."""

    if value in ("", ".", ".."):
        return False
    return all(
        char.isascii() and (char.isalnum() or char in "-_.") for char in value
    )


def normalize_github_repository(url: str) -> str | None:
    """Return ``owner/repo`` for a public GitHub repository URL."""

    if not isinstance(url, str):
        return None
    match = GITHUB_URL.match(url.strip())
    if not match:
        return None
    owner = match.group("owner")
    repo = match.group("repo")
    if not valid_id(owner) or not valid_id(repo):
        return None
    return f"{owner}/{repo}"


def normalize_coordinate(text: str) -> tuple[str, str] | None:
    """Normalize a coordinate the CLI accepts.

    Two path components are a GitHub ``owner/repo`` coordinate; three or more
    are a Mooncakes ``owner/module/package`` coordinate. A tag is dropped
    because the catalog always verifies the latest release.
    """

    value = text.strip().strip("`'\"()[]<>,;")
    if not value or "@" in value:
        value = value.split("@", 1)[0]
    parts = value.split("/")
    if len(parts) < 2 or len(parts) > 5:
        return None
    if not all(valid_id(part) for part in parts):
        return None
    if len(parts) == 2:
        return "github", "/".join(parts)
    return "mooncakes", "/".join(parts)


def candidate_from_coordinate(
    coordinate: str,
    kind: str,
    source: str,
    repository: str = "",
    module: str = "",
    description: str = "",
) -> Candidate:
    return Candidate(
        coordinate=coordinate,
        kind=kind,
        repository=repository,
        module=module,
        description=description,
        sources=(source,),
    )


def candidates_from_mooncakes(modules: Iterable[Any]) -> list[Candidate]:
    """Every non-yanked module whose repository is a public GitHub URL."""

    found: list[Candidate] = []
    for module in modules:
        if not isinstance(module, dict):
            continue
        if module.get("yanked"):
            continue
        name = module.get("name")
        repository = normalize_github_repository(module.get("repository", ""))
        if not isinstance(name, str) or repository is None:
            continue
        found.append(
            Candidate(
                coordinate=repository,
                kind="github",
                repository=repository,
                module=name,
                description=str(module.get("description") or ""),
                sources=("mooncakes",),
            )
        )
    return found


@dataclass
class SearchHit:
    repository: str
    path: str
    query: str
    source: str


def candidates_from_search_items(
    items: Iterable[Any], source: str, query: str
) -> tuple[list[Candidate], list[SearchHit]]:
    """Turn GitHub search items into candidates and evidence hits."""

    candidates: list[Candidate] = []
    hits: list[SearchHit] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        repository = item.get("repository")
        if isinstance(repository, dict):
            full_name = repository.get("full_name")
        else:
            full_name = item.get("full_name")
        if not isinstance(full_name, str):
            continue
        normalized = normalize_coordinate(full_name)
        if normalized is None or normalized[0] != "github":
            continue
        coordinate = normalized[1]
        candidates.append(
            Candidate(
                coordinate=coordinate,
                kind="github",
                repository=coordinate,
                description=str(item.get("description") or ""),
                sources=(source,),
            )
        )
        path = item.get("path")
        if not isinstance(path, str) and source == "repo_search":
            # Repository search matched the README, so the README is the
            # evidence to fetch. Code search always reports a real path.
            path = "README.md"
        if isinstance(path, str):
            hits.append(
                SearchHit(
                    repository=coordinate,
                    path=path,
                    query=query,
                    source=source,
                )
            )
    return candidates, hits


def candidates_from_readme(text: str) -> list[Candidate]:
    """Coordinates documented as ``moon binstall <coordinate>`` examples."""

    found: list[Candidate] = []
    for match in README_COMMAND.finditer(text):
        normalized = normalize_coordinate(match.group(1))
        if normalized is None:
            continue
        kind, coordinate = normalized
        found.append(
            Candidate(
                coordinate=coordinate,
                kind=kind,
                repository=coordinate if kind == "github" else "",
                sources=("readme",),
            )
        )
    return found


def merge_candidates(candidates: Iterable[Candidate]) -> list[Candidate]:
    """Deduplicate by coordinate and merge discovery sources."""

    merged: dict[str, Candidate] = {}
    for candidate in candidates:
        key = candidate.key
        existing = merged.get(key)
        if existing is None:
            merged[key] = candidate
            continue
        sources = tuple(sorted(set(existing.sources) | set(candidate.sources)))
        merged[key] = Candidate(
            coordinate=existing.coordinate,
            kind=existing.kind,
            repository=existing.repository or candidate.repository,
            module=existing.module or candidate.module,
            description=existing.description or candidate.description,
            sources=sources,
        )
    return sorted(merged.values(), key=lambda item: item.coordinate.casefold())


@dataclass
class Discovery:
    candidates: list[Candidate] = field(default_factory=list)
    hits: list[SearchHit] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    stats: dict[str, int] = field(default_factory=dict)
    sources_ok: int = 0
    sources_failed: int = 0


def discover(
    client: Client,
    readme_text: str = "",
    max_search_pages: int = 2,
    log: Any = None,
) -> Discovery:
    """Collect candidates from every available public source."""

    result = Discovery()
    collected: list[Candidate] = []

    def warn(message: str) -> None:
        result.warnings.append(message)
        if log is not None:
            log(message)

    # Mooncakes registry: the only complete enumeration of published modules.
    try:
        modules = client.get_json(MOONCAKES_MODULES_URL)
        if not isinstance(modules, list):
            raise HttpError("the registry list is not a JSON array")
        found = candidates_from_mooncakes(modules)
        collected.extend(found)
        result.stats["mooncakes_modules"] = len(modules)
        result.stats["mooncakes_candidates"] = len(found)
        result.sources_ok += 1
    except (HttpError, ValueError) as error:
        result.sources_failed += 1
        warn(f"mooncakes discovery failed: {error}")

    # GitHub code search: explicit manifests and usage strings.
    code_search_failed = False
    for query in CODE_SEARCH_QUERIES:
        if code_search_failed:
            break
        try:
            items: list[Any] = []
            for page in client.paginate(
                GITHUB_CODE_SEARCH_URL,
                {"q": query, "per_page": 100},
                max_pages=max_search_pages,
            ):
                if isinstance(page, dict):
                    items.extend(page.get("items") or [])
            found, hits = candidates_from_search_items(items, "code_search", query)
            collected.extend(found)
            result.hits.extend(hits)
            result.stats[f"code_search:{query}"] = len(items)
            result.sources_ok += 1
        except RateLimited:
            code_search_failed = True
            result.sources_failed += 1
            warn(f"code search rate limited at query {query!r}")
        except (HttpError, ValueError) as error:
            result.sources_failed += 1
            warn(f"code search failed for {query!r}: {error}")

    # Repository search: README mentions, including adoption evidence.
    repo_search_failed = False
    for query in REPO_SEARCH_QUERIES:
        if repo_search_failed:
            break
        try:
            items = []
            for page in client.paginate(
                GITHUB_REPO_SEARCH_URL,
                {"q": query, "per_page": 100},
                max_pages=max_search_pages,
            ):
                if isinstance(page, dict):
                    items.extend(page.get("items") or [])
            found, hits = candidates_from_search_items(items, "repo_search", query)
            collected.extend(found)
            result.hits.extend(hits)
            result.stats[f"repo_search:{query}"] = len(items)
            result.sources_ok += 1
        except RateLimited:
            repo_search_failed = True
            result.sources_failed += 1
            warn(f"repository search rate limited at query {query!r}")
        except (HttpError, ValueError) as error:
            result.sources_failed += 1
            warn(f"repository search failed for {query!r}: {error}")

    # Examples documented in this repository's own README.
    if readme_text:
        found = candidates_from_readme(readme_text)
        collected.extend(found)
        result.stats["readme_candidates"] = len(found)
        result.sources_ok += 1

    result.candidates = merge_candidates(collected)
    result.stats["candidates"] = len(result.candidates)
    return result
