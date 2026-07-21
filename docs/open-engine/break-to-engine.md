# break-to-engine

> Published alongside the essay [Two Systems for Handing Work to Agents](https://mattgoodrich.com/posts/two-systems-for-handing-work-to-agents/).
> This is the decomposition skill that turns a feature into a set of Open Engine
> issues the autonomous loop can actually ship. It is the "Five Rules" from the
> essay, in the form the agent actually reads.

Turns a feature / plan / spec / PRD into a **set of Open Engine issues (OEs) that the
autonomous loop can actually ship** — then files each one via the `to-engine` skill.
This sits one level above `to-engine` (which files a single OE) and is the
Open-Engine-specific sibling of a generic tracer-bullet vertical-slice skill,
hardened with the guardrails below.

## Why this skill exists (read this — it is the whole point)

A set of features (Meross energy monitoring, a notification-hub web front end, Plaid
onboarding, voice fan-out) were once broken into **sub-file micro-OEs** — e.g. Meross
became six issues: migration, config, collector, schedule, health, dashboard. Every
slice individually "passed" and reported *implementation complete*. But they did not
cohere:

- The **migration OE and the collector OE diverged on column names**, so the feature
  was non-functional at the first DB write — a bug no per-slice test could catch
  because the contract was split across two issues.
- Slices piled up as **dependency-blocked holds** ("requeue after OE-X") because the
  ordering lived only in prose, not structure.
- Partial epics left **un-shippable fragments** (a 47-commit runaway branch, a
  missing foundation slice).
- Blanket "no push" boilerplate boundaries **stranded 17 finished items** in
  Needs-Input.

The loop *executed* fine. The **breakdown** was the failure. This skill fixes the
breakdown.

## The five rules (each prevents a specific failure above)

1. **Vertical slices, not horizontal steps.** A slice is one *independently
   shippable, end-to-end-verifiable* change — not "one OE per file/layer." If a slice
   can't merge and be verified on its own, it's not a slice; fold it into the one it
   completes.
2. **Keep a contract inside one slice.** A schema and the code that reads/writes it,
   an API and its first caller, a config field and the code that consumes it —
   **never split across OEs.** This is the load-bearing rule; it's what the Meross
   schema break violated.
3. **Right-size for a single fire (~20 min walltime).** Too big → the fire times out
   and fail-loops. Too small → floods Needs-Input and multiplies integration seams.
   Aim for one coherent change a competent engineer ships in well under 20 minutes.
4. **Structure the dependencies, don't narrate them.** If slice B needs slice A
   merged first, set B's `parent` to A (via to-engine). The runner's
   dependency-gating only holds a child while its parent isn't Agent Done — but only
   if the link is in the `parent` field, not the body prose.
5. **Risk-scoped boundaries + integration-test acceptance.** Boundaries come from the
   autonomy policy's risk tiers (never the retired blanket "no push"). Acceptance
   MUST include end-to-end verification against the real interface — the mocked-DB
   unit tests are exactly what let the schema break through.

## Procedure

1. **Restate the deliverable** in one sentence and name its end-to-end success (what
   a human would check to say "this works").
2. **Find the seams.** List the interfaces the feature crosses: DB schema, HTTP
   endpoints, config, external APIs, UI. **A contract must not straddle two slices**
   (rule 2) — if a schema and its writer would land in different slices, merge those
   slices.
3. **Cut vertical slices** (rule 1). Each slice = a thin, shippable path through the
   seams it must touch, with its own verification. Prefer the *tracer bullet* first
   slice (the thinnest thing that proves the whole path), then widen.
4. **Size-check each slice** (rule 3). If a slice is more than a competent engineer
   ships in ~15 min, split it *along a shippable boundary* (not along files). If two
   "slices" can't be verified independently, merge them.
5. **Order the DAG** (rule 4). Draw dependencies; the first slice depends on nothing.
   Record which slice is each later slice's `parent`.
6. **Write each OE** with `to-engine`'s 9-section body. In `## Acceptance criteria`,
   require **integration/end-to-end verification** of the seam (rule 5), not just
   unit tests. In `## Boundaries`, use the autonomy-policy risk tiers; add a real
   boundary only for genuinely risky categories.
7. **File in dependency order** by invoking the `to-engine` skill once per slice,
   setting `parent` to the depended-on OE's UUID (to-engine returns each
   `sequence_id` + UUID; feed the parent's UUID to the next).
8. **Report the slice map** — the ordered OE list with the dependency edges, so the
   operator sees the shape and the loop can pull them in order.

## Sizing heuristics

- One migration + the code that writes/reads it + its test = **one slice** (never split).
- A new endpoint + its handler + auth + a test = one slice.
- "Add feature X across the stack" is usually **2–4 vertical slices** (tracer bullet →
  data → surface → polish), not 6–12 sub-file steps.
- A pure-doc, pure-config, or single-file change is one slice.
- If you're writing more than ~6 OEs for one feature, you're almost certainly slicing
  horizontally — stop and re-cut vertically.

## Anti-patterns (do NOT do these — each burned us)

- ❌ One OE per file or per layer (migration OE, model OE, view OE…). → integration
  seams the loop can't test.
- ❌ Splitting a schema from its writer, or an API from its caller, across OEs. → the
  Meross non-functional write.
- ❌ Dependencies expressed only in the body ("requeue after OE-X"). → stalled
  Needs-Input pile.
- ❌ Reflexive "Do NOT push / open a PR" boundaries. → 17 finished items stranded.
- ❌ Acceptance that only asserts unit tests pass. → mocked-away integration bugs ship.

## Worked example — Meross energy (wrong vs right)

**What we did (wrong):** 6 OEs — `050_meross.sql` · `config.py` · `collector.py` ·
schedule · health · dashboard. Result: schema↔collector column divergence,
non-functional, 6 held issues.

**What break-to-engine produces (right):** 2 slices.

- **Slice 1 — "Meross collector, end to end":** the migration, the collector, its
  config fields, the schedule + health wiring, **in one OE**, because the table schema
  and the collector's INSERT are a single contract. Acceptance: *a real insert against
  the migrated table succeeds* (integration test, not a DB mock). No parent.
- **Slice 2 — "Meross Grafana dashboard":** panels querying `meross_readings`.
  `parent` = Slice 1 (needs the table + real column names). Acceptance: dashboard JSON
  validates and its queries reference only columns that exist in Slice 1's migration.

Two coherent, independently-shippable slices, ordered — instead of six fragments that
don't add up.

## Output

Return: the ordered list of filed OEs (`sequence_id`, title, one-line scope), the
dependency edges (`OE-B parent=OE-A`), and a one-line note on where the tracer-bullet
slice is. Do not re-file OEs that already exist for this work; reconcile against the
queue first.

## References

- `to-engine` skill — files each individual OE (title bracket, labels, 9-section
  body, parent). See `to-engine.md` in this directory.
- The autonomy policy — risk tiers for the `## Boundaries` section. See `AUTONOMY.md`.
