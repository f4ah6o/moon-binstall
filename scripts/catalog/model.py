"""Shared catalog data model.

The model is deliberately small: a candidate is a coordinate the CLI accepts,
a target result is what one dry-run observed for one target, and the state is
the last confirmed observation per candidate and target. Unknown observations
never replace a confirmed one, so a transient API failure cannot erase a
verified entry.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

TARGETS = (
    "linux-x86_64",
    "linux-aarch64",
    "darwin-x86_64",
    "darwin-aarch64",
)

TARGET_LABELS = {
    "linux-x86_64": "Linux x64",
    "linux-aarch64": "Linux ARM64",
    "darwin-x86_64": "macOS x64",
    "darwin-aarch64": "macOS ARM64",
}

VERIFIED = "verified"
UNSUPPORTED = "unsupported"
UNKNOWN = "unknown"

STATUSES = (VERIFIED, UNSUPPORTED, UNKNOWN)

# Reason codes are stable identifiers, not user-facing prose. They are kept in
# the state file so a later run can explain why a candidate is not listed.
REASON_RESOLVED = "resolved"
REASON_NO_RELEASE = "no_release"
REASON_NO_ASSET = "no_matching_asset"
REASON_MODULE_NOT_FOUND = "module_not_found"
REASON_NO_GITHUB_RELEASE = "no_github_release"
REASON_RATE_LIMITED = "rate_limited"
REASON_TRANSPORT = "transport"
REASON_HTTP_ERROR = "http_error"
REASON_TIMEOUT = "timeout"
REASON_INVALID_RESPONSE = "invalid_response"
REASON_UNCLASSIFIED = "unclassified"
REASON_NOT_CHECKED = "not_checked"

REASON_TEXT = {
    REASON_RESOLVED: "release asset resolved",
    REASON_NO_RELEASE: "no GitHub release",
    REASON_NO_ASSET: "no matching release asset",
    REASON_MODULE_NOT_FOUND: "Mooncakes module not found",
    REASON_NO_GITHUB_RELEASE: "no GitHub release for the module version",
    REASON_RATE_LIMITED: "GitHub API rate limit",
    REASON_TRANSPORT: "network or transport failure",
    REASON_HTTP_ERROR: "unexpected HTTP status",
    REASON_TIMEOUT: "dry-run timed out",
    REASON_INVALID_RESPONSE: "unexpected API response",
    REASON_UNCLASSIFIED: "unclassified dry-run failure",
    REASON_NOT_CHECKED: "not checked yet",
}

# Sources that justify verifying a candidate on every run. Registry-only
# candidates rotate instead, so a daily scan stays inside the API budget.
EXPLICIT_SOURCES = ("code_search", "repo_search", "readme")

ADOPTION = "adoption"
INTEGRATION = "integration"
REFERENCE = "reference"

ADOPTION_CLASSES = (ADOPTION, INTEGRATION, REFERENCE)


@dataclass(frozen=True)
class Candidate:
    """A coordinate the CLI accepts, plus where it was discovered."""

    coordinate: str
    kind: str  # "github" or "mooncakes"
    repository: str = ""
    module: str = ""
    description: str = ""
    sources: tuple[str, ...] = ()

    @property
    def key(self) -> str:
        return candidate_key(self.coordinate, self.kind)


def candidate_key(coordinate: str, kind: str) -> str:
    """Deduplicate GitHub coordinates case-insensitively.

    GitHub owner/repository names are case-insensitive, so ``Owner/Repo`` and
    ``owner/repo`` are the same install target. Mooncakes module names are
    compared exactly: the registry is the authority for their spelling.
    """

    return coordinate.lower() if kind == "github" else coordinate


@dataclass
class TargetResult:
    status: str
    reason: str
    since: str
    tag: str = ""
    asset: str = ""
    binary: str = ""
    repository: str = ""
    detail: str = ""

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "status": self.status,
            "reason": self.reason,
            "since": self.since,
        }
        for name in ("tag", "asset", "binary", "repository", "detail"):
            value = getattr(self, name)
            if value:
                data[name] = value
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TargetResult":
        return cls(
            status=str(data.get("status", UNKNOWN)),
            reason=str(data.get("reason", REASON_UNCLASSIFIED)),
            since=str(data.get("since", "")),
            tag=str(data.get("tag", "")),
            asset=str(data.get("asset", "")),
            binary=str(data.get("binary", "")),
            repository=str(data.get("repository", "")),
            detail=str(data.get("detail", "")),
        )


@dataclass
class CandidateEntry:
    coordinate: str
    kind: str
    repository: str
    module: str
    description: str
    sources: list[str]
    first_seen: str
    targets: dict[str, TargetResult] = field(default_factory=dict)

    def target(self, name: str) -> TargetResult:
        return self.targets.get(
            name,
            TargetResult(status=UNKNOWN, reason=REASON_NOT_CHECKED, since=""),
        )

    def verified_targets(self) -> list[str]:
        return [name for name in TARGETS if self.target(name).status == VERIFIED]

    def binary_name(self) -> str:
        for name in TARGETS:
            result = self.target(name)
            if result.status == VERIFIED and result.binary:
                return result.binary
        return derive_binary(self.coordinate, self.kind)

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "coordinate": self.coordinate,
            "kind": self.kind,
            "sources": sorted(set(self.sources)),
            "first_seen": self.first_seen,
            "targets": {
                name: self.targets[name].to_dict()
                for name in TARGETS
                if name in self.targets
            },
        }
        for name in ("repository", "module", "description"):
            value = getattr(self, name)
            if value:
                data[name] = value
        return data

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "CandidateEntry":
        targets = {
            name: TargetResult.from_dict(value)
            for name, value in (data.get("targets") or {}).items()
            if name in TARGETS
        }
        return cls(
            coordinate=str(data.get("coordinate", "")),
            kind=str(data.get("kind", "github")),
            repository=str(data.get("repository", "")),
            module=str(data.get("module", "")),
            description=str(data.get("description", "")),
            sources=[str(item) for item in data.get("sources", [])],
            first_seen=str(data.get("first_seen", "")),
            targets=targets,
        )


@dataclass
class AdoptionEntry:
    repository: str
    classification: str
    evidence: list[str]
    since: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "repository": self.repository,
            "classification": self.classification,
            "evidence": sorted(set(self.evidence)),
            "since": self.since,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "AdoptionEntry":
        return cls(
            repository=str(data.get("repository", "")),
            classification=str(data.get("classification", REFERENCE)),
            evidence=[str(item) for item in data.get("evidence", [])],
            since=str(data.get("since", "")),
        )


@dataclass
class State:
    version: int = 1
    catalog_updated: str = ""
    body_sha256: str = ""
    candidates: dict[str, CandidateEntry] = field(default_factory=dict)
    adoption: dict[str, AdoptionEntry] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "version": self.version,
            "catalog_updated": self.catalog_updated,
            "body_sha256": self.body_sha256,
            "candidates": {
                key: self.candidates[key].to_dict()
                for key in sorted(self.candidates)
            },
            "adoption": {
                key: self.adoption[key].to_dict()
                for key in sorted(self.adoption)
            },
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "State":
        return cls(
            version=int(data.get("version", 1)),
            catalog_updated=str(data.get("catalog_updated", "")),
            body_sha256=str(data.get("body_sha256", "")),
            candidates={
                key: CandidateEntry.from_dict(value)
                for key, value in (data.get("candidates") or {}).items()
            },
            adoption={
                key: AdoptionEntry.from_dict(value)
                for key, value in (data.get("adoption") or {}).items()
            },
        )


def derive_binary(coordinate: str, kind: str) -> str:
    """The executable name the CLI derives from a coordinate.

    GitHub coordinates use the repository name with a trailing ``.mbt``
    removed; Mooncakes coordinates use the last package path component.
    """

    path = coordinate.split("@", 1)[0]
    parts = [part for part in path.split("/") if part]
    if not parts:
        return coordinate
    leaf = parts[-1]
    if kind == "github" and leaf.endswith(".mbt"):
        leaf = leaf[:-4]
    return leaf


def derive_repository(coordinate: str, kind: str) -> str:
    """Best-effort repository for a coordinate without a dry-run result."""

    path = coordinate.split("@", 1)[0]
    parts = [part for part in path.split("/") if part]
    if kind == "github" and len(parts) == 2:
        return "/".join(parts)
    return ""
