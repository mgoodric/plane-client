"""Open Engine — a reference pattern built on ``plane_client``.

This is an *illustrative* layer, not part of the shipped package. It shows how a
small autonomous "coding loop" can use Plane as its coordination substrate:

- **A state machine of custom Plane states** — issues flow
  ``Agent Todo → Agent Working → (Agent Needs Input | Agent Review) → Agent Done``.
  Create these states in your Plane project; this module resolves their UUIDs by
  name via the API, so nothing here hardcodes them.
- **One label as the poll gate.** A single label (here called
  ``agent-instructions``) marks an issue as "an automated worker may claim this".
  Workers only ever pick up labelled issues in ``Agent Todo``.
- **Receipts as an audit trail.** Each transition posts a comment
  (``AGENT CLAIMED`` / ``AGENT DONE`` / ``AGENT BLOCKED`` …) so a human can read
  the whole lifecycle from the issue thread.

Point it at your project with the standard ``PLANE_*`` env vars (see
``PlaneClient.from_env``) and pass in your own label + member UUIDs.

Run ``python examples/open_engine/oe.py`` for a read-only demo that lists the
claimable queue.
"""

from __future__ import annotations

import os
import sys
from typing import Any, Dict, List, Optional

# When run from the repo root, make the package importable without installing.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from plane_client import PlaneClient  # noqa: E402


# The lifecycle. Names are the contract; UUIDs are per-project and resolved
# dynamically. Adapt to taste.
TODO = "Agent Todo"
WORKING = "Agent Working"
NEEDS_INPUT = "Agent Needs Input"
REVIEW = "Agent Review"
DONE = "Agent Done"


def open_engine_client(**kwargs: Any) -> PlaneClient:
    """A ``PlaneClient`` for an Open-Engine-style project, from ``PLANE_*`` env."""
    return PlaneClient.from_env(**kwargs)


def claimable_queue(client: PlaneClient, *, agent_label: str) -> List[Dict[str, Any]]:
    """Issues a worker may claim: state ``Agent Todo`` AND carrying the poll label."""
    return [
        issue
        for issue in client.list(state=TODO)
        if agent_label in (issue.get("labels") or [])
    ]


def file_task(
    client: PlaneClient,
    *,
    title: str,
    body_md: str,
    agent_label: str,
    assignee: str,
    parent: Optional[str] = None,
) -> Dict[str, Any]:
    """File a new agent task in ``Agent Todo`` with the poll label + an assignee.

    A ``parent`` (issue ref) makes this a dependency-gated child: a worker holds
    the child until the parent reaches ``Agent Done``.
    """
    return client.create(
        title=title,
        body_md=body_md,
        state=TODO,
        labels=[agent_label],
        assignees=[assignee],
        parent=parent,
    )


def claim(client: PlaneClient, ref: str, *, worker: str) -> None:
    """Claim an issue: move it to ``Agent Working`` and post an ``AGENT CLAIMED`` receipt."""
    client.set_state(ref, WORKING)
    client.comment(ref, f"**AGENT CLAIMED** by `{worker}`. Beginning work.")


def complete(client: PlaneClient, ref: str, *, worker: str, summary: str) -> None:
    """Finish an issue: post an ``AGENT DONE`` receipt and move to ``Agent Done``."""
    client.comment(ref, f"**AGENT DONE** by `{worker}`. {summary}")
    client.set_state(ref, DONE)


def block(client: PlaneClient, ref: str, *, worker: str, question: str) -> None:
    """Pause for a human: post ``AGENT BLOCKED`` and move to ``Agent Needs Input``."""
    client.comment(ref, f"**AGENT BLOCKED** by `{worker}`. {question}")
    client.set_state(ref, NEEDS_INPUT)


def _demo() -> int:
    label = os.environ.get("OE_AGENT_LABEL")
    if not label:
        print("set OE_AGENT_LABEL to your poll-gate label UUID for the demo", file=sys.stderr)
        return 2
    client = open_engine_client()
    queue = claimable_queue(client, agent_label=label)
    print(f"{len(queue)} claimable issue(s) in '{TODO}':")
    for issue in queue:
        print(f"  #{issue.get('sequence_id')}  {issue.get('name')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_demo())
