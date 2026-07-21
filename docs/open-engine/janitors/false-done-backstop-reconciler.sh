#!/usr/bin/env bash
# false-done-backstop-reconciler.sh — detect Agent Done OEs whose work never
# integrated and route them back to Agent Review for human triage (OE-308).
#
# Backstop, not the primary gate. The OE-277 integration gate PREVENTS new
# false-Dones at Agent Done transition time; this cron catches anything that
# still slips through — a pre-OE-277 Done that lingered, a gate bypass, or a
# PR that regressed after Done was posted (revert, force-push over merged sha).
#
# Detection: an impl OE = title matches
#   [agent instructions][matt-<runtime>][<kind>]  where <kind> in (task|deploy)
# that is in Agent Done, whose AGENT receipts carry an enumerated-repo PR URL
# (<repo-a>|<repo-b>|<repo-c> — OE-237), AND for which the PR is NOT MERGED
# (state OPEN, CLOSED-unmerged, or missing). Filed = post AGENT REOPEN
# CANDIDATE receipt + move state Agent Done -> Agent Review for human triage.
#
# Guardrails (mirror orphan-pr-review-reconciler OE-306 + pr-merge-reconciler
# OE-219, and honor OE-199 cross-repo lesson + OE-308 boundaries):
#   - PR URL trust: enumerated repos ONLY, ONLY from AGENT receipt comments.
#     A PR URL in a random comment / OE body / description is IGNORED. Cross-
#     repo merged PRs never count (OE-199: engine OE claiming integration by
#     virtue of a merged <repo-b> PR is a conflation bug).
#   - Squash-merge trap: an absent HEAD branch does NOT mean unintegrated.
#     `gh pr view <url>` is authoritative — if state=MERGED, the work landed
#     regardless of whether the branch was deleted after squash.
#   - Default branch trap: never hard-code "main". `gh pr view` returns
#     baseRefName from GitHub itself (hugo-main, master, whatever the repo
#     uses). We do not compare to a hard-coded default at all — we trust the
#     PR's own base+merge state as the integration signal, which is per-repo
#     accurate by construction.
#   - Kind filter: only task/deploy OEs are expected to produce integrated
#     work via a PR. standing_skill / standing_status / review OEs are
#     SKIPPED — they can legitimately be Done without a repo PR.
#   - Idempotency: prior AGENT REOPEN CANDIDATE receipts carrying this
#     script's marker are detected and skip re-flagging. A prior receipt with
#     no state change (last cycle's PATCH failed) still allows the PATCH to
#     retry.
#   - MAX_FLAG caps flags per run so a batch of pre-OE-277 false-Dones cannot
#     mass-reopen the queue in a single cycle; remainder reconciles next run.
#   - Never re-fire, never merge PRs, never cancel OEs. Route to Agent Review
#     for the human/reviewer to decide (per OE-308 boundaries: "do NOT
#     silently re-fire").
#   - Every Plane read/write retries on HTTP 429 with 61s backoff (same
#     pattern as pr-merge-reconciler + orphan-pr-review-reconciler).
#
# Scheduled off runner/PR-merge/orphan cadences: every 30min = 1800s so its
# phase drifts against runner (720s), pr-merge (900s), orphan-pr-review
# (1500s), and pr-base-drift (varies).
#
# Usage:
#   bin/false-done-backstop-reconciler.sh            # reconcile
#   bin/false-done-backstop-reconciler.sh --dry-run  # print planned actions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
RECONCILER_ID="false-done-backstop-reconciler v1.0"
RECONCILER_MARK="false-done-backstop-reconciler"   # version-agnostic idempotency marker
# Enumerated repos only (OE-237 — mirrors pr-merge-reconciler PR_RE).
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
# Impl-OE title match: only task/deploy OEs are expected to integrate via a PR
# on their target repo. standing_skill/standing_status/review OEs can be
# legitimately Done without a repo PR (a standing OE re-firing on cadence, or
# a review OE that verified but did not merge).
IMPL_TITLE_RE='^\[agent instructions\]\[matt-(claude|codex)\]\[(task|deploy)\][[:space:]]'
MAX_FLAG="${MAX_FLAG:-3}"          # flags per run; stop when reached
PLANE_RATE_BACKOFF_SEC=61
PLANE_RATE_MAX_ATTEMPTS=3
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now)" "$*"; }

GH=$(command -v gh 2>/dev/null) || GH=""
[ -n "$GH" ] || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
[ -r "$PAT_FILE" ] || { echo "ERROR: PAT missing at $PAT_FILE (run bin/refresh-pat.sh)" >&2; exit 1; }
PAT=$(cat "$PAT_FILE")
API="$PLANE_BASE/api/v1/workspaces/$PLANE_WORKSPACE/projects/$PLANE_PROJECT/issues/"

# Plane GET with 429 backoff — mirrors pr-merge-reconciler.sh plane_get.
plane_get() {
  local url="$1" label="$2" max_time="${3:-15}"
  local out code body attempt
  for attempt in $(seq 1 "$PLANE_RATE_MAX_ATTEMPTS"); do
    out=$("$CURL" -sL -w $'\n%{http_code}' -H "X-API-Key: $PAT" \
      "$url" --max-time "$max_time") || { code=""; body=""; break; }
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
    [ "$code" != "429" ] && break
    [ "$attempt" -lt "$PLANE_RATE_MAX_ATTEMPTS" ] && { log "  GET $label: 429 rate-limited — backing off ${PLANE_RATE_BACKOFF_SEC}s (attempt $attempt/$PLANE_RATE_MAX_ATTEMPTS)"; sleep "$PLANE_RATE_BACKOFF_SEC"; }
  done
  printf '%s' "$body"
  [ "$code" = "200" ]
}

post_comment() {
  local issue="$1" html="$2" body code attempt
  body=$("$JQ" -nc --arg h "$html" '{comment_html:$h}')
  for attempt in $(seq 1 "$PLANE_RATE_MAX_ATTEMPTS"); do
    code=$("$CURL" -sL -o /dev/null -w "%{http_code}" -X POST \
      -H "X-API-Key: $PAT" -H "Content-Type: application/json" \
      -d "$body" "$API$issue/comments/" --max-time 15)
    [ "$code" != "429" ] && break
    [ "$attempt" -lt "$PLANE_RATE_MAX_ATTEMPTS" ] && { log "  comment POST issue=$issue: 429 rate-limited — backing off ${PLANE_RATE_BACKOFF_SEC}s (attempt $attempt/$PLANE_RATE_MAX_ATTEMPTS)"; sleep "$PLANE_RATE_BACKOFF_SEC"; }
  done
  log "  comment POST issue=$issue: $code"
  [ "$code" = "201" ]
}

patch_state() {
  local issue="$1" state="$2" code attempt
  for attempt in $(seq 1 "$PLANE_RATE_MAX_ATTEMPTS"); do
    code=$("$CURL" -sL -o /dev/null -w "%{http_code}" -X PATCH \
      -H "X-API-Key: $PAT" -H "Content-Type: application/json" \
      -d "{\"state\":\"$state\"}" "$API$issue/" --max-time 15)
    [ "$code" != "429" ] && break
    [ "$attempt" -lt "$PLANE_RATE_MAX_ATTEMPTS" ] && { log "  state PATCH issue=$issue: 429 rate-limited — backing off ${PLANE_RATE_BACKOFF_SEC}s (attempt $attempt/$PLANE_RATE_MAX_ATTEMPTS)"; sleep "$PLANE_RATE_BACKOFF_SEC"; }
  done
  log "  state PATCH issue=$issue -> $state: $code"
  [ "$code" = "200" ]
}

# --- fetch all issues (cursor pagination, same shape as pr-merge-reconciler)
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; : > "$tmp"
cursor=""
for _ in $(seq 1 20); do
  url="$API?per_page=100"; [ -n "$cursor" ] && url="$url&cursor=$cursor"
  page=$(plane_get "$url" "issues page" 25) || break
  echo "$page" | "$JQ" -c '.results[]? // .[]?' >> "$tmp" 2>/dev/null || true
  more=$(echo "$page" | "$JQ" -r '.next_page_results // false' 2>/dev/null || echo false)
  cursor=$(echo "$page" | "$JQ" -r '.next_cursor // ""' 2>/dev/null || echo "")
  [ "$more" = "true" ] && [ -n "$cursor" ] || break
done

# Candidates: impl OEs (task|deploy only) in Agent Done. `description_html` is
# carried through so the per-OE loop can parse "Scope: <path>" for the target
# repo (OE-199 cross-repo lesson: a merged PR in a DIFFERENT enumerated repo
# than the OE's Scope does not count as integration).
candidates=$("$JQ" -c \
  --arg done "$STATE_AGENT_DONE" \
  --arg re "$IMPL_TITLE_RE" \
  'select(.state == $done and (.name // "" | test($re)))
   | {id, seq: .sequence_id, state, name, desc: (.description_html // "")}' \
  "$tmp")

count=$(printf '%s' "$candidates" | grep -c . || true)
log "reconciler: $count task/deploy OE(s) in Agent Done to verify"
[ "$count" -eq 0 ] && exit 0

flagged=0; ok=0; skipped=0
while IFS= read -r issue_json; do
  [ -z "$issue_json" ] && continue
  issue_id=$(printf '%s' "$issue_json"    | "$JQ" -r '.id')
  seq=$(printf '%s' "$issue_json"         | "$JQ" -r '.seq')
  issue_name=$(printf '%s' "$issue_json"  | "$JQ" -r '.name')
  desc=$(printf '%s' "$issue_json"        | "$JQ" -r '.desc // ""')

  # OE-199 conflation guard: extract the target repo from the OE body's
  # "Scope: /path/to/<repo>" line (a convention every OE follows — see
  # skills/to-engine template). If parseable, restrict the PR URL match to
  # that exact enumerated repo. If not parseable, fall back to the parent's
  # enumerated-any-repo behavior (with a log note) — the fallback still
  # excludes non-enumerated repos and matches the parent detection.
  scope_repo=$(printf '%s' "$desc" | grep -oE 'Scope:[[:space:]]*/[^<[:space:]]*/(<repo-a>|<repo-b>|<repo-c>)' 2>/dev/null | head -1 | sed -E 's#.*/(<repo-a>|<repo-b>|<repo-c>).*#\1#' 2>/dev/null || true)
  if [ -n "$scope_repo" ]; then
    scope_pr_re="https://github\\.com/mgoodric/${scope_repo}/pull/[0-9]+"
  else
    scope_pr_re="$PR_RE"
    log "OE-$seq: Scope line missing/unparseable — falling back to any-enumerated-repo PR match (OE-199 guard partial)"
  fi

  comments_json=$(plane_get "$API$issue_id/comments/?per_page=100" "OE-$seq comments") || {
    log "OE-$seq: comments read failed — skipping this cycle"
    skipped=$((skipped+1)); continue
  }
  comments_arr=$(printf '%s' "$comments_json" | "$JQ" -c \
    'if type=="array" then . else (.results // []) end | sort_by(.created_at)' 2>/dev/null) \
    || comments_arr="[]"
  [ -n "$comments_arr" ] || comments_arr="[]"

  # --- PR URL: only from AGENT receipt comments; if Scope parsed, ONLY the
  # OE's own target repo — a merged PR in a different enumerated repo is
  # not integration for THIS OE (OE-199 cross-repo lesson).
  agent_html=$(printf '%s' "$comments_arr" | "$JQ" -r \
    '[.[] | select(.comment_html // "" | test("AGENT [A-Z]")) | .comment_html] | join("\n")' 2>/dev/null) \
    || agent_html=""
  pr_url=$(printf '%s' "$agent_html" | grep -oE "$scope_pr_re" | tail -1 || true)

  if [ -z "$pr_url" ]; then
    # A task/deploy OE with no enumerated PR URL in AGENT receipts is
    # suspicious: OE-277 gate requires an integration signal before Agent
    # Done, so a missing PR URL means the gate was bypassed, the OE
    # predates the gate, or the deliverable landed via a channel we don't
    # trust (unenumerated repo, direct main push). Flag for triage.
    reason="no enumerated PR URL in AGENT receipts — cannot verify integration"
    pr_display="(no PR URL found)"
  else
    pr_json=$("$GH" pr view "$pr_url" --json state,mergeCommit,baseRefName 2>/dev/null) || {
      log "OE-$seq: gh pr view failed for $pr_url — skipping this cycle"
      skipped=$((skipped+1)); continue
    }
    pr_state=$(printf '%s' "$pr_json" | "$JQ" -r '.state // ""')
    if [ "$pr_state" = "MERGED" ]; then
      # Integration confirmed. Squash-merge safe: `gh pr view` returns
      # state=MERGED regardless of whether the source branch was deleted
      # after the merge (the branch-absent != stranded trap). Base branch
      # is per-repo authoritative from GitHub (baseRefName), so hugo-main
      # or master repos are handled without hard-coding "main".
      ok=$((ok+1)); continue
    fi
    reason="PR $pr_url state=$pr_state (not MERGED) — work not integrated on baseRefName=$(printf '%s' "$pr_json" | "$JQ" -r '.baseRefName // "?"')"
    pr_display="$pr_url"
  fi

  # Idempotency: has the reconciler already flagged this OE with a REOPEN
  # CANDIDATE receipt carrying our marker? If so, still allow state PATCH
  # to retry (last cycle may have failed after receipt landed).
  prior_receipt=$(printf '%s' "$comments_arr" | "$JQ" -r --arg id "$RECONCILER_MARK" \
    '[.[] | select((.comment_html // "" | contains($id)) and (.comment_html // "" | contains("AGENT REOPEN CANDIDATE")))] | length' 2>/dev/null) || prior_receipt=0

  if [ "$flagged" -ge "$MAX_FLAG" ]; then
    log "OE-$seq: false-Done detected but per-run cap reached (MAX_FLAG=$MAX_FLAG) — stopping; remaining reconcile next cycle"
    break
  fi

  receipt_html="<p><strong>AGENT REOPEN CANDIDATE</strong></p><p>Agent: matt-claude · $RECONCILER_ID at $(now). This OE is in Agent Done but its work does NOT appear integrated: $reason. Backstop for OE-277's Agent-Done integration gate; catches pre-gate Dones and any regression that slips through. Routing to Agent Review for human triage (per OE-308: do NOT silently re-fire — the reviewer decides whether to re-fire, roll forward, or cancel). PR ref: $pr_display.</p>"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "OE-$seq: DRY RUN — would flag ($reason) and move to Agent Review"
    flagged=$((flagged+1)); continue
  fi

  if [ "${prior_receipt:-0}" -gt 0 ]; then
    log "OE-$seq: prior REOPEN CANDIDATE receipt present — retrying state PATCH only"
  else
    post_comment "$issue_id" "$receipt_html" \
      || { log "OE-$seq: receipt POST failed — leaving state untouched this cycle"; skipped=$((skipped+1)); continue; }
  fi
  patch_state "$issue_id" "$STATE_AGENT_REVIEW" \
    && { log "OE-$seq: flagged as false-Done, moved Agent Done -> Agent Review ($reason)"; flagged=$((flagged+1)); } \
    || log "OE-$seq: state PATCH failed — will retry next cycle"
done <<< "$candidates"

log "reconciler: flagged=$flagged verified-integrated=$ok no-action=$skipped"
