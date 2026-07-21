#!/usr/bin/env bash
# pr-base-drift-reconciler.sh - proactively merge origin/main into open engine
# PR heads whose GitHub mergeStateStatus shows base drift.
#
# This cron is additive to run_review_workflow's OE-253 reconcile. It drains
# obvious main-base drift before a review fire claims the review OE; the review
# path remains the fallback for PRs this cron missed.
#
# Usage:
#   bin/pr-base-drift-reconciler.sh            # reconcile up to MAX_RECONCILE
#   bin/pr-base-drift-reconciler.sh --dry-run  # print planned actions only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"
source "$SCRIPT_DIR/lib/reconcile.sh"

JQ=/opt/homebrew/bin/jq
RECONCILER_ID="pr-base-drift-reconciler v1.0"
# Enumerated repos only (OE-237) - never widen to a wildcard/any-repo match.
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
REPOS=("<repo-a>" "<repo-b>" "<repo-c>")
MAX_RECONCILE="${MAX_RECONCILE:-3}"
GITHUB_RATE_BACKOFF_SEC=61
GITHUB_RATE_MAX_ATTEMPTS=3
DRY_RUN=0
declare -a SCRATCH_WORKTREES=()

usage() {
  cat <<EOF
Usage:
  bin/pr-base-drift-reconciler.sh [--dry-run]
  bin/pr-base-drift-reconciler.sh --help

Proactively reconciles open mgoodric/{<repo-a>,<repo-b>,<repo-c>} PRs whose
base is main and whose mergeStateStatus is DIRTY or CONFLICTING. CLEAN pushes
HEAD to the PR head branch without force; CONFLICT/FATAL are logged only.
EOF
}

case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  --help|-h) usage; exit 0 ;;
  "") ;;
  *) echo "ERROR: unknown arg: $1 (try --help)" >&2; exit 1 ;;
esac

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now)" "$*"; }

GH=$(command -v gh 2>/dev/null) || GH=""
[ -n "$GH" ] || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
[ -x "$JQ" ] || { echo "ERROR: jq not found at $JQ" >&2; exit 1; }

cleanup() {
  local wt repo rest
  for wt in "${SCRATCH_WORKTREES[@]+"${SCRATCH_WORKTREES[@]}"}"; do
    [ -n "$wt" ] || continue
    rest="${wt#"$HOME/Development/.engine-worktrees/"}"
    repo="${rest%%/*}"
    if [ -n "$repo" ] && [ -d "$HOME/Development/$repo" ]; then
      git -C "$HOME/Development/$repo" worktree remove --force "$wt" >/dev/null 2>&1 || true
    fi
    if [ -e "$wt" ]; then
      rm -rf "$wt"
    fi
  done
  return 0
}
trap cleanup EXIT

gh_json() {
  local label="$1"; shift
  local out rc attempt
  for attempt in $(seq 1 "$GITHUB_RATE_MAX_ATTEMPTS"); do
    set +e
    out=$("$GH" "$@" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    if printf '%s' "$out" | grep -qiE '(^|[^0-9])429([^0-9]|$)|rate limit|secondary rate'; then
      if [ "$attempt" -lt "$GITHUB_RATE_MAX_ATTEMPTS" ]; then
        log "  gh $label: rate-limited - backing off ${GITHUB_RATE_BACKOFF_SEC}s (attempt $attempt/$GITHUB_RATE_MAX_ATTEMPTS)"
        sleep "$GITHUB_RATE_BACKOFF_SEC"
        continue
      fi
    fi
    printf '%s' "$out"
    return "$rc"
  done
}

create_scratch_worktree() {
  local repo="$1" pr_number="$2" base="$3" head="$4"
  local repo_path="$HOME/Development/$repo"
  local wt="$HOME/Development/.engine-worktrees/$repo/pr-drift-$pr_number"
  if [ ! -d "$repo_path" ]; then
    printf 'FATAL local checkout missing at %s' "$repo_path"
    return 2
  fi
  if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
    printf 'FATAL %s is not a git repo' "$repo_path"
    return 2
  fi
  git -C "$repo_path" worktree remove --force "$wt" >/dev/null 2>&1 || true
  [ -e "$wt" ] && rm -rf "$wt"
  mkdir -p "$(dirname "$wt")"
  if ! git -C "$repo_path" fetch origin "$base" "$head" --quiet >/dev/null 2>&1; then
    printf 'FATAL fetch origin %s %s failed' "$base" "$head"
    return 2
  fi
  if ! git -C "$repo_path" worktree add --detach "$wt" "origin/$base" --quiet >/dev/null 2>&1; then
    printf 'FATAL worktree add failed at %s' "$wt"
    return 2
  fi
  if ! repo_root_is_isolated "$wt"; then
    printf 'FATAL worktree %s resolves outside ~/Development/.engine-worktrees' "$wt"
    return 2
  fi
  printf '%s' "$wt"
}

should_reconcile() {
  local base="$1" mss="$2"
  [ "$base" = "main" ] || return 1
  [ "$mss" = "DIRTY" ] || [ "$mss" = "CONFLICTING" ]
}

log "$RECONCILER_ID: scanning open PRs in mgoodric/{<repo-a>,<repo-b>,<repo-c>}; max=$MAX_RECONCILE dry_run=$DRY_RUN"

acted=0
listed=0
skipped=0

for repo in "${REPOS[@]}"; do
  repo_slug="mgoodric/$repo"
  prs_json=$(gh_json "pr list $repo_slug" pr list --repo "$repo_slug" --state open --json number,url,baseRefName,headRefName,mergeStateStatus) || {
    detail=$(printf '%s' "$prs_json" | head -c 400 | tr '\n' ' ')
    log "repo=$repo: FATAL gh pr list failed: $detail"
    continue
  }
  while IFS= read -r pr; do
    [ -n "$pr" ] || continue
    number=$(printf '%s' "$pr" | "$JQ" -r '.number')
    url=$(printf '%s' "$pr" | "$JQ" -r '.url // ""')
    base=$(printf '%s' "$pr" | "$JQ" -r '.baseRefName // ""')
    head=$(printf '%s' "$pr" | "$JQ" -r '.headRefName // ""')
    mss=$(printf '%s' "$pr" | "$JQ" -r '.mergeStateStatus // ""')

    if ! printf '%s' "$url" | grep -Eq "^$PR_RE$"; then
      skipped=$((skipped+1))
      continue
    fi
    if ! should_reconcile "$base" "$mss"; then
      skipped=$((skipped+1))
      continue
    fi
    if [ "$listed" -ge "$MAX_RECONCILE" ]; then
      log "cap reached (MAX_RECONCILE=$MAX_RECONCILE); stopping scan early"
      break 2
    fi

    listed=$((listed+1))
    if [ "$DRY_RUN" -eq 1 ]; then
      log "PR-$number repo=$repo mss=$mss -> DRY-RUN would reconcile base=$base head=$head url=$url"
      continue
    fi

    set +e
    wt_out=$(create_scratch_worktree "$repo" "$number" "$base" "$head")
    wt_rc=$?
    set -e
    if [ "$wt_rc" -ne 0 ]; then
      detail=$(printf '%s' "$wt_out" | sed -E 's/^FATAL[[:space:]]*//')
      log "PR-$number repo=$repo mss=$mss -> FATAL $detail"
      continue
    fi
    wt="$wt_out"
    SCRATCH_WORKTREES+=("$wt")

    set +e
    reconcile_out=$(reconcile_pr_from_base "$wt" "$base" "$head")
    reconcile_rc=$?
    set -e
    case "$reconcile_rc" in
      0)
        sha=$(printf '%s' "$reconcile_out" | awk '{print $2}')
        if git -C "$wt" push origin "HEAD:refs/heads/$head" --quiet >/dev/null 2>&1; then
          log "PR-$number repo=$repo mss=$mss -> CLEAN $sha"
          acted=$((acted+1))
        else
          log "PR-$number repo=$repo mss=$mss -> FATAL push to refs/heads/$head failed"
        fi
        ;;
      1)
        files=$(printf '%s' "$reconcile_out" | sed -E 's/^CONFLICT[[:space:]]*//')
        log "PR-$number repo=$repo mss=$mss -> CONFLICT ${files:-unknown}"
        ;;
      *)
        detail=$(printf '%s' "$reconcile_out" | sed -E 's/^FATAL[[:space:]]*//')
        log "PR-$number repo=$repo mss=$mss -> FATAL $detail"
        ;;
    esac
  done < <(printf '%s' "$prs_json" | "$JQ" -c '.[]')
done

log "$RECONCILER_ID: intended=$listed reconciled=$acted skipped=$skipped"
