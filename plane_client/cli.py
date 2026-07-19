"""``plane`` command — a thin CLI over :class:`plane_client.core.PlaneClient`.

Human-readable output by default; ``--json`` for machine use. Body arguments
support ``-`` for stdin and ``@FILE`` for a file (avoids shell argv limits and
quoting quirks). Configure via the ``PLANE_*`` environment variables (see
``PlaneClient.from_env``).
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, List, Optional

from .core import PlaneAPIError, PlaneClient, PlaneParseError, RetryPolicy


def _load_body(arg: str) -> str:
    """Positional ``body`` arg: literal text, ``-`` for stdin, or ``@path`` for a
    file (curl's convention, so ``plane comment REF "text"`` and
    ``plane comment REF @body.md`` both read naturally).
    """
    if arg == "-":
        return sys.stdin.read()
    if arg.startswith("@"):
        with open(arg[1:], "r", encoding="utf-8") as f:
            return f.read()
    return arg


def _load_body_file(arg: str) -> str:
    """``--body-file`` arg: a bare path, ``-`` for stdin, or ``@path``.

    Unlike ``_load_body``, a bare path always reads the file — the argument name
    says "file", so it is never treated as literal text. This avoids silently
    posting the literal string "./body.md" as the description.
    """
    if arg == "-":
        return sys.stdin.read()
    path = arg[1:] if arg.startswith("@") else arg
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def _state_name(client: PlaneClient, uuid: str) -> str:
    """Best-effort state UUID → name for human output; falls back to the UUID."""
    if not uuid:
        return "(none)"
    try:
        for name, sid in client.states().items():
            if sid == uuid:
                return name
    except Exception:
        pass
    return uuid


def _print_issue(issue: Dict[str, Any], client: PlaneClient, *, as_json: bool) -> None:
    if as_json:
        json.dump(issue, sys.stdout, indent=2, sort_keys=True)
        print()
        return
    seq = issue.get("sequence_id", "?")
    name = issue.get("name", "(no title)")
    state = _state_name(client, issue.get("state", ""))
    print(f"#{seq}  [{state}]  {name}")
    url = client.url_for(issue) if issue.get("id") else ""
    if url:
        print(f"  {url}")


def _cmd_get(args: argparse.Namespace, client: PlaneClient) -> int:
    _print_issue(client.get(args.ref), client, as_json=args.json)
    return 0


def _cmd_list(args: argparse.Namespace, client: PlaneClient) -> int:
    items = client.list(state=args.state, per_page=args.per_page)
    if args.json:
        json.dump(items, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        for it in items:
            _print_issue(it, client, as_json=False)
        print(f"\n{len(items)} issue(s)")
    return 0


def _cmd_comment(args: argparse.Namespace, client: PlaneClient) -> int:
    resp = client.comment(args.ref, _load_body(args.body))
    if args.json:
        json.dump(resp, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"posted comment {resp.get('id', '(unknown)')} on {args.ref}")
    return 0


def _cmd_comments(args: argparse.Namespace, client: PlaneClient) -> int:
    if args.comment_id:
        resp: Any = client.get_comment(args.ref, args.comment_id)
    else:
        resp = client.list_comments(args.ref, per_page=args.per_page)
    if args.json:
        json.dump(resp, sys.stdout, indent=2, sort_keys=True)
        print()
    elif isinstance(resp, list):
        # Plane returns comments newest-first; sort ascending by created_at so
        # the human listing reads oldest→newest (the last line is the latest).
        ordered = sorted(resp, key=lambda c: str(c.get("created_at") or ""))
        for c in ordered:
            cid = c.get("id", "")
            created = c.get("created_at", "")
            actor_detail = c.get("actor_detail") or {}
            actor = actor_detail.get("display_name", "") if isinstance(actor_detail, dict) else ""
            print(f"{created}  {cid[:8]}  {actor}")
        print(f"\n{len(ordered)} comment(s) (oldest first; newest is last)")
    else:
        cid = resp.get("id", "") if isinstance(resp, dict) else ""
        print(f"comment {cid}")
    return 0


def _cmd_patch_comment(args: argparse.Namespace, client: PlaneClient) -> int:
    resp = client.patch_comment(args.ref, args.comment_id, _load_body(args.body))
    if args.json:
        json.dump(resp, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"patched comment {resp.get('id', args.comment_id)} on {args.ref}")
    return 0


def _cmd_set_state(args: argparse.Namespace, client: PlaneClient) -> int:
    resp = client.set_state(args.ref, args.state)
    if args.json:
        json.dump(resp, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        print(f"{args.ref} -> {args.state}")
    return 0


def _cmd_create(args: argparse.Namespace, client: PlaneClient) -> int:
    body = _load_body_file(args.body_file) if args.body_file else ""
    resp = client.create(
        title=args.title,
        body_md=body,
        state=args.state,
        labels=args.labels or None,
        assignees=args.assignees or None,
        priority=args.priority,
        parent=args.parent,
    )
    if args.json:
        json.dump(resp, sys.stdout, indent=2, sort_keys=True)
        print()
    else:
        seq = resp.get("sequence_id", "?")
        print(f"created #{seq}: {resp.get('id', '')}")
        url = client.url_for(resp) if resp.get("id") else ""
        if url:
            print(f"  {url}")
    return 0


def _add_json(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")


def _add_timeout(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--timeout",
        type=float,
        default=None,
        metavar="SEC",
        help="fast-fail: cap the per-request timeout and disable retry (max_attempts=1)",
    )


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="plane",
        description="A small CLI for the Plane API (configure via PLANE_* env vars).",
    )
    _add_json(p)
    _add_timeout(p)
    sub = p.add_subparsers(dest="verb", required=True)

    g = sub.add_parser("get", help="fetch a single issue")
    g.add_argument("ref", help="PROJ-N, N, or issue UUID")
    _add_json(g)
    _add_timeout(g)
    g.set_defaults(func=_cmd_get)

    ls = sub.add_parser("list", help="list issues (follows cursor pagination)")
    ls.add_argument("--state", default=None, help="state name or UUID to filter by")
    ls.add_argument("--per-page", type=int, default=100, dest="per_page")
    _add_json(ls)
    _add_timeout(ls)
    ls.set_defaults(func=_cmd_list)

    c = sub.add_parser("comment", help="post a comment")
    c.add_argument("ref", help="PROJ-N, N, or issue UUID")
    c.add_argument("body", help="body text, '-' for stdin, or '@path/to/file'")
    _add_json(c)
    c.set_defaults(func=_cmd_comment)

    cs = sub.add_parser("comments", help="fetch issue comments (list, or single by id)")
    cs.add_argument("ref", help="PROJ-N, N, or issue UUID")
    cs.add_argument("--comment-id", dest="comment_id", default=None,
                    help="fetch a single comment by its UUID (omit to list all)")
    cs.add_argument("--per-page", type=int, default=100, dest="per_page")
    _add_json(cs)
    _add_timeout(cs)
    cs.set_defaults(func=_cmd_comments)

    pc = sub.add_parser("patch-comment", help="update a specific comment in place")
    pc.add_argument("ref", help="PROJ-N, N, or issue UUID that owns the comment")
    pc.add_argument("--comment-id", dest="comment_id", required=True,
                    help="UUID of the comment to overwrite")
    pc.add_argument("body", help="body text, '-' for stdin, or '@path/to/file'")
    _add_json(pc)
    pc.set_defaults(func=_cmd_patch_comment)

    s = sub.add_parser("set-state", help="move an issue to another state")
    s.add_argument("ref", help="PROJ-N, N, or issue UUID")
    s.add_argument("state", help="state name or UUID")
    _add_json(s)
    s.set_defaults(func=_cmd_set_state)

    n = sub.add_parser("create", help="create a new issue")
    n.add_argument("--title", required=True)
    n.add_argument("--body-file", dest="body_file", default=None,
                   help="path to a markdown body file (also accepts '-' for stdin or '@path')")
    n.add_argument("--state", default=None, help="state name or UUID (default: Plane's default)")
    n.add_argument("--labels", nargs="*", default=None, help="label UUIDs")
    n.add_argument("--assignees", nargs="*", default=None, help="assignee (member) UUIDs")
    n.add_argument("--priority", default="none",
                   choices=["low", "medium", "high", "urgent", "none"])
    n.add_argument("--parent", default=None, help="parent PROJ-N, N, or UUID")
    _add_json(n)
    n.set_defaults(func=_cmd_create)

    return p


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    timeout: Optional[float] = getattr(args, "timeout", None)
    kwargs: Dict[str, Any] = {}
    if timeout is not None:
        kwargs["timeout"] = timeout
        kwargs["retry"] = RetryPolicy(max_attempts=1)
    try:
        client = PlaneClient.from_env(**kwargs)
    except RuntimeError as e:
        print(f"plane: {e}", file=sys.stderr)
        return 2
    try:
        return args.func(args, client)
    except PlaneParseError as e:
        # HTTP 2xx with an unparseable body (e.g. an auth-proxy HTML page in
        # front of Plane) exits non-zero instead of looking like "no results".
        print(
            f"plane: unparseable response body (HTTP {e.status}) on {e.url}: {e.body[:400]}",
            file=sys.stderr,
        )
        return 1
    except PlaneAPIError as e:
        print(f"plane: API error {e.status}: {e.body[:400]}", file=sys.stderr)
        return 1
    except ValueError as e:
        print(f"plane: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
