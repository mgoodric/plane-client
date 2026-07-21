#!/usr/bin/env bash
# Shared git reconciliation helpers for Open Engine runners and cron drainers.
# Source this file; it intentionally performs no work at load time.

# repo_root_is_isolated: 0 (true) when $1's resolved git toplevel lives under
# $HOME/Development/.engine-worktrees/. Any git mutation (add/commit/merge/
# push) outside that area risks sweeping stray untracked files from a shared
# checkout into an OE branch (the PRs #16-#21 incident - OE-230).
repo_root_is_isolated() {
  local root
  root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)
  case "$root" in
    "$HOME/Development/.engine-worktrees/"*) return 0 ;;
    *) return 1 ;;
  esac
}

# reconcile_pr_from_base: one-shot merge-from-base reconciliation for a review
# PR whose mergeStateStatus is DIRTY/CONFLICTING because the base branch has
# advanced with non-overlapping edits ("base drift"). Runs entirely inside an
# isolated worktree; never touches the shared main tree; never rebases; never
# force-pushes. The final squash-merge on GitHub collapses the extra merge
# commit anyway, so this is additive-only.
#
# Contract:
#   $1 = worktree path (MUST exist and MUST already be under
#        ~/Development/.engine-worktrees/ - caller enforces OE-230 guard)
#   $2 = base branch name (e.g. "main")
#   $3 = head branch name (the PR's source branch on origin)
# Echoes to stdout exactly one line, one of:
#   "CLEAN <sha>"              - merge succeeded; HEAD is at <sha> (detached)
#   "CONFLICT <files...>"      - overlapping conflicts; merge --aborted;
#                                <files...> is the space-separated
#                                `git diff --name-only --diff-filter=U` list
#   "FATAL <detail>"           - fetch/checkout failed before merge could run
# Return codes: 0 = CLEAN, 1 = CONFLICT, 2 = FATAL.
#
# The caller pushes on CLEAN (this helper never pushes).
#
# The detached checkout of origin/<head> avoids "branch already checked out"
# collisions when the head branch is still live in a separate task-fire
# worktree (the one that originally produced the PR).
reconcile_pr_from_base() {
  local wt="$1" base="$2" head="$3"
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'FATAL worktree %s missing' "$wt"
    return 2
  fi
  if ! git -C "$wt" fetch origin "$base" "$head" --quiet >/dev/null 2>&1; then
    printf 'FATAL fetch origin %s %s failed' "$base" "$head"
    return 2
  fi
  if ! git -C "$wt" checkout --detach "origin/$head" --quiet >/dev/null 2>&1; then
    printf 'FATAL checkout --detach origin/%s failed' "$head"
    return 2
  fi
  # Additive merge. --no-edit + --no-ff keeps the merge commit deterministic.
  # The author identity is scoped to this single invocation so we do not
  # depend on the launchd runner user's global git config. Both stdout and
  # stderr are redirected: on conflict, git writes "Auto-merging ..." +
  # "CONFLICT ..." to STDOUT (not stderr), which would otherwise leak into the
  # caller's command-substitution capture.
  if git -C "$wt" \
        -c user.email=matt-claude@openengine.local \
        -c user.name="matt-claude runner (OE-253)" \
        merge "origin/$base" --no-edit --no-ff --quiet >/dev/null 2>&1; then
    local sha
    sha=$(git -C "$wt" rev-parse HEAD)
    printf 'CLEAN %s' "$sha"
    return 0
  fi
  local conflict_files
  conflict_files=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null \
                     | tr '\n' ' ' | sed -E 's/[[:space:]]+$//')
  git -C "$wt" merge --abort >/dev/null 2>&1 || true
  printf 'CONFLICT %s' "$conflict_files"
  return 1
}
