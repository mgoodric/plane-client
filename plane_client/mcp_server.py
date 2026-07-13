"""MCP server exposing :mod:`plane_client.core` as typed tools.

A second frontend over :class:`plane_client.core.PlaneClient` (alongside the
``plane`` CLI): the five verbs (get / list / comment / set-state / create) are
surfaced as MCP tools so an MCP-capable client (e.g. Claude Code / Claude
Desktop) can drive Plane through structured tool calls.

Runtime: **stdlib JSON-RPC over stdio** — the protocol is handled by hand rather
than depending on the Python MCP SDK, keeping this module aligned with
``plane_client.core``'s zero-dependency principle.

Registration (Claude Code MCP config, e.g. ``~/.claude.json``):

    "mcpServers": {
      "plane": {
        "type": "stdio",
        "command": "python3",
        "args": ["-m", "plane_client.mcp_server"],
        "env": {
          "PLANE_BASE": "https://plane.example.com",
          "PLANE_WORKSPACE": "your-workspace",
          "PLANE_PROJECT": "<project-uuid>",
          "PLANE_PAT_FILE": "/path/to/token"
        }
      }
    }

The server reads its config + token from the same ``PLANE_*`` env vars as the
CLI (``PlaneClient.from_env``), so no credentials live in the config file if you
point ``PLANE_PAT_FILE`` at a token file.
"""

from __future__ import annotations

import json
import logging
import sys
from typing import Any, Callable, Dict, List, Optional

from .core import PlaneAPIError, PlaneClient


__version__ = "0.1.0"


# Advertised MCP protocol versions, most recent first. Clients negotiate against
# this list; unknown newer clients get the newest we advertise, older clients
# the version they ask for if we speak it.
SUPPORTED_PROTOCOL_VERSIONS = [
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
]


logger = logging.getLogger("plane_client.mcp_server")


# --- Tool definitions -----------------------------------------------------


def _tool_specs() -> Dict[str, Dict[str, Any]]:
    """Return the five tool specs (description + input schema)."""
    ref_desc = "Issue reference: PROJ-N, bare N, or a full issue UUID."
    return {
        "plane_get": {
            "description": (
                "Fetch a single Plane issue by ref. `ref` accepts `PROJ-N`, "
                "bare `N`, or a full issue UUID. Returns the full issue payload."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"ref": {"type": "string", "description": ref_desc}},
                "required": ["ref"],
                "additionalProperties": False,
            },
        },
        "plane_list": {
            "description": (
                "List Plane issues, optionally filtered by state name. Follows "
                "Plane's cursor pagination automatically and re-filters "
                "client-side (Plane's server-side state filter is ignored)."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "state": {
                        "type": "string",
                        "description": (
                            "Optional state name (case-insensitive) or state UUID. "
                            "Omit to list every issue in the project."
                        ),
                    },
                },
                "additionalProperties": False,
            },
        },
        "plane_comment": {
            "description": (
                "Post a comment on a Plane issue. `body` may be markdown "
                "(converted via pandoc when available) or HTML. Apostrophes and "
                "quotes are safe — the client uses `json.dumps` end-to-end."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": {"type": "string", "description": ref_desc},
                    "body": {"type": "string", "description": "Comment body (markdown or HTML)."},
                },
                "required": ["ref", "body"],
                "additionalProperties": False,
            },
        },
        "plane_set_state": {
            "description": (
                "Move a Plane issue to a different state. `state` accepts a "
                "case-insensitive state name (resolved via the project's states) "
                "or a state UUID."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": {"type": "string", "description": ref_desc},
                    "state": {"type": "string", "description": "Target state name or UUID."},
                },
                "required": ["ref", "state"],
                "additionalProperties": False,
            },
        },
        "plane_create": {
            "description": (
                "Create a new Plane issue. Optional `state` (name or UUID), "
                "`labels` and `assignees` (UUID lists), `priority`, and `parent` "
                "(PATCHed after creation, since Plane's create endpoint does not "
                "accept `parent` reliably)."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": {"type": "string", "description": "Issue title."},
                    "body": {"type": "string", "description": "Issue body in markdown."},
                    "state": {"type": "string", "description": "State name or UUID."},
                    "labels": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional list of label UUIDs.",
                    },
                    "assignees": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Optional list of assignee (member) UUIDs.",
                    },
                    "parent": {
                        "type": "string",
                        "description": "Optional parent issue ref (PROJ-N, N, or UUID).",
                    },
                    "priority": {
                        "type": "string",
                        "enum": ["low", "medium", "high", "urgent", "none"],
                        "description": "Priority (default: none).",
                    },
                },
                "required": ["title"],
                "additionalProperties": False,
            },
        },
    }


TOOL_ORDER = (
    "plane_get",
    "plane_list",
    "plane_comment",
    "plane_set_state",
    "plane_create",
)


# --- Server ---------------------------------------------------------------


class PlaneMCPServer:
    """Stdio JSON-RPC MCP server bound to a single ``PlaneClient`` instance.

    Testable in isolation: construct with a mock client and drive it by feeding
    JSON-RPC requests through ``handle_request``. ``run`` is the stdio loop.
    """

    def __init__(self, client: PlaneClient):
        self.client = client
        self.tool_specs = _tool_specs()
        self._handlers: Dict[str, Callable[[Dict[str, Any]], Any]] = {
            "plane_get": self._plane_get,
            "plane_list": self._plane_list,
            "plane_comment": self._plane_comment,
            "plane_set_state": self._plane_set_state,
            "plane_create": self._plane_create,
        }
        # Guard against a tool spec drifting from the handler map.
        assert set(self.tool_specs) == set(self._handlers) == set(TOOL_ORDER), (
            "tool spec/handler drift: "
            f"specs={sorted(self.tool_specs)}, handlers={sorted(self._handlers)}"
        )

    # ---- typed handlers (thin wrappers over core) --------------------

    def _plane_get(self, args: Dict[str, Any]) -> Any:
        return self.client.get(args["ref"])

    def _plane_list(self, args: Dict[str, Any]) -> Any:
        # Absent or empty `state` both mean "no filter".
        return self.client.list(state=args.get("state") or None)

    def _plane_comment(self, args: Dict[str, Any]) -> Any:
        return self.client.comment(args["ref"], args["body"])

    def _plane_set_state(self, args: Dict[str, Any]) -> Any:
        return self.client.set_state(args["ref"], args["state"])

    def _plane_create(self, args: Dict[str, Any]) -> Any:
        kwargs: Dict[str, Any] = {"title": args["title"], "body_md": args.get("body", "")}
        if args.get("state"):
            kwargs["state"] = args["state"]
        if args.get("labels") is not None:
            kwargs["labels"] = args["labels"]
        if args.get("assignees") is not None:
            kwargs["assignees"] = args["assignees"]
        if args.get("parent"):
            kwargs["parent"] = args["parent"]
        if args.get("priority"):
            kwargs["priority"] = args["priority"]
        return self.client.create(**kwargs)

    # ---- JSON-RPC layer ----------------------------------------------

    def list_tools(self) -> List[Dict[str, Any]]:
        return [
            {
                "name": name,
                "description": self.tool_specs[name]["description"],
                "inputSchema": self.tool_specs[name]["inputSchema"],
            }
            for name in TOOL_ORDER
        ]

    def call_tool(self, name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Invoke a tool and wrap the result in the MCP content shape.

        Plane-level failures (``PlaneAPIError``, ``ValueError`` from ref / state
        resolution) surface as ``isError: true`` results with a clean message —
        never a raw traceback.
        """
        if name not in self._handlers:
            return _error_result(f"unknown tool: {name}")
        try:
            result = self._handlers[name](arguments or {})
        except PlaneAPIError as e:
            return _error_result(f"Plane API {e.status}: {(e.body or '')[:400]}")
        except (KeyError, ValueError) as e:
            return _error_result(str(e))
        return {
            "content": [
                {"type": "text", "text": json.dumps(result, indent=2, sort_keys=True, default=str)}
            ],
            "isError": False,
        }

    def handle_request(self, request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Dispatch one JSON-RPC request. Returns None for notifications."""
        method = request.get("method") or ""
        params = request.get("params") or {}
        req_id = request.get("id")

        if method == "initialize":
            client_version = params.get("protocolVersion", SUPPORTED_PROTOCOL_VERSIONS[-1])
            negotiated = (
                client_version
                if client_version in SUPPORTED_PROTOCOL_VERSIONS
                else SUPPORTED_PROTOCOL_VERSIONS[0]
            )
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": negotiated,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "plane_client", "version": __version__},
                },
            }
        if method == "ping":
            return {"jsonrpc": "2.0", "id": req_id, "result": {}}
        if method.startswith("notifications/"):
            return None
        if method == "tools/list":
            return {"jsonrpc": "2.0", "id": req_id, "result": {"tools": self.list_tools()}}
        if method == "tools/call":
            result = self.call_tool(params.get("name") or "", params.get("arguments") or {})
            return {"jsonrpc": "2.0", "id": req_id, "result": result}

        if req_id is None:
            return None
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Unknown method: {method}"},
        }

    # ---- stdio loop --------------------------------------------------

    def run(self, *, stdin=None, stdout=None) -> None:
        """Read JSON-RPC requests line-by-line, write responses to stdout."""
        stdin = stdin or sys.stdin
        stdout = stdout or sys.stdout
        while True:
            try:
                line = stdin.readline()
            except KeyboardInterrupt:
                return
            if not line:
                return
            line = line.strip()
            if not line:
                continue
            try:
                request = json.loads(line)
            except json.JSONDecodeError as e:
                stdout.write(
                    json.dumps(
                        {"jsonrpc": "2.0", "id": None,
                         "error": {"code": -32700, "message": f"parse error: {e}"}}
                    )
                    + "\n"
                )
                stdout.flush()
                continue
            try:
                response = self.handle_request(request)
            except Exception:  # pragma: no cover - defensive
                logger.exception("unexpected error handling request")
                response = {
                    "jsonrpc": "2.0",
                    "id": request.get("id"),
                    "error": {"code": -32603, "message": "internal error"},
                }
            if response is not None:
                stdout.write(json.dumps(response) + "\n")
                stdout.flush()


def _error_result(message: str) -> Dict[str, Any]:
    """MCP tool-result shape for a clean, non-traceback error."""
    return {"content": [{"type": "text", "text": message}], "isError": True}


# --- Entry point ----------------------------------------------------------


def main(argv: Optional[List[str]] = None) -> int:
    # Logs go to stderr so stdout stays JSON-RPC-only (any stray stdout write
    # breaks the protocol stream).
    logging.basicConfig(
        level=logging.INFO,
        stream=sys.stderr,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    try:
        client = PlaneClient.from_env()
    except RuntimeError as e:
        print(f"plane_client.mcp_server: {e}", file=sys.stderr)
        return 2
    PlaneMCPServer(client).run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
