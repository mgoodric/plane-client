"""Unit tests for plane_client.core — the HTTP layer is mocked, so these run
offline and assert the gotcha-handling behaviour the client exists to provide.
"""

from __future__ import annotations

import io
import json
import unittest
import urllib.error
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

from plane_client.core import (
    PlaneAPIError,
    PlaneClient,
    PlaneParseError,
    PlaneRateLimitError,
    RetryPolicy,
    resolve_ref,
    strip_control_chars,
)


PROJECT = "11111111-2222-3333-4444-555555555555"
ISSUE_UUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


class _FakeResp:
    def __init__(self, status: int, body: str):
        self.status = status
        self._body = body.encode("utf-8")

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> "_FakeResp":
        return self

    def __exit__(self, *exc: Any) -> None:
        return None


class _FakeHTTP:
    """Scripted urlopen replacement.

    `script` is a list of responses consumed in order. Each entry is either
    (status, body_dict_or_str) for a normal response, an HTTPError, or a
    URLError. Records every request for assertions.
    """

    def __init__(self, script: List[Any]):
        self.script = list(script)
        self.calls: List[Dict[str, Any]] = []

    def __call__(self, req: Any, timeout: Optional[float] = None) -> _FakeResp:
        data = req.data.decode("utf-8") if req.data else None
        self.calls.append({"method": req.method, "url": req.full_url, "data": data})
        item = self.script.pop(0)
        if isinstance(item, (urllib.error.HTTPError, urllib.error.URLError)):
            raise item
        status, body = item
        raw = body if isinstance(body, str) else json.dumps(body)
        return _FakeResp(status, raw)


def _client(script: List[Any], **kw: Any) -> Tuple[PlaneClient, _FakeHTTP]:
    fake = _FakeHTTP(script)
    retry = RetryPolicy(max_attempts=3, backoff_sec=0.0, sleeper=lambda s: None)
    client = PlaneClient(
        base="https://plane.example.com",
        workspace="ws",
        project=PROJECT,
        pat="tok",
        retry=retry,
        # Pre-seed states so no /states/ round-trip is needed by default.
        state_map={"todo": "state-todo", "done": "state-done"},
        **kw,
    )
    return client, fake


def _http_error(status: int, body: str = "") -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "https://plane.example.com", status, "err", {}, io.BytesIO(body.encode())
    )


class RefResolutionTest(unittest.TestCase):
    def test_uuid(self) -> None:
        self.assertEqual(resolve_ref(ISSUE_UUID), ("uuid", None))

    def test_bare_number(self) -> None:
        self.assertEqual(resolve_ref("42"), ("seq", 42))

    def test_prefixed(self) -> None:
        self.assertEqual(resolve_ref("PROJ-42"), ("seq", 42))
        self.assertEqual(resolve_ref("oe-7"), ("seq", 7))

    def test_bad(self) -> None:
        with self.assertRaises(ValueError):
            resolve_ref("not-a-ref-x")


class ControlCharTest(unittest.TestCase):
    def test_strip(self) -> None:
        self.assertEqual(strip_control_chars("a\x00b\x07c"), "abc")
        # Whitespace we keep.
        self.assertEqual(strip_control_chars("a\tb\nc"), "a\tb\nc")

    def test_polluted_response_still_parses(self) -> None:
        polluted = '{"id": "x", "name": "a\x07b"}'
        client, fake = _client([(200, polluted)])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            out = client.request("GET", "/x")
        self.assertEqual(out["name"], "ab")


class RateLimitTest(unittest.TestCase):
    def test_429_then_success_retries(self) -> None:
        client, fake = _client([_http_error(429, "rate"), (200, {"ok": True})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            out = client.request("GET", "/x")
        self.assertEqual(out, {"ok": True})
        self.assertEqual(len(fake.calls), 2)

    def test_429_exhausted_raises_ratelimit(self) -> None:
        client, fake = _client([_http_error(429), _http_error(429), _http_error(429)])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            with self.assertRaises(PlaneRateLimitError):
                client.request("GET", "/x")


class NetworkErrorTest(unittest.TestCase):
    def test_urlerror_retries_then_raises(self) -> None:
        err = urllib.error.URLError("conn refused")
        client, fake = _client([err, err, err])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            with self.assertRaises(PlaneAPIError):
                client.request("GET", "/x")
        self.assertEqual(len(fake.calls), 3)


class ParseErrorTest(unittest.TestCase):
    def test_empty_body_is_none(self) -> None:
        client, fake = _client([(204, "")])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            self.assertIsNone(client.request("DELETE", "/x", expect=(204,)))

    def test_unparseable_200_raises(self) -> None:
        client, fake = _client([(200, "<html>maintenance</html>")])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            with self.assertRaises(PlaneParseError):
                client.request("GET", "/x")

    def test_valid_empty_list_is_fine(self) -> None:
        client, fake = _client([(200, {"results": [], "count": 0})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            out = client.request("GET", "/x")
        self.assertEqual(out, {"results": [], "count": 0})


class ApostropheSafetyTest(unittest.TestCase):
    def test_apostrophe_body_is_json_encoded(self) -> None:
        client, fake = _client([(201, {"id": "c1"})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            client.comment(ISSUE_UUID, "it's a \"tricky\" body")
        # The guarantee is that the body rides as valid JSON (no string-interp
        # 400s); json.loads succeeding on the raw request data proves it. Assert
        # on a word pandoc leaves alone (it may smart-quote the punctuation).
        sent = json.loads(fake.calls[0]["data"])
        self.assertIn("tricky", sent["comment_html"])

    def test_html_body_preserved_verbatim(self) -> None:
        # An HTML body bypasses markdown conversion, so a literal apostrophe
        # survives byte-for-byte and still transports as valid JSON.
        client, fake = _client([(201, {"id": "c1"})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            client.comment(ISSUE_UUID, "<p>it's a 'literal' body</p>")
        sent = json.loads(fake.calls[0]["data"])
        self.assertEqual(sent["comment_html"], "<p>it's a 'literal' body</p>")


class SeqResolutionTest(unittest.TestCase):
    def test_resolves_seq_by_paginating(self) -> None:
        # Plane ignores the seq filter, so the client must scan the list.
        page = {
            "results": [
                {"id": "u1", "sequence_id": 1},
                {"id": ISSUE_UUID, "sequence_id": 42},
            ],
            "next_page_results": False,
            "next_cursor": "x",
        }
        issue = {"id": ISSUE_UUID, "sequence_id": 42, "name": "found"}
        client, fake = _client([(200, page), (200, issue)])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            out = client.get("42")
        self.assertEqual(out["name"], "found")
        # Second call is the direct GET on the resolved UUID.
        self.assertIn(ISSUE_UUID, fake.calls[1]["url"])


class PaginationTest(unittest.TestCase):
    def test_stops_on_next_page_results_false(self) -> None:
        # next_cursor is present on the LAST page; next_page_results is the
        # real stop signal (trusting next_cursor loops forever).
        last = {
            "results": [{"id": "u1", "sequence_id": 1}],
            "next_page_results": False,
            "next_cursor": "still-here",
        }
        client, fake = _client([(200, last)])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            items = client.list()
        self.assertEqual(len(items), 1)
        self.assertEqual(len(fake.calls), 1)

    def test_follows_multiple_pages(self) -> None:
        p1 = {
            "results": [{"id": "u1", "sequence_id": 1}],
            "next_page_results": True,
            "next_cursor": "100:1:0",
        }
        p2 = {
            "results": [{"id": "u2", "sequence_id": 2}],
            "next_page_results": False,
            "next_cursor": "100:2:0",
        }
        client, fake = _client([(200, p1), (200, p2)])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            items = client.list()
        self.assertEqual([i["sequence_id"] for i in items], [1, 2])


class StateResolutionTest(unittest.TestCase):
    def test_seeded_state_map(self) -> None:
        client, fake = _client([(200, {"id": ISSUE_UUID})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            client.set_state(ISSUE_UUID, "Done")
        self.assertEqual(json.loads(fake.calls[0]["data"])["state"], "state-done")

    def test_dynamic_state_fetch(self) -> None:
        # No seeded map → the client fetches /states/ and resolves by name.
        fake = _FakeHTTP(
            [
                (200, {"results": [{"id": "s-review", "name": "In Review"}]}),
                (200, {"id": ISSUE_UUID}),
            ]
        )
        client = PlaneClient(
            base="https://plane.example.com",
            workspace="ws",
            project=PROJECT,
            pat="tok",
            retry=RetryPolicy(max_attempts=1, sleeper=lambda s: None),
        )
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            client.set_state(ISSUE_UUID, "in review")
        self.assertEqual(json.loads(fake.calls[1]["data"])["state"], "s-review")

    def test_unknown_state_raises(self) -> None:
        client, _ = _client([])
        with self.assertRaises(ValueError):
            client.set_state(ISSUE_UUID, "no-such-state")


class CreateTest(unittest.TestCase):
    def test_create_with_parent_patches_after(self) -> None:
        created = {"id": "new-id", "sequence_id": 7}
        parent_page = {
            "results": [{"id": "parent-uuid", "sequence_id": 3}],
            "next_page_results": False,
        }
        client, fake = _client([(201, created), (200, parent_page), (200, {})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            out = client.create(title="t", body_md="b", state="todo", parent="3")
        self.assertEqual(out["parent"], "parent-uuid")
        self.assertEqual(fake.calls[0]["method"], "POST")
        self.assertEqual(fake.calls[-1]["method"], "PATCH")

    def test_create_omits_unset_fields(self) -> None:
        client, fake = _client([(201, {"id": "n"})])
        with mock.patch("plane_client.core.urllib.request.urlopen", side_effect=fake):
            client.create(title="t")
        payload = json.loads(fake.calls[0]["data"])
        self.assertNotIn("state", payload)
        self.assertNotIn("labels", payload)
        self.assertNotIn("assignees", payload)
        self.assertEqual(payload["name"], "t")


class UrlForTest(unittest.TestCase):
    def test_url_for(self) -> None:
        client, _ = _client([])
        url = client.url_for({"id": ISSUE_UUID})
        self.assertEqual(
            url, f"https://plane.example.com/ws/projects/{PROJECT}/issues/{ISSUE_UUID}"
        )


if __name__ == "__main__":
    unittest.main()
