# Open Engine janitors

> Published alongside the essay [Letting the Loop Merge](https://mattgoodrich.com/posts/letting-the-loop-merge/).
>
> These are the small reconcilers that keep an autonomous agent queue from rotting
> quietly once the loop is allowed to merge on its own. Each one runs on a timer
> (cron / launchd) and exists because one specific thing rotted once.
>
> **Reference copies from the private engine repo.** Instance-specific identifiers
> (the Plane host, project/label/state/issue UUIDs, the default assignee) are
> removed and shown as `<placeholders>`. They live in a gitignored `constants.sh`
> that each script `source`s — copy `constants.example.sh` to `constants.sh` and
> fill in your own. The Plane API token is read from a file on disk
> (`PAT_FILE`), never inlined.

## The set

| Script | What it does |
|---|---|
| `pr-base-drift-reconciler.sh` | Merges `main` forward into open PR heads that GitHub reports as drifted, so a PR does not go un-mergeable while it waits for review. Pushes without `--force`; a real conflict is logged and left for a human. |
| `orphan-pr-review-reconciler.sh` | Finds mergeable PRs whose review task was never filed (the issue closed through a path that skipped it) and files the missing review. |
| `pr-age-escalator.sh` | Posts one follow-up note on a review issue after a PR has been open too long, so age becomes visible instead of silent. |
| `false-done-backstop-reconciler.sh` | Reopens any issue marked Done whose PR did not actually merge (a runner returned success on exit 0 without the work landing). |
| `superseded-oe-surfacer.sh` | Flags issues that look like they need a decision but whose work already shipped through a sibling PR, as candidates to cancel. |
| `pr-merge-reconciler.sh` | Advances an issue to Done when its PR merged outside the loop; flags closed-unmerged PRs. |
| `human-queue-digest.sh` | Posts everything that actually needs a person to a chat channel, so a human follow-up cannot get lost. |
| `lifecycle-notifier.sh` | Emits created / done / cancelled / moved lifecycle events for visibility. |
| `heartbeat-watchdog.sh` | Local alert when a runner's heartbeat goes stale past a threshold. Read-only against Plane; notifies via the OS. |
| `lib/reconcile.sh` | Shared helper: merge a base branch forward into a PR head in an isolated worktree. |

## The bias

Every janitor that can act destructively is written to **surface, not fix**: the
superseded-issue one flags rather than cancels, the false-Done one reopens rather
than redoes, the base-drift one merges forward but never force-pushes. A wrong
cancel loses work; a wrong surface costs a glance.

## Not a turnkey install

These are reference copies, not a packaged product. They assume a Plane project
running the Open Engine seven-state machine, `gh` and `jq` on PATH, and the
constants above. Read them as worked examples of the pattern, adapt to your own
tracker and hosts.
