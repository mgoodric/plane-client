# Open Engine — Autonomy Policy

> Published alongside the essay [Two Systems for Handing Work to Agents](https://mattgoodrich.com/posts/two-systems-for-handing-work-to-agents/).
> This is the canonical autonomy policy the Open Engine runners key on — the risk
> tiers referenced from issue bodies and the `break-to-engine` skill. Reproduced
> from the private engine repo; infrastructure-specific identifiers are not part of
> the policy itself.

**Canonical source of truth for how far agents act on their own.** Every runner
prompt, the `to-engine` skill, and the core-context standing issue reference this
file instead of restating the rules — so the policy lives in ONE place and cannot
drift. If you change the policy, change it here.

## Principle

**Autonomous by default. Escalate only when risky.**

The operator's time is the scarce resource. The engine should carry work all the way
to done without a human, and interrupt *only* for decisions that are genuinely risky
— irreversible, outward-facing, security-sensitive, or ambiguous. Everything else
the loop handles end to end. "I wasn't sure" is not a reason to escalate; "this
could do real, hard-to-undo harm and I can't verify it's safe" is.

## The autonomous loop (no human review)

For a task that is **not** classified risky below, the agent runs the full loop
and closes the issue itself:

```
implement → run tests → self-review (content + mechanical) → commit →
push branch → open PR → merge to main → AGENT DONE
```

Also autonomous, always: creating branches, worktree lifecycle, filing follow-up
issues, updating tracker state, posting receipts and notifications, reversible
refactors, scaffolds, docs, formatting, dependency bumps that pass tests.

The gate for auto-merge is **passing verification + unambiguous spec + reversible**:
- Tests pass (or the change has no runtime surface), AND
- content-review verdict is `APPROVED` (not `REQUEST_CHANGES` / `BLOCKED`), AND
- the diff is within the safe auto-review size, AND
- the issue spec is clear and self-consistent.

If any of those fail → escalate (below). Do not guess past a failed gate.

## Escalate to human-in-the-loop (→ Agent Needs Input)

Stop and hand back to the operator via `AGENT HUMAN HOLD` (spec/decision unclear) or
`AGENT BLOCKED` (can't safely proceed), which routes the issue to **Agent Needs
Input** and fires a notification. Escalate when the change is **risky**:

1. **Production / outward-facing effects** — deploying to production, restarting or
   replacing prod containers, DNS / network / ACL / firewall changes affecting live
   services, sending email/chat/messages to third parties, publishing anything
   publicly, changing credentials, secrets, or billing.
2. **Destructive / irreversible** — bulk deletes, `git push --force`, history
   rewrites, dropping databases or data, deleting tracker issues or shared branches,
   `rm -rf` on real trees.
3. **Security-sensitive surface** — auth/authz, secret handling, cryptography,
   permission/ACL code.
4. **Engine self-modification** — changes to the runner scripts, scheduled jobs,
   the filing skill, this policy, or any part of the engine's own guardrails. The
   fleet must not rewrite its own guardrails without a human. (Meta-risk.)
5. **Schema / data migrations** that are not trivially reversible.
6. **Ambiguous or self-contradictory spec** — the issue body is unclear,
   underspecified, or conflicts with itself on consequential work.
7. **Verification gap** — tests fail or can't be run, coverage is too thin to trust
   the change, content-review returned `REQUEST_CHANGES` / `BLOCKED`, or the diff
   exceeds the safe auto-review size. **A failure that is pre-existing on `main` and
   untouched by your diff is NOT a verification gap** — see below.
8. **Explicit flag** — the issue carries a `human-action` or `pair-session`
   label, or the body asks for human review.
9. **Cross-repo / broad blast radius** — changes reaching beyond the scoped repo.
10. **Cost** — external spend above the configured threshold.

When in doubt about whether something is risky, escalate. When it's clearly
routine, do not.

## Merge vs deploy (important distinction)

**Merging to main is autonomous.** **Deployment is not the engine's concern.**

The engine's job ends at merge-on-green: push → PR → gates → merge → AGENT DONE,
regardless of what a repo's deploy config says. Whether a merge then reaches
production is owned by external automation — a per-container label opt-in is the
operator's deploy toggle, flipped outside the engine. Runners log the repo's deploy
mode for the record but never hold a merge for it, and never perform deployments
themselves.

Rationale: an earlier gate parked every completed product issue at HUMAN HOLD,
turning "Agent Needs Input" into a merge queue. Deploy risk is real but belongs to
the deployment layer, not the work loop.

## What is NOT a boundary anymore

Pushing to a git remote and opening a PR are **normal autonomous steps**, not
prohibited actions. The old blanket "no push to remote" boundary is retired in
favor of the risk tiers above. Do not inject "no push / no PR" into issue bodies as
a reflexive default; add boundaries only for the genuinely risky categories, or
issue-specific bounds.

### Pre-existing red tests are not a blocker

**A test that is already failing on `main`, and that your diff does not touch, is not
a reason to park an issue.** Proceed with the work.

The escalation in risk tier 7 is about *your change* not being verifiable. It was
never meant to make the fleet hostage to unrelated rot that predates the fire.
Applied literally, one stale red test parks every issue that runs the same suite.

What to do instead:

1. Establish the baseline. Run the suite on `main` *before* applying your change, or
   otherwise confirm the failure predates you (`git log` on the failing file).
2. If the failure is pre-existing and your diff does not touch it — **proceed**.
3. Verify the narrower thing that actually matters: your change introduces no *new*
   failures. Pass-count parity with the baseline is the bar, not a green suite.
4. Name the pre-existing failure in your receipt, so it is on the record rather than
   silently tolerated.
5. If nothing else has, file an issue to repair the failing test. Do not fix it
   inside an unrelated issue — that widens the diff and couples two changes.

Still escalate when the failure is **yours**: if your diff touches the failing test,
or your change plausibly caused the regression, that is a real verification gap under
tier 7 and belongs in Agent Needs Input.

## Escalation protocol

- `AGENT HUMAN HOLD — <reason>` → Agent Needs Input, alert notification. Use when a
  decision or clarification is needed.
- `AGENT BLOCKED — <reason>` → Agent Needs Input, alert notification. Use when a
  gate failed and proceeding is unsafe.
- Resume happens when the operator answers (`AGENT HUMAN ANSWERED`) or the block clears.
