"""PlaneClient — a small, dependency-free client for the Plane REST API.

Plane (https://plane.so, self-hostable) has a handful of API behaviours that
bite anyone who talks to it with ad-hoc ``curl``/``requests`` code. This module
encodes them once:

- **Control chars in JSON.** Plane echoes raw control characters back inside
  ``description_html`` / ``comment_html``. ``json.loads`` rejects them even
  though the write succeeded — so they are stripped before parsing, and a
  failed parse is *not* retried (the write already happened).
- **Rate limiting (429).** Plane 429s on a per-token per-minute budget. Unlike
  the control-char case, a 429 means the request did *not* happen, so it is
  retried after a backoff.
- **Apostrophe/quote 400s.** Bodies built by string interpolation 400 when they
  contain apostrophes or quotes. Everything here goes through ``json.dumps``
  end to end, so arbitrary text is safe.
- **Cursor pagination.** List endpoints paginate via a cursor, and the
  ``next_cursor`` field is present *even on the last page* — the real
  "is there more?" signal is the ``next_page_results`` boolean. Trusting
  ``next_cursor`` alone is an infinite loop.
- **Silently-ignored filters.** Some server-side list filters (e.g. filtering
  the issues list by ``state``) are accepted but ignored, returning the full
  project. This client post-filters client-side so callers get what they asked
  for.
- **Three reference flavours.** Issues can be addressed by UUID, by bare
  sequence number (``42``), or by the project's identifier form (``PROJ-42``).
  All three resolve here.

Zero third-party dependencies — standard library only.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Iterator, List, Optional, Tuple


_UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE
)
# A bare sequence number, optionally prefixed by the project identifier
# (e.g. "PROJ-42", "proj-42", or just "42").
_SEQ_REF_RE = re.compile(r"^(?:[A-Za-z][A-Za-z0-9]*-)?(\d+)$")

# Plane sometimes echoes raw control chars in *_html fields; json.loads rejects
# them but the write succeeded.
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


class PlaneAPIError(RuntimeError):
    """Non-2xx response from the Plane API (after any 429 retries were exhausted)."""

    def __init__(self, status: int, url: str, body: str = ""):
        self.status = status
        self.url = url
        self.body = body
        super().__init__(f"Plane API {status} on {url}: {body[:200]}")


class PlaneRateLimitError(PlaneAPIError):
    """A 429 that survived every retry attempt."""


class PlaneParseError(PlaneAPIError):
    """An HTTP-2xx response whose body is not valid JSON after stripping control chars.

    Raised rather than silently returning an empty result, so that (for example)
    an OAuth2-proxy login/maintenance HTML page served in front of Plane with a
    200 status surfaces as a hard error instead of "0 results".
    """


def strip_control_chars(raw: str) -> str:
    r"""Remove control chars (except ``\t \n \r``) so ``json.loads`` survives echoes."""
    return _CONTROL_CHARS_RE.sub("", raw)


def resolve_ref(ref: str) -> Tuple[str, Optional[int]]:
    """Classify a reference string.

    Returns ``(kind, seq)`` where ``kind`` is ``"uuid"`` or ``"seq"`` and ``seq``
    is the numeric sequence id when known. Raises ``ValueError`` otherwise.
    """
    ref = ref.strip()
    if _UUID_RE.match(ref):
        return "uuid", None
    m = _SEQ_REF_RE.match(ref)
    if m:
        return "seq", int(m.group(1))
    raise ValueError(f"unrecognized ref: {ref!r} (expected PROJ-N, N, or a UUID)")


@dataclass
class RetryPolicy:
    """How the client retries 429s and transient network errors."""

    max_attempts: int = 3
    backoff_sec: float = 61.0
    # A hook so tests can inject a fast fake without patching time.sleep globally.
    sleeper: Callable[[float], None] = time.sleep


@dataclass
class PlaneClient:
    """A client bound to one Plane project.

    ``base`` is the Plane instance URL (e.g. ``https://plane.example.com``),
    ``workspace`` the workspace slug, ``project`` the project UUID, and ``pat``
    a personal access token. Prefer :meth:`from_env` to build one from the
    environment.

    ``state_map`` optionally pre-seeds name→UUID state resolution; when omitted,
    states are fetched from the project's ``/states/`` endpoint on first use.
    """

    base: str
    workspace: str
    project: str
    pat: str
    timeout: float = 20.0
    retry: RetryPolicy = field(default_factory=RetryPolicy)
    state_map: Optional[Dict[str, str]] = None
    # Per-instance caches, populated lazily.
    _seq_cache: Dict[int, str] = field(default_factory=dict)
    _states: Optional[Dict[str, str]] = field(default=None, repr=False)

    def __post_init__(self) -> None:
        if self.state_map:
            self._states = {k.strip().lower(): v for k, v in self.state_map.items()}

    # ---- construction --------------------------------------------------

    @classmethod
    def from_env(
        cls,
        *,
        pat_file: Optional[str] = None,
        retry: Optional[RetryPolicy] = None,
        timeout: Optional[float] = None,
        state_map: Optional[Dict[str, str]] = None,
    ) -> "PlaneClient":
        """Build a client from environment variables.

        Required: ``PLANE_BASE``, ``PLANE_WORKSPACE``, ``PLANE_PROJECT``, and a
        token via either ``PLANE_PAT`` (wins) or ``PLANE_PAT_FILE`` (a path to a
        file containing the token; also settable via the ``pat_file`` argument).

        ``timeout`` and ``retry`` override the latency/retry behaviour — e.g.
        pass ``retry=RetryPolicy(max_attempts=1)`` for a fast-fail client that
        does not sit through the 429 backoff.
        """
        base = _require_env("PLANE_BASE")
        workspace = _require_env("PLANE_WORKSPACE")
        project = _require_env("PLANE_PROJECT")

        pat = os.environ.get("PLANE_PAT", "").strip()
        if not pat:
            path = pat_file or os.environ.get("PLANE_PAT_FILE")
            if not path:
                raise RuntimeError(
                    "no token: set PLANE_PAT, or PLANE_PAT_FILE / pat_file to a "
                    "file containing the token"
                )
            pat_path = Path(os.path.expanduser(path))
            if not pat_path.is_file():
                raise RuntimeError(f"PLANE_PAT_FILE not found: {pat_path}")
            pat = pat_path.read_text().strip()
        if not pat:
            raise RuntimeError("token is empty")

        kwargs: Dict[str, Any] = dict(
            base=base,
            workspace=workspace,
            project=project,
            pat=pat,
            retry=retry or RetryPolicy(),
            state_map=state_map,
        )
        if timeout is not None:
            kwargs["timeout"] = timeout
        return cls(**kwargs)

    # ---- HTTP layer ----------------------------------------------------

    def _url(self, path: str) -> str:
        return f"{self.base.rstrip('/')}{path}"

    def _project_path(self, tail: str = "") -> str:
        return f"/api/v1/workspaces/{self.workspace}/projects/{self.project}{tail}"

    def request(
        self,
        method: str,
        path_or_url: str,
        *,
        body: Any = None,
        query: Optional[Dict[str, Any]] = None,
        expect: Iterable[int] = (200, 201),
    ) -> Any:
        """Perform an HTTP request against Plane, with 429 retry + control-char strip.

        ``body``, if given, is JSON-encoded (``json.dumps`` → utf-8). Never string
        interpolate user input into JSON — that is the apostrophe-400 trap.

        ``path_or_url`` may be an absolute URL (e.g. a paginated ``next`` link
        returned by Plane) or a path starting with ``/``.
        """
        url = path_or_url if path_or_url.startswith("http") else self._url(path_or_url)
        if query:
            # Only add non-None values; skip empty strings too — Plane treats
            # `state=` as "state is empty string" which returns nothing.
            filtered = {k: v for k, v in query.items() if v is not None and v != ""}
            if filtered:
                sep = "&" if "?" in url else "?"
                url = f"{url}{sep}{urllib.parse.urlencode(filtered)}"

        data: Optional[bytes] = None
        headers = {"X-API-Key": self.pat, "Accept": "application/json"}
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"

        expect_set = set(expect)
        last_status = 0
        last_body = ""
        for attempt in range(1, self.retry.max_attempts + 1):
            req = urllib.request.Request(url, method=method, data=data, headers=headers)
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    last_status = resp.status
                    raw = resp.read().decode("utf-8", errors="replace")
            except urllib.error.HTTPError as e:
                last_status = e.code
                try:
                    raw = e.read().decode("utf-8", errors="replace")
                except Exception:
                    raw = ""
                last_body = raw
                if last_status == 429 and attempt < self.retry.max_attempts:
                    self.retry.sleeper(self.retry.backoff_sec)
                    continue
                if last_status in expect_set:
                    # HTTPError raised for a status we accept (e.g. 204).
                    try:
                        return _parse_body(raw)
                    except PlaneParseError as pe:
                        raise PlaneParseError(last_status, url, pe.body) from pe
                raise _wrap_error(last_status, url, raw)
            except urllib.error.URLError as e:
                # Network hiccup — treat like a 429 for retry purposes.
                if attempt < self.retry.max_attempts:
                    self.retry.sleeper(self.retry.backoff_sec)
                    continue
                raise PlaneAPIError(0, url, str(e))

            # 2xx path.
            last_body = raw
            if last_status in expect_set:
                try:
                    return _parse_body(raw)
                except PlaneParseError as pe:
                    raise PlaneParseError(last_status, url, pe.body) from pe
            raise _wrap_error(last_status, url, raw)

        raise _wrap_error(last_status, url, last_body)

    # ---- ref + state resolution ---------------------------------------

    def _uuid_for_ref(self, ref: str) -> str:
        kind, seq = resolve_ref(ref)
        if kind == "uuid":
            return ref
        assert seq is not None
        if seq in self._seq_cache:
            return self._seq_cache[seq]
        # Plane's issues list silently ignores a server-side `sequence_id`
        # filter, so we paginate the full list and match client-side.
        for item in self.iter_list(per_page=100):
            if int(item.get("sequence_id", -1)) == seq:
                uuid = item["id"]
                self._seq_cache[seq] = uuid
                return uuid
        raise PlaneAPIError(
            404, self._project_path("/issues/"), f"no issue with sequence_id={seq}"
        )

    def states(self, *, refresh: bool = False) -> Dict[str, str]:
        """Return this project's ``{lowercased state name: uuid}`` map.

        Fetched from the project's ``/states/`` endpoint once and cached; pass
        ``refresh=True`` to re-fetch, or seed ``state_map`` at construction to
        skip the request entirely.
        """
        if self._states is not None and not refresh:
            return self._states
        data = self.request("GET", self._project_path("/states/"))
        mapping = {
            str(s["name"]).strip().lower(): s["id"]
            for s in _extract_results(data)
            if s.get("name") and s.get("id")
        }
        self._states = mapping
        return mapping

    def _state_uuid(self, state: str) -> str:
        if _UUID_RE.match(state):
            return state
        key = state.strip().lower()
        states = self.states()
        if key in states:
            return states[key]
        raise ValueError(
            f"unknown state name: {state!r} (known: {sorted(states)})"
        )

    # ---- public verbs --------------------------------------------------

    def get(self, ref: str) -> Dict[str, Any]:
        """Fetch a single issue by ref (UUID / ``PROJ-N`` / ``N``)."""
        uuid = self._uuid_for_ref(ref)
        return self.request("GET", self._project_path(f"/issues/{uuid}/"))

    def list(
        self,
        *,
        state: Optional[str] = None,
        per_page: int = 100,
        max_pages: Optional[int] = None,
    ) -> List[Dict[str, Any]]:
        """List issues (optionally filtered by state name), following pagination."""
        return list(self.iter_list(state=state, per_page=per_page, max_pages=max_pages))

    def iter_list(
        self,
        *,
        state: Optional[str] = None,
        per_page: int = 100,
        max_pages: Optional[int] = None,
    ) -> Iterator[Dict[str, Any]]:
        """Yield issues one at a time, following cursor pagination to exhaustion.

        Plane's issues endpoint ignores a server-side state filter, so filtering
        is done client-side here — callers still get exactly the state they
        asked for.
        """
        state_uuid = self._state_uuid(state) if state else None
        query: Dict[str, Any] = {"per_page": per_page}
        # Also pass the (currently no-op) state param — harmless, and free
        # narrowing if Plane ever wires the filter up.
        if state_uuid:
            query["state"] = state_uuid
        url = self._project_path("/issues/")
        pages = 0
        while True:
            data = self.request("GET", url, query=query)
            for item in _extract_results(data):
                if state_uuid is None or item.get("state") == state_uuid:
                    yield item
            pages += 1
            if max_pages is not None and pages >= max_pages:
                return
            next_cursor = _next_cursor(data)
            if not next_cursor:
                return
            url, query = self._advance(
                self._project_path("/issues/"), next_cursor, per_page, state_uuid
            )

    def comment(self, ref: str, body: str) -> Dict[str, Any]:
        """Post a comment. ``body`` may be markdown or HTML (markdown is converted).

        Bodies go over the wire via ``json.dumps``; apostrophes and quotes are safe.
        """
        uuid = self._uuid_for_ref(ref)
        html = markdown_to_html(body) if not _looks_like_html(body) else body
        return self.request(
            "POST",
            self._project_path(f"/issues/{uuid}/comments/"),
            body={"comment_html": html},
            expect=(200, 201),
        )

    def list_comments(
        self,
        ref: str,
        *,
        per_page: int = 100,
        max_pages: Optional[int] = None,
    ) -> List[Dict[str, Any]]:
        """List all comments on an issue, following cursor pagination."""
        return list(self.iter_comments(ref, per_page=per_page, max_pages=max_pages))

    def iter_comments(
        self,
        ref: str,
        *,
        per_page: int = 100,
        max_pages: Optional[int] = None,
    ) -> Iterator[Dict[str, Any]]:
        """Yield an issue's comments, following cursor pagination to exhaustion.

        **Ordering:** Plane's ``/comments/`` endpoint returns comments
        *newest-first*. Do not assume oldest-first, and do not take
        ``list_comments(ref)[-1]`` to get the latest comment — that yields the
        *oldest*. Use :meth:`latest_comment` (which selects by ``created_at``
        rather than trusting server position) when you want the most recent one.
        """
        uuid = self._uuid_for_ref(ref)
        base_path = self._project_path(f"/issues/{uuid}/comments/")
        query: Dict[str, Any] = {"per_page": per_page}
        url = base_path
        pages = 0
        while True:
            data = self.request("GET", url, query=query)
            for item in _extract_results(data):
                yield item
            pages += 1
            if max_pages is not None and pages >= max_pages:
                return
            next_cursor = _next_cursor(data)
            if not next_cursor:
                return
            url, query = self._advance(base_path, next_cursor, per_page, None)

    def latest_comment(self, ref: str) -> Optional[Dict[str, Any]]:
        """Return the newest comment on an issue, or ``None`` if there are none.

        Plane returns comments newest-first, but that ordering is undocumented
        server behaviour — so rather than trust position (e.g. taking the first
        or last element of :meth:`list_comments`), this collects every comment
        and returns the one with the maximum ``created_at``. Comments missing a
        ``created_at`` sort as oldest, so a well-formed comment always wins.
        """
        newest: Optional[Dict[str, Any]] = None
        newest_key = ""
        for comment in self.iter_comments(ref):
            key = str(comment.get("created_at") or "")
            if newest is None or key > newest_key:
                newest = comment
                newest_key = key
        return newest

    def get_comment(self, ref: str, comment_id: str) -> Dict[str, Any]:
        """Fetch a single comment by its UUID."""
        uuid = self._uuid_for_ref(ref)
        return self.request(
            "GET",
            self._project_path(f"/issues/{uuid}/comments/{comment_id}/"),
        )

    def patch_comment(self, ref: str, comment_id: str, body: str) -> Dict[str, Any]:
        """Update a specific comment in place (useful for a single, overwritten
        status/heartbeat comment). ``body`` may be markdown or HTML.
        """
        uuid = self._uuid_for_ref(ref)
        html = markdown_to_html(body) if not _looks_like_html(body) else body
        return self.request(
            "PATCH",
            self._project_path(f"/issues/{uuid}/comments/{comment_id}/"),
            body={"comment_html": html},
            expect=(200,),
        )

    def set_state(self, ref: str, state: str) -> Dict[str, Any]:
        """Move an issue to ``state`` (a state name or a state UUID)."""
        uuid = self._uuid_for_ref(ref)
        state_uuid = self._state_uuid(state)
        return self.request(
            "PATCH",
            self._project_path(f"/issues/{uuid}/"),
            body={"state": state_uuid},
        )

    def create(
        self,
        *,
        title: str,
        body_md: str = "",
        state: Optional[str] = None,
        labels: Optional[List[str]] = None,
        assignees: Optional[List[str]] = None,
        priority: str = "none",
        parent: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Create an issue.

        ``state`` is a name or UUID (omit to let Plane pick the default). ``labels``
        and ``assignees`` are lists of UUIDs. ``parent`` (a ref) is PATCHed after
        creation, since Plane's create endpoint does not accept it reliably; a
        failed parent link is non-fatal and reported as ``parent=None``.
        """
        payload: Dict[str, Any] = {
            "name": title,
            "description_html": markdown_to_html(body_md),
            "priority": priority,
        }
        if state is not None:
            payload["state"] = self._state_uuid(state)
        if labels is not None:
            payload["labels"] = labels
        if assignees is not None:
            payload["assignees"] = assignees
        created = self.request(
            "POST", self._project_path("/issues/"), body=payload, expect=(200, 201)
        )
        if parent:
            parent_uuid = self._uuid_for_ref(parent)
            try:
                self.request(
                    "PATCH",
                    self._project_path(f"/issues/{created['id']}/"),
                    body={"parent": parent_uuid},
                )
                created["parent"] = parent_uuid
            except PlaneAPIError:
                created["parent"] = None
        return created

    # ---- convenience helpers ------------------------------------------

    def url_for(self, issue: Dict[str, Any]) -> str:
        """Browser URL for an issue dict (as returned by :meth:`get`/:meth:`create`)."""
        return (
            f"{self.base.rstrip('/')}/{self.workspace}/projects/"
            f"{self.project}/issues/{issue['id']}"
        )

    def _advance(
        self,
        base_path: str,
        next_cursor: str,
        per_page: int,
        state_uuid: Optional[str],
    ) -> Tuple[str, Dict[str, Any]]:
        """Compute the (url, query) for the next page from a next_cursor value,
        which Plane may return as an absolute URL, a query fragment, or a token.
        """
        if next_cursor.startswith("http"):
            return next_cursor, {}
        if next_cursor.startswith("?") or "=" in next_cursor:
            return f"{base_path}?{next_cursor.lstrip('?')}", {}
        query: Dict[str, Any] = {"per_page": per_page, "cursor": next_cursor}
        if state_uuid:
            query["state"] = state_uuid
        return base_path, query


# --- module helpers (exposed for tests) ------------------------------------


def _require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        raise RuntimeError(f"required environment variable {name} is not set")
    return val


def _parse_body(raw: str) -> Any:
    """Parse a JSON response body after stripping Plane's control-char pollution.

    Empty body returns None (Plane's 204 shape). A body that still won't parse
    raises :class:`PlaneParseError`; ``request`` re-raises it with URL/status.
    """
    if not raw:
        return None
    cleaned = strip_control_chars(raw)
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        try:
            return json.loads(cleaned.encode("utf-8", "ignore").decode("utf-8", "ignore"))
        except json.JSONDecodeError:
            raise PlaneParseError(0, "", raw)


def _wrap_error(status: int, url: str, body: str) -> PlaneAPIError:
    if status == 429:
        return PlaneRateLimitError(status, url, body)
    return PlaneAPIError(status, url, body)


def _extract_results(data: Any) -> List[Dict[str, Any]]:
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        return data.get("results") or data.get("data") or []
    return []


def _next_cursor(data: Any) -> Optional[str]:
    """Return the cursor for the next page, or None if there is no next page.

    Plane's list envelope ships a ``next_cursor`` string even on the LAST page,
    so the load-bearing "is there more?" signal is ``next_page_results``.
    Ignoring that is an infinite loop. Falls back to a bare ``next`` URL for
    endpoints that don't send ``next_page_results``.
    """
    if not isinstance(data, dict):
        return None
    if "next_page_results" in data:
        if not data.get("next_page_results"):
            return None
        cursor = data.get("next_cursor")
        if isinstance(cursor, str) and cursor:
            return cursor
        return None
    nxt = data.get("next")
    if isinstance(nxt, str) and nxt:
        return nxt
    return None


def _looks_like_html(text: str) -> bool:
    stripped = text.lstrip()
    return stripped.startswith("<") and ">" in stripped[:200]


def markdown_to_html(md: str) -> str:
    """Convert markdown to HTML, preferring pandoc when available and falling
    back to a minimal converter so this module has no hard dependency on it.
    """
    if not md:
        return ""
    pandoc = _find_pandoc()
    if pandoc:
        try:
            result = subprocess.run(
                [pandoc, "-f", "markdown", "-t", "html"],
                input=md,
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                return result.stdout
        except (FileNotFoundError, subprocess.TimeoutExpired):
            pass
    return _minimal_md_to_html(md)


def _find_pandoc() -> Optional[str]:
    for candidate in (
        "/opt/homebrew/bin/pandoc",
        "/usr/local/bin/pandoc",
        "/usr/bin/pandoc",
    ):
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


def _minimal_md_to_html(md: str) -> str:
    # Deliberately not a full renderer — just enough that paragraphs and headings
    # round-trip through Plane. Install pandoc for faithful conversion.
    lines = md.split("\n")
    out: List[str] = []
    para: List[str] = []

    def flush() -> None:
        if para:
            out.append("<p>" + " ".join(para).strip() + "</p>")
            para.clear()

    for line in lines:
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            flush()
            n = len(m.group(1))
            out.append(f"<h{n}>{m.group(2).strip()}</h{n}>")
            continue
        if not line.strip():
            flush()
            continue
        para.append(line.strip())
    flush()
    return "\n".join(out)
