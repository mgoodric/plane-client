# to-engine

> Published alongside the essay [Two Systems for Handing Work to Agents](https://mattgoodrich.com/posts/two-systems-for-handing-work-to-agents/).
>
> **This is a redacted copy.** The working skill hard-codes instance-specific
> identifiers — the Plane host, workspace/project/label/user UUIDs, state UUIDs, the
> API token location, and machine paths. All of those are removed here and shown as
> `<placeholders>`. What remains is the reusable part: the title convention, the
> nine-section body template, and the filing procedure. Transport is the `plane` CLI
> published in this repo (see the top-level `README.md`).

Files an article-aligned task issue into an Open Engine queue on Plane. Encapsulates
the conventions that solidified over the first couple dozen issues: title-bracket
routing, a single `agent-instructions` label, the body-section template, the
parent-child convention, and the two-mode pattern (normal Agent Todo vs pre-staged
Agent Needs Input smoke tests).

## When to use

| User intent | Action |
|---|---|
| "File an OE issue for X" / "Queue this as agent work" | Default: Agent Todo, `matt-claude`, no parent. Compose body from context; ask only about parent. |
| "File a Plane task for matt-codex to..." | Same as default but runtime = `matt-codex`. |
| "File a child of OE-N for..." | Set parent = OE-N (the CLI resolves the sequence id to a UUID). |
| "Pre-stage a smoke test issue..." | Special mode: state = Agent Needs Input, plus pre-posted receipts. |
| "File a follow-up to fix the X gap" | Default mode; reference the originating issue in `## Sources`. |

**Auto-scope:** if the skill is invoked from a `pwd` under your dev root
(`<dev-root>/<repo>/`), a `Scope: <dev-root>/<repo>` line is auto-injected at the top
of the composed body (before `## Requester`). The runner reads that line and narrows
the fire's working directory to the matching repo. Invocations from outside the dev
root inject nothing.

**NOT for:** filing issues in unrelated Plane projects (the runners don't poll them),
filing GitHub issues, or anything outside the engine project.

## Configuration (instance-specific — supply your own)

The working skill keeps a block of literal constants so it never has to look them up
at runtime. Redacted here; provide your own:

```
PLANE_BASE       = https://<your-plane-host>
WORKSPACE_SLUG   = <your-workspace>
ENGINE_PROJECT   = <project-uuid>            # the OPENENGINE project
AGENT_LABEL_ID   = <label-uuid>              # agent-instructions (runner gate)
ASSIGNEE_USER_ID = <user-uuid>               # default assignee
API_TOKEN        = <read from a local secret store, never inlined>
```

State names the runners key on (your tracker's own UUIDs back these):

```
Standing · Agent Todo · Agent Working · Agent Needs Input · Agent Review ·
Agent Done · Cancelled
```

## Title format (REQUIRED — non-negotiable)

```
[agent instructions][matt-<runtime>][<kind>] <outcome>
```

- `<runtime>` ∈ `{matt-claude, matt-codex}`. Default `matt-claude` unless the user
  specifies.
- `<kind>` is almost always `task`.
- `<outcome>` is short (≤80 chars total in title), imperative, specific. Bad: "Stuff
  for the hub." Good: "Architecture v1: incorporate decisions + topic taxonomy proposal."

## Body template (REQUIRED 9 sections, in this order)

Compose markdown with these section headers verbatim. Use `## ` (H2) for each.
Required even if a section is short — if a section is genuinely empty, write "None."
rather than omitting it.

```markdown
## Requester

Who is asking and any high-level framing context.

## Desired outcome

The concrete result wanted. One paragraph; no implementation hand-waving.

## Context

Why this matters; what's true today; prior issues this builds on (cite by OE-N).
Avoid restating the desired outcome here.

## Sources

- Codebase paths (absolute)
- Plane issue references (OE-N)
- External URLs (sparingly — only if load-bearing)

## Do

Numbered steps. Each step is one verifiable action. If a step would take >2 min of
agent time, consider splitting into sub-steps so the verifier can check granularity.
Be explicit about file paths to read AND file paths to write.

## Acceptance criteria

Bulleted, observable success conditions. Each one must be testable by inspecting
files/state after the fire. Avoid criteria like "the design is sound" — rephrase as
"the doc has sections X, Y, Z in this order."

## Output handoff

What artifacts land where: files created/edited, Plane comments posted, state
transitions.

## Boundaries

Explicit do-NOTs, scoped to what's genuinely risky under the autonomy policy
(`AUTONOMY.md` — autonomous by default, escalate only when risky). **Do NOT reflexively
forbid pushing or opening a PR — those are normal autonomous steps now, not
boundaries.** Include only the risky-category standard set that actually applies. Add
issue-specific risky bounds on top.

## If blocked

Anticipate failure modes. For each, state which sentinel to emit (`AGENT_BLOCKED:`
for tracker-answerable, `AGENT_HUMAN_HOLD:` for operator-session-answerable) plus a
one-line question/request.
```

## Procedure

1. **Gather inputs from conversation context:** the intent/outcome, the runtime
   (`matt-claude` unless explicitly `matt-codex`), whether a parent OE is implied
   ("child of OE-N", "follow-up to OE-N"), and whether this is a smoke test (rare;
   the user has to say so explicitly).
2. **Derive the Scope hint from `pwd`.** If the current directory is under your dev
   root, inject a `Scope: <dev-root>/<repo>` line as line 1 of the body (absolute
   path, not `~`, so it survives the runner's pandoc round-trip). Otherwise inject
   nothing.
3. **Compose the body markdown** with all 9 sections. Be tight and specific. If a
   section feels thin, the issue is probably under-scoped — deepen it or ask.
4. **Sanity-check before filing:** title matches the bracket format; all 9 sections
   present; file paths absolute; boundaries risk-scoped (no reflexive "no push"); if
   blocked has at least one sentinel branch; nothing says "TBD".
5. **File to Plane via the `plane` CLI** (published in this repo). It encapsulates
   every gotcha the raw `curl` path re-discovers each time — 429 retry with backoff,
   control-char stripping on responses, apostrophe-safe JSON, Plane's silently-ignored
   server-side filters, and cursor pagination for the `--parent` sequence→UUID lookup.
   Article-aligned defaults apply automatically (label `agent-instructions`, default
   assignee, state Agent Todo, priority medium); override via
   `--state` / `--labels` / `--assignee` / `--priority`.

   ```bash
   plane create \
     --title "[agent instructions][matt-claude][task] <outcome>" \
     --body-file /tmp/oe-body.md \
     --parent OE-M \
     --json > /tmp/oe-resp.json     # omit --parent when there is none

   OE_ID=$(jq -r '.id' /tmp/oe-resp.json)
   OE_SID=$(jq -r '.sequence_id' /tmp/oe-resp.json)
   ```

   For **smoke test** filings, override the state with `--state "Agent Needs Input"`.
6. **Return the result:**

   ```
   ✅ OE-N filed:
     UUID:        <uuid>
     sequence_id: N
     parent:      <OE-M or "(none)">
     state:       Agent Todo   (or Agent Needs Input for smoke tests)
     URL:         https://<your-plane-host>/.../issues/<uuid>
   ```

## Smoke test pre-staging (advanced mode)

For testing the runner's resume-scan code path, an issue is staged in **Agent Needs
Input** with pre-posted receipts. Comments are posted with `plane comment <OE-ref>
<body>`. Two flavors:

- **AGENT BLOCKED smoke test** — post an `AGENT BLOCKED` comment with a specific
  question, then a human prose reply that must NOT start with `AGENT <UPPERCASE>`
  (lead with a name, e.g. `Reply: ...`). The resume-scan detects the answer because
  it leads with prose, not an `AGENT` token.
- **AGENT HUMAN HOLD smoke test** — post `AGENT HUMAN HOLD`, then a reply containing
  the literal string `AGENT HUMAN ANSWERED`. The resume-scan greps for that token in
  comments newer than the HOLD.

## What this skill explicitly does NOT do

- Does NOT file in unrelated Plane projects (only the engine project).
- Does NOT poll, claim, or process the issue afterward — that's the runner's job.
- Does NOT decide the parent automatically; it asks if unclear from context.
- Does NOT widen scope beyond what the user requested — extra "while you're in there"
  steps need their own issue.
- Does NOT auto-fire the runner after filing — the scheduler drives that.
- Does NOT modify existing issues; only creates new ones.

## Rate-limit gotcha

Plane returns HTTP 429 (`RATE_LIMIT_EXCEEDED`) after ~30–40 rapid POSTs to a single
project. When batching multiple creates, sleep ~400ms between calls; a standard 30s
backoff resolves it. (The `plane` CLI already handles the retry.)

## Comment-author identity caveat

A single API token posts as one user, so there is no per-comment authorship
distinction between agent-posted and human-posted comments. The runner's BLOCKED
detection relies entirely on whether the comment body leads with `AGENT <UPPERCASE>`
or with prose. This is a load-bearing convention; do NOT post smoke-test "human"
replies that start with an `AGENT` token.
