# plane-client

A small, zero-dependency Python client, CLI, and MCP server for the [Plane](https://plane.so) project-management API.

Plane is a great issue tracker, and it's self-hostable — but its REST API has a handful of sharp edges that bite anyone talking to it with ad-hoc `curl` or `requests` code: control characters in JSON responses, a per-token rate limit, 400s from apostrophes, a pagination field that lies about whether there's a next page, and server-side filters that are silently ignored. `plane-client` encodes those workarounds once so you don't have to rediscover them.

Everything here is standard library only — no `requests`, no third-party HTTP stack, nothing to audit but the code in this repo. Python 3.9+.

## Install

From source:

```bash
git clone <this-repo>
cd plane-client
pip install .
```

Or, for a checkout you plan to edit:

```bash
pip install -e .
```

There are no runtime dependencies. (`pandoc` is used *if present* for faithful Markdown→HTML conversion of issue/comment bodies, and a minimal built-in converter is used otherwise — but it is never required.)

## Configuration

The client is bound to a single Plane project and reads its configuration from the environment:

| Variable | Required | Meaning |
| --- | --- | --- |
| `PLANE_BASE` | yes | Plane instance URL, e.g. `https://plane.example.com` |
| `PLANE_WORKSPACE` | yes | Workspace slug |
| `PLANE_PROJECT` | yes | Project UUID |
| `PLANE_PAT` | one of these two | Personal access token (value) |
| `PLANE_PAT_FILE` | one of these two | Path to a file containing the token |

`PLANE_PAT` wins if both are set. `PLANE_PAT_FILE` is the friendlier option for keeping the secret out of your shell history and process environment — point it at a `600`-mode file and you're done.

```bash
export PLANE_BASE="https://plane.example.com"
export PLANE_WORKSPACE="your-workspace"
export PLANE_PROJECT="00000000-0000-0000-0000-000000000000"
export PLANE_PAT_FILE="$HOME/.config/plane/token"
```

## Quickstart

### Python

```python
from plane_client.core import PlaneClient

plane = PlaneClient.from_env()

issue = plane.get("PROJ-42")                 # by identifier, bare number, or UUID
print(issue["name"], "->", plane.url_for(issue))

plane.comment("PROJ-42", "Looks good — shipping it. Don't @ me.")
plane.set_state("PROJ-42", "In Progress")    # state resolved by name, no UUIDs

for i in plane.list(state="Todo"):           # client-side filtered, fully paginated
    print(i["sequence_id"], i["name"])
```

Every issue reference — `get`, `comment`, `set_state`, and friends — accepts any of the three flavours below, so you can pass whatever you have on hand.

### CLI

The package installs a `plane` console command. Each verb maps to a client method, and each supports `--json` for machine-readable output.

```bash
plane get PROJ-42 --json
plane list --state "In Progress" --json

# Comment body is a positional argument; use "-" to read from stdin,
# or "@path" to read from a file.
plane comment PROJ-42 "Nice work"
plane comment PROJ-42 - < notes.md
plane comment PROJ-42 @release-notes.md

plane comments PROJ-42 --json
plane set-state PROJ-42 "Done"

plane create --title "Investigate flaky test" --body-file ./body.md
plane patch-comment PROJ-42 <comment-uuid> "edited in place"
```

## MCP server

The package ships an [MCP](https://modelcontextprotocol.io) server (stdlib JSON-RPC over stdio) exposing five typed tools to MCP-capable AI clients such as Claude Code and Claude Desktop:

| Tool | Does |
| --- | --- |
| `plane_get` | Fetch a single issue by ref |
| `plane_list` | List issues, optionally filtered by state name |
| `plane_comment` | Post a comment |
| `plane_set_state` | Move an issue to a named state |
| `plane_create` | Create an issue |

Run it directly with:

```bash
python -m plane_client.mcp_server
```

### Registering with Claude Code

Add an entry to the `mcpServers` block of your `~/.claude.json`. The server reads the same environment variables as the client, passed through `env` — so no secret ever lives in the repo:

```json
{
  "mcpServers": {
    "plane": {
      "type": "stdio",
      "command": "python3",
      "args": ["-m", "plane_client.mcp_server"],
      "env": {
        "PLANE_BASE": "https://plane.example.com",
        "PLANE_WORKSPACE": "your-workspace",
        "PLANE_PROJECT": "00000000-0000-0000-0000-000000000000",
        "PLANE_PAT_FILE": "/home/you/.config/plane/token"
      }
    }
  }
}
```

## Plane API gotchas this handles

This is the part worth reading. Each of these is a real behaviour of Plane's API that the client absorbs so your code doesn't have to.

- **Control characters in JSON responses.** Plane echoes raw control characters back inside `description_html` / `comment_html` fields. `json.loads` rejects the response even though the write itself succeeded. The client strips the offending control characters before parsing — and critically, does *not* retry a failed parse, because the write already happened and retrying would double-apply it.

- **Rate limiting (429), with a retry/don't-retry distinction.** Plane enforces a per-token, per-minute budget and returns `429` when you exceed it. Unlike the control-char case, a `429` means the request did *not* land, so the client backs off and retries it. The two failure modes look superficially similar but demand opposite handling; the client gets both right.

- **Apostrophe / quote 400s.** Request bodies assembled by string interpolation return `400` whenever the text contains an apostrophe or a quote. The client builds every payload with `json.dumps` end to end, so arbitrary text — contractions, quoted strings, code snippets — goes over the wire safely.

- **Cursor pagination that lies about the last page.** List endpoints paginate via a cursor, and the `next_cursor` field is present *even on the final page*. Trusting `next_cursor` alone is an infinite loop. The real "is there more?" signal is the `next_page_results` boolean, which the client keys on (falling back to a bare `next` URL for endpoints that don't send it).

- **Server-side filters that are silently ignored.** Some list filters — notably filtering the issues list by `state` — are accepted by the server and then ignored, returning the entire project instead of the subset you asked for. Rather than trust the server, the client passes the filter (in case Plane ever wires it up) *and* post-filters the results client-side, so `list(state="Todo")` returns exactly the issues in that state.

- **Three reference flavours.** An issue can be addressed by its UUID, by its bare sequence number (`42`), or by the project identifier form (`PROJ-42`). All three resolve transparently. Because Plane also ignores a server-side `sequence_id` filter, resolving a bare number or `PROJ-N` ref means paginating the issue list and matching client-side; the client caches the resolution so you only pay for it once.

## Example: a coordination loop on Plane

[`examples/open_engine/`](examples/open_engine/) is a worked reference showing
how to use this client to run a small autonomous multi-agent "coding loop" with
**Plane as the coordination substrate** — a state machine of custom states, a
single label as the poll gate for automated workers, comment receipts as an
audit trail, and the parent field for dependency-gated work. It is illustrative;
adapt the states and IDs to your own project.

## Not affiliated with Plane

This is an independent, community-built client. It is not produced, endorsed, or supported by Plane (makeplane / plane.so). "Plane" is the trademark of its respective owner.

## License

MIT.
