#!/usr/bin/env bash
# superseded-oe-surfacer.sh — detect open OEs whose deliverable already
# appears on their target repo's default branch (via a sibling PR) and
# SURFACE them to the human-queue digest as candidate-cancellations (OE-308).
#
# NOT an auto-canceller. This session's Needs-Input triage showed most of
# what looked like "decisions" were actually superseded — a sibling OE
# already delivered the work on main via a clean PR — but auto-cancel is too
# risky (a wrong cancel loses real work). This surfaces the candidates to
# the human queue so the operator decides.
#
# Detection: an impl OE = title matches
#   [agent instructions][matt-<runtime>][<kind>]  where <kind> in (task|deploy)
# that is OPEN (Agent Todo | Agent Needs Input | Agent Review) — NOT Working,
# NOT Done, NOT Cancelled — carrying an enumerated-repo PR URL (<repo-a>
# |<repo-b>|<repo-c> — OE-237) in an AGENT receipt comment, AND for which the
# PR's diff against its base branch is EMPTY (zero additions + zero
# deletions). An empty-diff PR is a strong sibling-delivery signal: the OE
# opened a branch, but by the time the PR was rendered, the same work was
# already on the base branch via a sibling merge — nothing left to merge.
#
# Guardrails (mirror orphan-pr-review-reconciler OE-306 + honor OE-199
# cross-repo lesson + OE-308 boundaries):
#   - PR URL trust: enumerated repos ONLY, ONLY from AGENT receipt comments.
#     Cross-repo merged PRs never count as sibling delivery (OE-199).
#   - Squash-merge trap: an absent HEAD branch does NOT mean superseded.
#     Only an empty PR diff (additions=0 AND deletions=0) counts. We do NOT
#     probe branch existence directly — the PR's own diff is authoritative.
#   - Default branch trap: never hard-code "main". `gh pr view` returns
#     baseRefName from GitHub itself (hugo-main, master, whatever the repo
#     uses). We compare the PR against its own base, which is per-repo
#     accurate by construction.
#   - Kind filter: only task/deploy OEs are candidates. standing_skill /
#     standing_status / review OEs are SKIPPED — those are periodic /
#     process OEs and "superseded" does not apply.
#   - Agent Working excluded: a mid-fire OE belongs to the live runner and
#     surfacing it during the fire is confusing (the fire is actively
#     working; the "empty diff" would just be pre-push state).
#   - NEVER auto-cancels, NEVER changes state, NEVER patches the OE. The
#     only Plane write is an idempotent AGENT SUPERSEDED CANDIDATE receipt
#     posted once per OE per detection (marker-guarded). This preserves the
#     OE-308 boundary: "surface only, no auto-cancel — a wrong cancel loses
#     real work".
#   - MAX_SURFACE caps surfaces per run.
#   - Every Plane read/write retries on HTTP 429.
#
# Surface channel: writes the detected set to $STATE_DIR/superseded-candidates.txt
# (default $HOME/.local/state/openengine/). The human-queue-digest.sh cron
# reads this file and appends a "Candidate cancellations" section to its
# digest. The file is REWRITTEN each run (not appended), so stale entries
# drop naturally when an OE is cancelled / re-worked / integrated.
#
# Format of the state file (one line per candidate, tab-separated):
#   OE-<seq>\t<pr_url>\t<repo>\t<name>
#
# Scheduled off runner/PR-merge/orphan/false-done cadences: every 45min = 2700s.
#
# Usage:
#   bin/superseded-oe-surfacer.sh            # detect + write state + receipts
#   bin/superseded-oe-surfacer.sh --dry-run  # print planned actions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
SURFACER_ID="superseded-oe-surfacer v1.0"
SURFACER_MARK="superseded-oe-surfacer"   # version-agnostic idempotency marker
# Enumerated repos only (OE-237 — mirrors pr-merge-reconciler PR_RE).
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
IMPL_TITLE_RE='^\[agent instructions\]\[matt-(claude|codex)\]\[(task|deploy)\][[:space:]]'
MAX_SURFACE="${MAX_SURFACE:-5}"    # candidates surfaced per run
PLANE_RATE_BACKOFF_SEC=61
PLANE_RATE_MAX_ATTEMPTS=3
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# State dir contract (shared with human-queue-digest.sh): the digest reads
# $STATE_DIR/superseded-candidates.txt and appends a section iff the file
# exists and is non-empty. Both scripts resolve $STATE_DIR the same way.
STATE_DIR="${OE_STATE_DIR:-$HOME/.local/state/openengine}"
STATE_FILE="$STATE_DIR/superseded-candidates.txt"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now)" "$*"; }

GH=$(command -v gh 2>/dev/null) || GH=""
[ -n "$GH" ] || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
[ -r "$PAT_FILE" ] || { echo "ERROR: PAT missing at $PAT_FILE (run bin/refresh-pat.sh)" >&2; exit 1; }
PAT=$(cat "$PAT_FILE")
API="$PLANE_BASE/api/v1/workspaces/$PLANE_WORKSPACE/projects/$PLANE_PROJECT/issues/"

mkdir -p "$STATE_DIR" 2>/dev/null || true

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

# --- fetch all issues (cursor pagination) --------------------------------
tmp=$(mktemp); tmp_state=$(mktemp)
trap 'rm -f "$tmp" "$tmp_state"' EXIT
: > "$tmp"
cursor=""
for _ in $(seq 1 20); do
  url="$API?per_page=100"; [ -n "$cursor" ] && url="$url&cursor=$cursor"
  page=$(plane_get "$url" "issues page" 25) || break
  echo "$page" | "$JQ" -c '.results[]? // .[]?' >> "$tmp" 2>/dev/null || true
  more=$(echo "$page" | "$JQ" -r '.next_page_results // false' 2>/dev/null || echo false)
  cursor=$(echo "$page" | "$JQ" -r '.next_cursor // ""' 2>/dev/null || echo "")
  [ "$more" = "true" ] && [ -n "$cursor" ] || break
done

# Candidates: impl OEs (task|deploy) in Agent Todo / Needs Input / Review.
# Agent Working is deliberately excluded (live fire — false positive would be
# routine pre-push state); Agent Done handled by the false-Done backstop.
candidates=$("$JQ" -c \
  --arg todo "$STATE_AGENT_TODO" \
  --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg review "$STATE_AGENT_REVIEW" \
  --arg re "$IMPL_TITLE_RE" \
  'select((.state == $todo or .state == $needs or .state == $review)
          and (.name // "" | test($re)))
   | {id, seq: .sequence_id, state, name}' \
  "$tmp")

count=$(printf '%s' "$candidates" | grep -c . || true)
log "surfacer: $count open task/deploy OE(s) to scan for superseded work"
: > "$tmp_state"

if [ "$count" -eq 0 ]; then
  # Still refresh state file (empty) so digest drops any prior stale entries.
  if [ "$DRY_RUN" -eq 0 ]; then mv "$tmp_state" "$STATE_FILE"; fi
  exit 0
fi

surfaced=0; skipped=0; already=0
while IFS= read -r issue_json; do
  [ -z "$issue_json" ] && continue
  [ "$surfaced" -ge "$MAX_SURFACE" ] && { log "cap reached (MAX_SURFACE=$MAX_SURFACE); stopping scan"; break; }
  issue_id=$(printf '%s' "$issue_json"    | "$JQ" -r '.id')
  seq=$(printf '%s' "$issue_json"         | "$JQ" -r '.seq')
  issue_name=$(printf '%s' "$issue_json"  | "$JQ" -r '.name')

  comments_json=$(plane_get "$API$issue_id/comments/?per_page=100" "OE-$seq comments") || {
    log "OE-$seq: comments read failed — skipping this cycle"
    skipped=$((skipped+1)); continue
  }
  comments_arr=$(printf '%s' "$comments_json" | "$JQ" -c \
    'if type=="array" then . else (.results // []) end | sort_by(.created_at)' 2>/dev/null) \
    || comments_arr="[]"
  [ -n "$comments_arr" ] || comments_arr="[]"

  agent_html=$(printf '%s' "$comments_arr" | "$JQ" -r \
    '[.[] | select(.comment_html // "" | test("AGENT [A-Z]")) | .comment_html] | join("\n")' 2>/dev/null) \
    || agent_html=""
  pr_url=$(printf '%s' "$agent_html" | grep -oE "$PR_RE" | tail -1 || true)
  if [ -z "$pr_url" ]; then
    skipped=$((skipped+1)); continue
  fi

  # Superseded signal: PR diff is empty (additions+deletions == 0) against
  # its own base branch (baseRefName). We use additions/deletions rather
  # than probing git directly — GitHub is authoritative for PR state and
  # already reflects squash-merge, base-drift, and cross-branch history.
  # A MERGED PR always has additions>0 so this cannot false-positive on
  # merged work. A CLOSED-unmerged PR with 0/0 is the sibling-delivery
  # case we want to surface.
  pr_json=$("$GH" pr view "$pr_url" --json state,additions,deletions,baseRefName,headRefName 2>/dev/null) || {
    log "OE-$seq: gh pr view failed for $pr_url — skipping"
    skipped=$((skipped+1)); continue
  }
  pr_state=$(printf '%s' "$pr_json" | "$JQ" -r '.state // ""')
  additions=$(printf '%s' "$pr_json" | "$JQ" -r '.additions // 0')
  deletions=$(printf '%s' "$pr_json" | "$JQ" -r '.deletions // 0')

  # A MERGED PR is not superseded (it landed). Skip.
  if [ "$pr_state" = "MERGED" ]; then
    skipped=$((skipped+1)); continue
  fi

  # Empty-diff detection.
  if [ "${additions:-0}" -ne 0 ] || [ "${deletions:-0}" -ne 0 ]; then
    skipped=$((skipped+1)); continue
  fi

  # Extract repo name from PR URL for the state file (mgoodric/<repo>/pull/<n>).
  repo=$(printf '%s' "$pr_url" | sed -E 's|.*/mgoodric/([^/]+)/pull/[0-9]+.*|\1|')

  # Write the candidate row (always, so an idempotent receipt does not
  # keep the OE off the digest when the receipt is already there).
  printf 'OE-%s\t%s\t%s\t%s\n' "$seq" "$pr_url" "$repo" "$issue_name" >> "$tmp_state"

  # Post the marker receipt once (idempotent). The digest reads the state
  # file, not the receipts — so this comment is just for the OE's paper
  # trail so a reader lands directly on the reason.
  prior=$(printf '%s' "$comments_arr" | "$JQ" -r --arg id "$SURFACER_MARK" --arg u "$pr_url" \
    '[.[] | select((.comment_html // "" | contains($id)) and (.comment_html // "" | contains($u)))] | length' 2>/dev/null) || prior=0
  if [ "${prior:-0}" -gt 0 ]; then
    already=$((already+1))
    log "OE-$seq: prior receipt for $pr_url present — surfaced to digest, no new receipt"
    surfaced=$((surfaced+1)); continue
  fi

  receipt_html="<p><strong>AGENT SUPERSEDED CANDIDATE</strong></p><p>Agent: matt-claude · $SURFACER_ID at $(now). PR $pr_url has an EMPTY diff against baseRefName=$(printf '%s' "$pr_json" | "$JQ" -r '.baseRefName // "?"') (additions=0, deletions=0) while this OE is still open. Strong sibling-delivery signal: a peer OE likely delivered the same work already. Surfaced to the human-queue digest as a candidate-cancellation. NOT auto-cancelled (OE-308 boundary: a wrong cancel loses real work). Operator: verify + cancel if superseded, or close this OE with a note if the empty diff is expected.</p>"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "OE-$seq: DRY RUN — would surface (empty diff on $pr_url) and post receipt"
    surfaced=$((surfaced+1)); continue
  fi

  post_comment "$issue_id" "$receipt_html" \
    || log "OE-$seq: receipt POST failed — surfacing to digest anyway (receipt retries next cycle)"
  log "OE-$seq: surfaced as candidate-cancellation ($pr_url empty diff)"
  surfaced=$((surfaced+1))
done <<< "$candidates"

# Publish the state file (atomic move so digest never reads half-written).
if [ "$DRY_RUN" -eq 0 ]; then
  mv "$tmp_state" "$STATE_FILE"
  log "surfacer: wrote $(wc -l < "$STATE_FILE" | tr -d ' ') candidate(s) to $STATE_FILE"
else
  log "surfacer: DRY RUN — would write $(wc -l < "$tmp_state" | tr -d ' ') candidate(s) to $STATE_FILE"
fi

log "surfacer: surfaced=$surfaced already-marked=$already no-action=$skipped"
