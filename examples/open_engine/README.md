# Open Engine — a coordination-loop pattern on Plane

A worked example of using [`plane_client`](../../README.md) to run a small
autonomous multi-agent "coding loop" with **Plane as the coordination
substrate**. It is illustrative — adapt the states, label, and IDs to your own
project. `oe.py` is the runnable reference; this file explains the pattern.

## The idea

Instead of a bespoke queue, the work lives in Plane as ordinary issues. Custom
**states** form a lifecycle, a single **label** gates what an automated worker
may touch, and every transition leaves a **comment receipt** so a human can read
the whole story from the issue thread.

```
                 file_task()                 claim()               complete()
   (human/agent) ──────────▶  Agent Todo  ──────────▶ Agent Working ──────────▶ Agent Done
                                  ▲                        │
                                  │                        │ block()
                                  └────────────────────────▶ Agent Needs Input ──▶ (human replies)
```

## The three conventions

1. **A state machine of custom Plane states.**
   `Agent Todo → Agent Working → (Agent Needs Input | Agent Review) → Agent Done`
   (plus `Standing` for parked work and `Cancelled`). Create these in your Plane
   project; `oe.py` resolves their UUIDs by name via the API, so nothing is
   hardcoded.

2. **One label as the poll gate.** A single label (here `agent-instructions`)
   marks an issue as claimable by an automated worker. Workers only ever pick up
   labelled issues in `Agent Todo` — so a human can file an issue *without* the
   label to keep it out of the automation, or add it to hand work over.

3. **Receipts as an audit trail.** Each transition posts a comment —
   `AGENT CLAIMED`, `AGENT DONE`, `AGENT BLOCKED` — so the issue thread *is* the
   log. Because comments go through `plane_client` they are safe to fill with
   arbitrary prose (apostrophes, code, quotes) without tripping Plane's JSON
   quirks.

## Dependency gating

`file_task(..., parent=<ref>)` links a task to a parent. A worker holds the
child until the parent reaches `Agent Done` — so an ordered chain of work
(`A → B → C`) is expressed structurally in Plane's parent field, not narrated in
prose. This is how you decompose a feature into slices the loop ships in order.

## Try it (read-only)

```bash
export PLANE_BASE=https://plane.example.com
export PLANE_WORKSPACE=your-workspace
export PLANE_PROJECT=<project-uuid>
export PLANE_PAT_FILE=/path/to/token
export OE_AGENT_LABEL=<your-poll-label-uuid>

python examples/open_engine/oe.py     # lists the claimable Agent Todo queue
```

## Using the helpers

```python
from examples.open_engine.oe import open_engine_client, file_task, claim, complete

client = open_engine_client()

issue = file_task(
    client,
    title="[worker-a] Add a healthcheck endpoint",
    body_md="## Goal\nReturn 200 from /health.\n",
    agent_label="<label-uuid>",
    assignee="<member-uuid>",
)

# ... a worker picks it up:
claim(client, f"{issue['sequence_id']}", worker="worker-a")
complete(client, f"{issue['sequence_id']}", worker="worker-a", summary="Shipped in PR #123.")
```

That is the whole coordination primitive: **file → claim → work → receipt →
done**, with Plane holding the state and the humans reading along.
