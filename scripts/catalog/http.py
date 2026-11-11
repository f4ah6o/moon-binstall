"""Minimal read-only HTTPS client for the catalog scan.

Only public endpoints are used. A GitHub token is read from ``GITHUB_TOKEN``
or ``GH_TOKEN`` and is sent only to ``api.github.com``; it is never included
in an exception message, a log line or a generated artifact.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Iterator

USER_AGENT = "moon-binstall-catalog/1"
MAX_BODY = 16 * 1024 * 1024
TOKEN_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")


class HttpError(Exception):
    """A request failed in a way the caller must classify."""


class NotFound(HttpError):
    """The server confirmed the resource does not exist (HTTP 404)."""


class RateLimited(HttpError):
    """The server refused the request because a rate limit is exhausted."""


@dataclass
class Response:
    status: int
    body: bytes
    headers: dict[str, str] = field(default_factory=dict)

    def json(self) -> Any:
        return json.loads(self.body.decode("utf-8"))

    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")


def _header(headers: Any, name: str) -> str:
    if headers is None:
        return ""
    value = headers.get(name)
    return "" if value is None else str(value)


def _rate_limit_reset(headers: Any) -> float | None:
    value = _header(headers, "x-ratelimit-reset")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _is_rate_limited(status: int, headers: Any) -> bool:
    if status == 429:
        return True
    if status != 403:
        return False
    return _header(headers, "x-ratelimit-remaining").strip() == "0"


def _next_link(headers: Any) -> str | None:
    link = _header(headers, "link")
    if not link:
        return None
    for part in link.split(","):
        match = re.search(r'<([^>]+)>\s*;\s*rel="next"', part)
        if match:
            return match.group(1)
    return None


class Client:
    """A small retrying client with explicit rate-limit handling."""

    def __init__(
        self,
        token: str | None = None,
        timeout: float = 30.0,
        retries: int = 3,
        max_wait: float = 60.0,
        sleep: Callable[[float], None] = time.sleep,
        opener: Callable[..., Any] = urllib.request.urlopen,
    ) -> None:
        if token is None:
            token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        token = (token or "").strip()
        self.token = token if TOKEN_PATTERN.match(token) else ""
        self.timeout = timeout
        self.retries = max(0, retries)
        self.max_wait = max_wait
        self.sleep = sleep
        self.opener = opener

    def _headers(self, url: str, accept: str) -> dict[str, str]:
        headers = {
            "Accept": accept,
            "User-Agent": USER_AGENT,
        }
        if self.token and url.startswith("https://api.github.com/"):
            headers["Authorization"] = "Bearer " + self.token
            headers["X-GitHub-Api-Version"] = "2022-11-28"
        return headers

    def get(
        self,
        url: str,
        params: dict[str, Any] | None = None,
        accept: str = "application/vnd.github+json",
    ) -> Response:
        if not url.startswith("https://"):
            raise HttpError("refusing a non-HTTPS URL")
        if params:
            query = urllib.parse.urlencode(params)
            url = url + ("&" if "?" in url else "?") + query
        last_error: Exception | None = None
        for attempt in range(self.retries + 1):
            request = urllib.request.Request(
                url, headers=self._headers(url, accept), method="GET"
            )
            try:
                with self.opener(request, timeout=self.timeout) as response:
                    body = response.read(MAX_BODY + 1)
                    if len(body) > MAX_BODY:
                        raise HttpError("response body exceeded the size limit")
                    return Response(
                        status=int(response.status),
                        body=body,
                        headers=dict(response.headers.items()),
                    )
            except urllib.error.HTTPError as error:
                headers = error.headers
                status = int(error.code)
                if status == 404:
                    raise NotFound(url) from None
                if _is_rate_limited(status, headers):
                    reset = _rate_limit_reset(headers)
                    wait = None if reset is None else reset - time.time()
                    if (
                        wait is not None
                        and 0 <= wait <= self.max_wait
                        and attempt < self.retries
                    ):
                        self.sleep(wait + 1)
                        last_error = RateLimited(url)
                        continue
                    raise RateLimited(url) from None
                if status >= 500 and attempt < self.retries:
                    last_error = HttpError(f"HTTP {status}")
                    self.sleep(min(2**attempt, 8))
                    continue
                raise HttpError(f"HTTP {status}") from None
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last_error = error
                if attempt < self.retries:
                    self.sleep(min(2**attempt, 8))
                    continue
                raise HttpError("network failure") from None
        raise HttpError(str(last_error) if last_error else "request failed")

    def get_json(
        self,
        url: str,
        params: dict[str, Any] | None = None,
        accept: str = "application/vnd.github+json",
    ) -> Any:
        response = self.get(url, params=params, accept=accept)
        try:
            return response.json()
        except (ValueError, UnicodeDecodeError) as error:
            raise HttpError("invalid JSON response") from error

    def get_text(self, url: str) -> str | None:
        """Fetch a raw file; a confirmed 404 returns None."""

        try:
            return self.get(url, accept="text/plain").text()
        except NotFound:
            return None

    def paginate(
        self,
        url: str,
        params: dict[str, Any] | None = None,
        max_pages: int = 3,
    ) -> Iterator[Any]:
        """Yield JSON pages, following GitHub's ``Link: rel="next"``."""

        next_url: str | None = url
        page = 0
        while next_url and page < max_pages:
            response = self.get(next_url, params=params if page == 0 else None)
            try:
                yield response.json()
            except (ValueError, UnicodeDecodeError) as error:
                raise HttpError("invalid JSON response") from error
            next_url = _next_link(response.headers)
            page += 1
