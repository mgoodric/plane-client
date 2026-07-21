#!/usr/bin/env bash
# orphan-pr-review-reconciler.sh — file a [review] OE for an orphaned mergeable
# PR whose impl OE is stuck in Agent Review with no live reviewer (OE-306).
#
# Loop-closing backstop. runner-matt-claude / runner-matt-codex file a
# [review] follow-on OE from every PR-opening close path via OE-304's
# file_review_oe_for_pr helper — but a fire predating that fix, a Plane
# hiccup at filing time, or any bug that regresses the helper can still land
# an impl OE in Agent Review with no reviewer. Live case: OE-282 opened
# <repo-b> PR #81 via a close path that skipped review-OE filing; the PR sat
# mergeable for days until an operator hand-filed OE-284. This script is
# the standing scan that catches any such orphan on the next cadence.
#
# Detection: an impl OE = title matches
#   [agent instructions][matt-<runtime>][<kind>]  where <kind> != review
# that is in Agent Review, has an OPEN + MERGEABLE PR carried in an AGENT
# receipt comment (enumerated repos only, OE-237), AND has no live
# [review]-kind OE tracking it (a live reviewer = a [review] OE in Agent
# Todo / Agent Working / Agent Needs Input / Agent Review whose title
# carries the impl OE sequence id — the runner's file_review_oe_for_pr
# naming convention "OE-<impl_seq>: <clean impl title>").
#
# Guardrails:
#   - Read-mostly against Plane: files a new [review] OE via bin/to-engine.sh
#     and posts a single receipt comment on the impl OE. NEVER merges PRs,
#     cancels OEs, or changes impl-OE state (the OE-306 body: "must NOT
#     merge PRs, cancel OEs, or change impl-OE state in this slice").
#   - Read-only against GitHub: gh pr view for state/mergeability. No writes.
#   - PR URL trust mirrors pr-merge-reconciler (OE-237): the enumerated
#     repos regex applied ONLY to AGENT receipt comment HTML — never to
#     an issue body / description, never to a wildcard repo pattern.
#   - Dedupe is BOTH structural (no live [review] OE exists) AND
#     idempotent (a prior AGENT FOLLOW-UP receipt marked with
#     $RECONCILER_MARK skips re-posting; retry only files if the receipt
#     landed but the to-engine call failed last cycle).
#   - MAX_FILE caps [review] OEs filed per run; a batch of orphans cannot
#     flood the queue in one cycle — remaining orphans reconcile next run.
#   - Every Plane read/write retries on HTTP 429 with a 61s backoff (same
#     pattern as pr-merge-reconciler + runner-matt-claude plane_get/hb).
#
# Scheduled staggered off the runner fire (every 12min = 720s) and off
# pr-merge-reconciler (every 15min = 900s) — this runs every 25min = 1500s
# so its phase drifts against both and it never triggers alongside a live
# fire (which is running in Agent Working; this scan skips Agent Working
# entirely, so there is no race even in the aliased case).
#
# Usage:
#   bin/orphan-pr-review-reconciler.sh            # reconcile
#   bin/orphan-pr-review-reconciler.sh --dry-run  # print planned actions
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
RECONCILER_ID="orphan-pr-review-reconciler v1.0"
RECONCILER_MARK="orphan-pr-review-reconciler"   # version-agnostic idempotency marker
# Enumerated repos only (OE-237 — mirrors pr-merge-reconciler PR_RE).
PR_RE='https://github\.com/mgoodric/(<repo-a>|<repo-b>|<repo-c>)/pull/[0-9]+'
# Impl-OE title match: any runtime, any kind EXCEPT review. review OEs
# themselves in Agent Review do not need a further reviewer.
IMPL_TITLE_RE='^\[agent instructions\]\[matt-(claude|codex)\]\[(task|deploy|standing_skill|standing_status)\][[:space:]]'
# Review-OE title match: matt-claude is the only reviewer runtime (matt-codex
# fires DO file reviews, but they file them AS matt-claude — the reviewer
# needs Claude for content review). Naming convention: file_review_oe_for_pr
# builds "[agent instructions][matt-claude][review] OE-<impl_seq>: ..."
REVIEW_TITLE_RE='^\[agent instructions\]\[matt-claude\]\[review\][[:space:]]'
MAX_FILE="${MAX_FILE:-3}"          # review OEs filed per run; stop when reached
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
TO_ENGINE="$SCRIPT_DIR/to-engine.sh"
[ -x "$TO_ENGINE" ] || { echo "ERROR: to-engine.sh not executable at $TO_ENGINE" >&2; exit 1; }

# Plane GET with 429 backoff — mirrors pr-merge-reconciler.sh plane_get. Echoes
# body on stdout; returns 0 only on HTTP 200 so callers can skip on partial data.
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

# Strip the "[agent instructions][matt-{claude,codex}][KIND] " prefix — same
# rule the runners use (bin/runner-matt-claude.sh:_strip_title_prefix).
strip_title_prefix() {
  printf '%s' "$1" | sed -E 's/^\[agent instructions\]\[(matt-claude|matt-codex)\]\[[^]]+\][[:space:]]*//'
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

# Candidates: impl OEs in Agent Review.
candidates=$("$JQ" -c \
  --arg review "$STATE_AGENT_REVIEW" \
  --arg re "$IMPL_TITLE_RE" \
  'select(.state == $review and (.name // "" | test($re)))
   | {id, seq: .sequence_id, state, name}' \
  "$tmp")

# Live reviewers: [review]-kind OEs currently in a live state (Agent Todo,
# Working, Needs Input, Review). Emitted as {seq_ref} entries where seq_ref
# is the impl-OE seq embedded in the reviewer's title after the KIND bracket
# (the file_review_oe_for_pr naming contract: "... OE-<impl_seq>: ...").
# Reviewers that don't carry an OE-<n> suffix (hand-filed, non-conforming)
# are still counted below via a full-title scan against the candidate seq.
live_reviewer_titles=$("$JQ" -c \
  --arg todo "$STATE_AGENT_TODO" \
  --arg working "$STATE_AGENT_WORKING" \
  --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg review "$STATE_AGENT_REVIEW" \
  --arg re "$REVIEW_TITLE_RE" \
  'select((.state == $todo or .state == $working or .state == $needs or .state == $review)
          and (.name // "" | test($re)))
   | .name' \
  "$tmp")

count=$(printf '%s' "$candidates" | grep -c . || true)
live_ct=$(printf '%s' "$live_reviewer_titles" | grep -c . || true)
log "reconciler: $count impl OE(s) in Agent Review; $live_ct live [review] OE(s) tracking known impls"
[ "$count" -eq 0 ] && exit 0

filed=0; skipped=0; dedup=0
while IFS= read -r issue_json; do
  [ -z "$issue_json" ] && continue
  issue_id=$(printf '%s' "$issue_json"    | "$JQ" -r '.id')
  seq=$(printf '%s' "$issue_json"         | "$JQ" -r '.seq')
  issue_name=$(printf '%s' "$issue_json"  | "$JQ" -r '.name')

  # --- Structural dedupe: does a live [review] OE reference this impl seq?
  # Reviewer titles carry "OE-<seq>:" per the runner's naming contract.
  # Anchor the boundary so OE-3 does not match OE-30 (OE-237 lesson:
  # substring-in-name matches burn — same reason PR_RE is enumerated).
  if printf '%s' "$live_reviewer_titles" | "$JQ" -r --arg s "$seq" \
     'select(test("OE-" + $s + "(:| |\\]|,|$)"))' 2>/dev/null | grep -q . ; then
    log "OE-$seq: live [review] OE already tracks this impl — skipping (dedupe)"
    dedup=$((dedup+1)); continue
  fi

  # --- PR URL: only from AGENT receipt comments, enumerated repos only.
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
    log "OE-$seq: no enumerated PR URL in AGENT receipt comments — skipping"
    skipped=$((skipped+1)); continue
  fi

  # --- Idempotency: has the reconciler already posted a FOLLOW-UP receipt
  # for this PR on this impl OE? (Filing may have failed after the receipt
  # landed last cycle; treat as still-orphaned only if no live reviewer AND
  # no prior receipt for this PR URL — otherwise skip to avoid double-file.)
  prior_receipt=$(printf '%s' "$comments_arr" | "$JQ" -r --arg id "$RECONCILER_MARK" --arg u "$pr_url" \
    '[.[] | select((.comment_html // "" | contains($id)) and (.comment_html // "" | contains($u)))] | length' 2>/dev/null) || prior_receipt=0
  if [ "${prior_receipt:-0}" -gt 0 ]; then
    log "OE-$seq: prior reconciler receipt for $pr_url present but still no live reviewer — logging and skipping (needs operator triage)"
    skipped=$((skipped+1)); continue
  fi

  # --- PR liveness gate: OPEN + MERGEABLE.
  pr_json=$("$GH" pr view "$pr_url" --json state,mergeable,mergeStateStatus,title,additions,deletions 2>/dev/null) || {
    log "OE-$seq: gh pr view failed for $pr_url — skipping"
    skipped=$((skipped+1)); continue
  }
  pr_state=$(printf '%s' "$pr_json" | "$JQ" -r '.state // ""')
  pr_mergeable=$(printf '%s' "$pr_json" | "$JQ" -r '.mergeable // ""')
  pr_title=$(printf '%s' "$pr_json" | "$JQ" -r '.title // ""')
  if [ "$pr_state" != "OPEN" ] || [ "$pr_mergeable" != "MERGEABLE" ]; then
    log "OE-$seq: PR $pr_url state=$pr_state mergeable=$pr_mergeable — not orphaned-mergeable; pr-merge-reconciler handles merged/closed"
    skipped=$((skipped+1)); continue
  fi

  # --- File the [review] OE.
  if [ "$filed" -ge "$MAX_FILE" ]; then
    log "OE-$seq: orphaned mergeable PR $pr_url found but per-run cap reached (MAX_FILE=$MAX_FILE) — stopping; remaining orphans reconcile next cycle"
    break
  fi

  clean_impl_title=$(strip_title_prefix "$issue_name")
  review_title="[agent instructions][matt-claude][review] OE-$seq: $clean_impl_title"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "OE-$seq: DRY RUN — would file $review_title for $pr_url"
    filed=$((filed+1)); continue
  fi

  # Body mirrors the OE-304 file_review_oe_for_pr shape (reviewer body the
  # runner already files). Kept inline rather than sourced so this script
  # has zero cross-file dependencies at runtime — the runner is a large,
  # fast-moving surface and sourcing it would tangle blast radius.
  review_body_file=$(mktemp /tmp/orphan-review-body.XXXXXX.md)
  cat > "$review_body_file" <<EOF
## Requester

orphan-pr-review-reconciler (OE-306 backstop). The impl OE OPENENGINE-$seq landed in Agent Review with an OPEN + MERGEABLE PR but no live [review] OE tracking it. Filed to close the loop so the PR gets merged without operator intervention.

## Desired outcome

matt-claude reviews PR $pr_url, runs tests if present, and either:
- **Pass**: merges via \`gh pr merge --squash --delete-branch\`, posts AGENT DONE here, files a deploy OE per pipeline.md §4.
- **Fail**: posts \`gh pr review --request-changes\` comments on the PR, leaves this OE in Agent Review for Matt to triage, posts AGENT BLOCKED here with the failing criteria.

## PR details

- URL: $pr_url
- Parent impl OE: OPENENGINE-$seq
- Filed by: $RECONCILER_ID at $(now)

## Sources

- \`~/Development/<repo-a>/docs/pipeline.md\` §3 (review stage contract)
- OE-306 (this reconciler)
- OE-282 / OE-284 (the live orphaned-PR case this backstop catches)

## Do

1. \`gh pr view $pr_url\` — confirm PR is open + mergeable.
2. \`gh pr diff $pr_url\` — scan the diff for obvious issues.
3. If the repo has a test command in its README or Makefile, run it inside the worktree.
4. Decision branching per pipeline.md §3.
EOF

  filing_out=$("$TO_ENGINE" \
    --title "$review_title" \
    --body-file "$review_body_file" \
    --runtime matt-claude 2>&1) || {
    rm -f "$review_body_file"
    log "OE-$seq: to-engine.sh failed for $pr_url — will retry next cycle. Output: $filing_out"
    skipped=$((skipped+1)); continue
  }
  rm -f "$review_body_file"
  review_oe_seq=$(printf '%s' "$filing_out" | awk '/^[0-9a-f-]{36} [0-9]+ / { print $2; exit }')
  if [ -z "$review_oe_seq" ]; then
    log "OE-$seq: to-engine.sh returned no seq for $pr_url — will retry next cycle. Output: $filing_out"
    skipped=$((skipped+1)); continue
  fi

  # Receipt on the impl OE so the operator has a paper trail.
  receipt_html="<p><strong>AGENT FOLLOW-UP</strong></p><p>Agent: matt-claude · $RECONCILER_ID at $(now). Detected orphaned mergeable PR $pr_url with no live [review] OE — filed OPENENGINE-$review_oe_seq (matt-claude reviewer) so the PR gets merged without operator intervention (OE-306 backstop for the OE-282→OE-284 shape).</p>"
  post_comment "$issue_id" "$receipt_html" \
    || log "OE-$seq: receipt POST failed after filing OPENENGINE-$review_oe_seq — receipt will retry next cycle; the review OE is already queued"
  log "OE-$seq: filed OPENENGINE-$review_oe_seq for $pr_url"
  filed=$((filed+1))
done <<< "$candidates"

log "reconciler: filed=$filed deduped=$dedup no-action=$skipped"
