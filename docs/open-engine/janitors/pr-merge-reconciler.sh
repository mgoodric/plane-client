#!/usr/bin/env bash
# pr-merge-reconciler.sh — advance an OE to Agent Done when its linked PR merges
# out-of-band (OE-219). run_task_pipeline closes OEs it merges itself, but a PR
# merged manually (a held PR, or a prod-deploy PR cleared later) left its OE
# stranded in Agent Needs Input / Agent Review (OE-195/196/201).
#
# For each OE in Agent Needs Input or Agent Review carrying an enumerated-repo
# PR URL (mgoodric/{<repo-a>,<repo-b>,<repo-c>} — OE-237) in an AGENT receipt
# comment:
#   - PR MERGED           → post AGENT DONE (PR URL + merge SHA), move to Agent Done
#   - PR CLOSED unmerged  → post an AGENT FOLLOW-UP note once; leave state for Matt
#   - PR OPEN / unknown   → no action
#
# Guardrails (PR #23 review):
#   - Agent Working is NOT scanned: a mid-fire OE belongs to the live runner and
#     reconciling it races the fire (idempotence does not prevent yanking state).
#   - PR links are trusted ONLY when they appear in an AGENT receipt comment and
#     point at an enumerated repo: mgoodric/<repo-a>, mgoodric/<repo-b>, or
#     mgoodric/<repo-c> (OE-237 — engine OEs deliver into product repos too).
#     Never a wildcard/any-repo match. There is no raw-body fallback — an OE
#     that merely references an unrelated PR is never advanced.
#   - MAX_ADVANCE caps Agent Done advances per run; a batch of merged-but-wrong
#     PRs cannot mass-advance the queue in one cycle.
#   - Every Plane read/write retries on HTTP 429 (mirrors runner v3.17 plane_get
#     and v3.18 write-helper backoff). A 429'd comment read skips the OE for the
#     cycle instead of acting on partial data.
#
# Idempotent: prior reconciler receipts are detected before posting, and OEs in
# Agent Done leave the scan set. Read-only against GitHub; the only writes are
# the Plane receipt comment and the OE state PATCH.
#
# Usage:
#   bin/pr-merge-reconciler.sh            # reconcile
#   bin/pr-merge-reconciler.sh --dry-run  # print planned actions, change nothing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
RECONCILER_ID="pr-merge-reconciler v1.2"
RECONCILER_MARK="pr-merge-reconciler"   # version-agnostic idempotency marker
# Enumerated repos only (OE-237) — never widen to a wildcard/any-repo match.
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
MAX_ADVANCE="${MAX_ADVANCE:-3}"   # Agent Done advances per run; stop when reached
PLANE_RATE_BACKOFF_SEC=61      # 429 backoff; >60s guarantees Plane's per-minute
                               # throttle window (API_KEY_RATE_LIMIT) fully drains
PLANE_RATE_MAX_ATTEMPTS=3      # total tries per Plane call (2 backoffs), then give up
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now)" "$*"; }

GH=$(command -v gh 2>/dev/null) || GH=""
[ -n "$GH" ] || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
[ -r "$PAT_FILE" ] || { echo "ERROR: PAT missing at $PAT_FILE (run bin/refresh-pat.sh)" >&2; exit 1; }
PAT=$(cat "$PAT_FILE")
API="$PLANE_BASE/api/v1/workspaces/$PLANE_WORKSPACE/projects/$PLANE_PROJECT/issues/"

# Plane GET helper — mirrors runner-matt-claude.sh v3.17 plane_get (OE-227):
# up to PLANE_RATE_MAX_ATTEMPTS tries with PLANE_RATE_BACKOFF_SEC sleeps on 429.
# Echoes the final attempt's body on stdout; returns 0 only on HTTP 200 so
# callers can skip an OE rather than act on a rate-limited partial read.
# Args: 1=URL, 2=short label for the log, 3=curl --max-time (default 15).
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

# Write helpers retry on 429 like runner v3.18 hb()/post_comment()/patch_state().
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

state_name() {
  case "$1" in
    "$STATE_AGENT_NEEDS_INPUT") printf 'Agent Needs Input' ;;
    "$STATE_AGENT_REVIEW")      printf 'Agent Review' ;;
    *)                          printf '%s' "$1" ;;
  esac
}

# --- fetch all issues (cursor pagination, same shape as human-queue-digest) -----
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT; : > "$tmp"
cursor=""
for _ in $(seq 1 20); do   # 20-page safety cap
  url="$API?per_page=100"; [ -n "$cursor" ] && url="$url&cursor=$cursor"
  page=$(plane_get "$url" "issues page" 25) || break
  echo "$page" | "$JQ" -c '.results[]? // .[]?' >> "$tmp" 2>/dev/null || true
  more=$(echo "$page" | "$JQ" -r '.next_page_results // false' 2>/dev/null || echo false)
  cursor=$(echo "$page" | "$JQ" -r '.next_cursor // ""' 2>/dev/null || echo "")
  [ "$more" = "true" ] && [ -n "$cursor" ] || break
done

# Agent Working is deliberately excluded: those OEs belong to a live fire.
candidates=$("$JQ" -c \
  --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg review "$STATE_AGENT_REVIEW" \
  'select(.state == $needs or .state == $review)
   | {id, seq: .sequence_id, state, name}' \
  "$tmp")

count=$(printf '%s' "$candidates" | grep -c . || true)
log "reconciler: $count candidate OE(s) in Agent Needs Input / Agent Review"
[ "$count" -eq 0 ] && exit 0

advanced=0; flagged=0; skipped=0
while IFS= read -r issue_json; do
  [ -z "$issue_json" ] && continue
  issue_id=$(printf '%s' "$issue_json"  | "$JQ" -r '.id')
  seq=$(printf '%s' "$issue_json"       | "$JQ" -r '.seq')
  state_id=$(printf '%s' "$issue_json"  | "$JQ" -r '.state')

  # A failed comments read (429 exhausted, network) skips the OE — never act
  # on partial data (PR #23 review: the old path fell through to a body scan).
  comments_json=$(plane_get "$API$issue_id/comments/?per_page=100" "OE-$seq comments") || {
    log "OE-$seq: comments read failed — skipping this cycle"
    skipped=$((skipped+1)); continue
  }
  comments_arr=$(printf '%s' "$comments_json" | "$JQ" -c \
    'if type=="array" then . else (.results // []) end | sort_by(.created_at)' 2>/dev/null) \
    || comments_arr="[]"
  [ -n "$comments_arr" ] || comments_arr="[]"

  # PR URL: only the newest enumerated-repo PR URL (<repo-a>|<repo-b>|<repo-c>)
  # inside an AGENT receipt comment (the PR the pipeline actually opened/held).
  # No body fallback.
  agent_html=$(printf '%s' "$comments_arr" | "$JQ" -r \
    '[.[] | select(.comment_html // "" | test("AGENT [A-Z]")) | .comment_html] | join("\n")' 2>/dev/null) \
    || agent_html=""
  pr_url=$(printf '%s' "$agent_html" | grep -oE "$PR_RE" | tail -1 || true)
  if [ -z "$pr_url" ]; then
    skipped=$((skipped+1)); continue
  fi

  pr_json=$("$GH" pr view "$pr_url" --json state,mergeCommit 2>/dev/null) || {
    log "OE-$seq: gh pr view failed for $pr_url — skipping (no state change on unknown)"
    skipped=$((skipped+1)); continue
  }
  pr_state=$(printf '%s' "$pr_json" | "$JQ" -r '.state // ""')

  case "$pr_state" in
    MERGED)
      if [ "$advanced" -ge "$MAX_ADVANCE" ]; then
        log "OE-$seq: MERGED PR found but per-run advance cap reached (MAX_ADVANCE=$MAX_ADVANCE) — stopping; remaining OEs reconcile next cycle"
        break
      fi
      merge_sha=$(printf '%s' "$pr_json" | "$JQ" -r '.mergeCommit.oid // ""')
      receipt_html="<p><strong>AGENT DONE</strong></p><p>Agent: matt-claude · $RECONCILER_ID at $(now). $pr_url was merged out-of-band at <code>${merge_sha:-unknown}</code>. Reconciler advanced this OE from $(state_name "$state_id") to Agent Done (OE-219).</p>"
      if [ "$DRY_RUN" -eq 1 ]; then
        log "OE-$seq: DRY RUN — would post AGENT DONE ($pr_url @ ${merge_sha:-unknown}) and move to Agent Done"
        advanced=$((advanced+1)); continue
      fi
      # Idempotency: if a prior reconciler AGENT DONE receipt exists (comment
      # landed but the state PATCH failed last cycle), skip re-posting.
      already=$(printf '%s' "$comments_arr" | "$JQ" -r --arg id "$RECONCILER_MARK" \
        '[.[] | select((.comment_html // "" | contains($id)) and (.comment_html // "" | contains("AGENT DONE")))] | length' 2>/dev/null) || already=0
      if [ "${already:-0}" -gt 0 ]; then
        log "OE-$seq: reconciler AGENT DONE receipt already present — retrying state PATCH only"
      else
        post_comment "$issue_id" "$receipt_html" \
          || { log "OE-$seq: receipt POST failed — leaving state untouched this cycle"; skipped=$((skipped+1)); continue; }
      fi
      patch_state "$issue_id" "$STATE_AGENT_DONE" \
        && { log "OE-$seq: advanced to Agent Done ($pr_url @ ${merge_sha:-unknown})"; advanced=$((advanced+1)); } \
        || log "OE-$seq: state PATCH failed — will retry next cycle"
      ;;
    CLOSED)
      note_html="<p><strong>AGENT FOLLOW-UP</strong></p><p>Agent: matt-claude · $RECONCILER_ID at $(now). $pr_url was closed without merging. Leaving this OE in $(state_name "$state_id") for the operator — decide whether to re-fire, re-open the PR, or cancel (OE-219).</p>"
      if [ "$DRY_RUN" -eq 1 ]; then
        log "OE-$seq: DRY RUN — would flag closed-unmerged PR $pr_url (state unchanged)"
        flagged=$((flagged+1)); continue
      fi
      already=$(printf '%s' "$comments_arr" | "$JQ" -r --arg id "$RECONCILER_MARK" --arg u "$pr_url" \
        '[.[] | select((.comment_html // "" | contains($id)) and (.comment_html // "" | contains("closed without merging")) and (.comment_html // "" | contains($u)))] | length' 2>/dev/null) || already=0
      if [ "${already:-0}" -gt 0 ]; then
        skipped=$((skipped+1)); continue
      fi
      post_comment "$issue_id" "$note_html" \
        && { log "OE-$seq: flagged closed-unmerged PR $pr_url (state unchanged)"; flagged=$((flagged+1)); } \
        || log "OE-$seq: closed-unmerged note POST failed — will retry next cycle"
      ;;
    *)
      # OPEN or anything unexpected: never advance on open/unknown.
      skipped=$((skipped+1))
      ;;
  esac
done <<< "$candidates"

log "reconciler: advanced=$advanced flagged=$flagged no-action=$skipped"
