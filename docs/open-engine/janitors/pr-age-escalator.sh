#!/usr/bin/env bash
# pr-age-escalator.sh — visibility-only alert for old engine-authored PRs.
#
# For each open PR in the enumerated engine repos, alert the linked review OE
# once when the PR has been open longer than PR_AGE_ESCALATE_HOURS. This does
# not rebase, merge, review, patch Plane state, or write to GitHub; the only
# mutation is one Plane AGENT FOLLOW-UP comment per PR lifetime.
#
# Usage:
#   bin/pr-age-escalator.sh            # post at most MAX_ESCALATE_PER_RUN notes
#   bin/pr-age-escalator.sh --dry-run  # print intended escalations only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
ESCALATOR_ID="pr-age-escalator-v1"
ESCALATOR_MARK="pr-age-escalator-v1"
# Enumerated repos only (same contract as pr-merge-reconciler.sh). Do not widen.
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
REPOS=("mgoodric/<repo-a>" "mgoodric/<repo-b>" "mgoodric/<repo-c>")
PR_AGE_ESCALATE_HOURS="${PR_AGE_ESCALATE_HOURS:-4}"
MAX_ESCALATE_PER_RUN="${MAX_ESCALATE_PER_RUN:-5}"
PLANE_RATE_BACKOFF_SEC=61
PLANE_RATE_MAX_ATTEMPTS=3
DRY_RUN=0

if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
elif [ "${1:-}" != "" ]; then
  echo "Usage: bin/pr-age-escalator.sh [--dry-run]" >&2
  exit 2
fi

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(now)" "$*"; }
log_err() { printf '%s %s\n' "$(now)" "$*" >&2; }

GH=$(command -v gh 2>/dev/null) || GH=""
[ -n "$GH" ] || { echo "ERROR: gh CLI not found on PATH" >&2; exit 1; }
[ -x "$JQ" ] || { echo "ERROR: jq missing at $JQ" >&2; exit 1; }
[ -r "$PAT_FILE" ] || { echo "ERROR: PAT missing at $PAT_FILE (run bin/refresh-pat.sh)" >&2; exit 1; }
PAT=$(cat "$PAT_FILE")
API="$PLANE_BASE/api/v1/workspaces/$PLANE_WORKSPACE/projects/$PLANE_PROJECT/issues/"

"$JQ" -n -e --arg v "$PR_AGE_ESCALATE_HOURS" \
  '($v | test("^[0-9]+([.][0-9]+)?$")) and (($v | tonumber) >= 0)' >/dev/null \
  || { echo "ERROR: PR_AGE_ESCALATE_HOURS must be a non-negative number" >&2; exit 2; }
case "$MAX_ESCALATE_PER_RUN" in
  ''|*[!0-9]*) echo "ERROR: MAX_ESCALATE_PER_RUN must be an integer" >&2; exit 2 ;;
esac

# Plane GET helper — mirrors pr-merge-reconciler.sh: retry 429s and return
# non-zero on non-200 so callers never act on partial Plane data.
plane_get() {
  local url="$1" label="$2" max_time="${3:-15}"
  local out code body attempt
  for attempt in $(seq 1 "$PLANE_RATE_MAX_ATTEMPTS"); do
    out=$("$CURL" -sL -w $'\n%{http_code}' -H "X-API-Key: $PAT" \
      "$url" --max-time "$max_time") || { code=""; body=""; break; }
    code="${out##*$'\n'}"
    body="${out%$'\n'*}"
    [ "$code" != "429" ] && break
    [ "$attempt" -lt "$PLANE_RATE_MAX_ATTEMPTS" ] && { log_err "  GET $label: 429 rate-limited — backing off ${PLANE_RATE_BACKOFF_SEC}s (attempt $attempt/$PLANE_RATE_MAX_ATTEMPTS)"; sleep "$PLANE_RATE_BACKOFF_SEC"; }
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

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

age_hours() {
  "$JQ" -n -r --arg created "$1" '((now - ($created | fromdateiso8601)) / 3600)'
}

age_is_old_enough() {
  "$JQ" -n -e --argjson age "$1" --argjson threshold "$PR_AGE_ESCALATE_HOURS" \
    '$age >= $threshold' >/dev/null
}

# Fetch all Plane issues once so sequence-id lookup is local. Comment scanning
# still happens through Plane comments, matching pr-merge-reconciler's trusted
# AGENT-receipt source rather than issue body text.
issues_tmp=$(mktemp)
link_candidates_tmp=$(mktemp)
old_prs_tmp=$(mktemp)
trap 'rm -f "$issues_tmp" "$link_candidates_tmp" "$old_prs_tmp"' EXIT
: > "$issues_tmp"
: > "$link_candidates_tmp"
: > "$old_prs_tmp"
cursor=""
for _ in $(seq 1 20); do
  url="$API?per_page=100"; [ -n "$cursor" ] && url="$url&cursor=$cursor"
  page=$(plane_get "$url" "issues page" 25) || { log "issues page read failed — aborting without mutation"; exit 1; }
  echo "$page" | "$JQ" -c '.results[]? // .[]?' >> "$issues_tmp" 2>/dev/null || true
  more=$(echo "$page" | "$JQ" -r '.next_page_results // false' 2>/dev/null || echo false)
  cursor=$(echo "$page" | "$JQ" -r '.next_cursor // ""' 2>/dev/null || echo "")
  [ "$more" = "true" ] && [ -n "$cursor" ] || break
done

issue_count=$("$JQ" -s 'length' "$issues_tmp")
"$JQ" -c \
  --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg review "$STATE_AGENT_REVIEW" \
  'select(.state == $needs or .state == $review)' \
  "$issues_tmp" > "$link_candidates_tmp"
candidate_count=$("$JQ" -s 'length' "$link_candidates_tmp")
log "pr-age-escalator: loaded $issue_count Plane issue(s), $candidate_count link candidate(s); threshold=${PR_AGE_ESCALATE_HOURS}h cap=$MAX_ESCALATE_PER_RUN dry_run=$DRY_RUN"

find_issue_id_by_seq() {
  "$JQ" -r --argjson seq "$1" 'select(.sequence_id == $seq) | .id' "$issues_tmp" | head -1
}

comments_array_for_issue() {
  local issue_id="$1" seq="$2" comments_json
  comments_json=$(plane_get "$API$issue_id/comments/?per_page=100" "OE-$seq comments") || return 1
  printf '%s' "$comments_json" | "$JQ" -c \
    'if type=="array" then . else (.results // []) end | sort_by(.created_at)' 2>/dev/null
}

# Locate the review OE from a trusted AGENT receipt mentioning the PR URL. The
# current runner leaves this on the implementation OE as "review queued at
# OPENENGINE-N" / "Review handoff filed at OPENENGINE-N"; the last OPENENGINE-N
# in the same AGENT receipt is the review handoff.
locate_review_issue() {
  local pr_url="$1" issue_json issue_id seq comments_arr match_html review_seq review_id
  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    issue_id=$(printf '%s' "$issue_json" | "$JQ" -r '.id')
    seq=$(printf '%s' "$issue_json" | "$JQ" -r '.sequence_id')
    comments_arr=$(comments_array_for_issue "$issue_id" "$seq") || {
      log_err "OE-$seq: comments read failed during PR lookup — skipping this issue"
      continue
    }
    match_html=$(printf '%s' "$comments_arr" | "$JQ" -r --arg u "$pr_url" \
      '[.[] | select((.comment_html // "" | test("AGENT [A-Z]")) and (.comment_html // "" | contains($u))) | .comment_html] | last // ""' 2>/dev/null) \
      || match_html=""
    [ -n "$match_html" ] || continue
    review_seq=$(printf '%s' "$match_html" | grep -oE 'OPENENGINE-[0-9]+' | tail -1 | sed 's/OPENENGINE-//' || true)
    [ -n "$review_seq" ] || continue
    review_id=$(find_issue_id_by_seq "$review_seq")
    [ -n "$review_id" ] || continue
    printf '%s\t%s\n' "$review_id" "$review_seq"
    return 0
  done < "$link_candidates_tmp"
  return 1
}

already_escalated() {
  local comments_arr="$1" pr_url="$2"
  "$JQ" -e --arg mark "$ESCALATOR_MARK" --arg u "$pr_url" \
    '[.[] | select((.comment_html // "" | contains($mark)) and (.comment_html // "" | contains($u)))] | length > 0' \
    >/dev/null <<<"$comments_arr"
}

for repo in "${REPOS[@]}"; do
  "$GH" pr list --repo "$repo" --state open --limit 100 --json url,createdAt \
    | "$JQ" -c '.[]' >> "$old_prs_tmp"
done

escalated=0; skipped_young=0; skipped_unlinked=0; skipped_seen=0
while IFS= read -r pr_json; do
  [ -z "$pr_json" ] && continue
  pr_url=$(printf '%s' "$pr_json" | "$JQ" -r '.url')
  created_at=$(printf '%s' "$pr_json" | "$JQ" -r '.createdAt')
  if ! printf '%s' "$pr_url" | grep -Eq "^$PR_RE$"; then
    continue
  fi

  age=$(age_hours "$created_at")
  if ! age_is_old_enough "$age"; then
    skipped_young=$((skipped_young+1))
    continue
  fi
  if [ "$escalated" -ge "$MAX_ESCALATE_PER_RUN" ]; then
    log "per-run escalation cap reached (MAX_ESCALATE_PER_RUN=$MAX_ESCALATE_PER_RUN) — stopping; remaining PRs check next cycle"
    break
  fi

  link=$(locate_review_issue "$pr_url" || true)
  if [ -z "$link" ]; then
    log "$pr_url: old enough ($(printf '%.1f' "$age")h) but no linked review OE found — skipping"
    skipped_unlinked=$((skipped_unlinked+1))
    continue
  fi
  review_id="${link%%$'\t'*}"
  review_seq="${link##*$'\t'}"
  review_comments=$(comments_array_for_issue "$review_id" "$review_seq") || {
    log "OPENENGINE-$review_seq: comments read failed before idempotency check — skipping"
    skipped_unlinked=$((skipped_unlinked+1))
    continue
  }
  if already_escalated "$review_comments" "$pr_url"; then
    skipped_seen=$((skipped_seen+1))
    continue
  fi

  age_display=$(printf '%.1f' "$age")
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY RUN — would post AGENT FOLLOW-UP on OPENENGINE-$review_seq for $pr_url (open ${age_display}h)"
    escalated=$((escalated+1))
    continue
  fi

  safe_url=$(printf '%s' "$pr_url" | html_escape)
  note_html="<p><strong>AGENT FOLLOW-UP</strong></p><p>Agent: matt-codex · $ESCALATOR_ID at $(now). PR <a href=\"$safe_url\">$safe_url</a> has been open for ${age_display} hours (threshold ${PR_AGE_ESCALATE_HOURS}h). PR open hours — review queue may be deep or PR may be blocked on a real conflict; operator triage.</p><p>Idempotency: <code>$ESCALATOR_MARK</code></p>"
  post_comment "$review_id" "$note_html" \
    && { log "OPENENGINE-$review_seq: posted PR age follow-up for $pr_url (${age_display}h)"; escalated=$((escalated+1)); } \
    || log "OPENENGINE-$review_seq: follow-up POST failed for $pr_url — will retry next cycle"
done < "$old_prs_tmp"

log "pr-age-escalator: escalations=$escalated young=$skipped_young unlinked=$skipped_unlinked already_seen=$skipped_seen"
