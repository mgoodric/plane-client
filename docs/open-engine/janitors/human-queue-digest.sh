#!/usr/bin/env bash
# human-queue-digest.sh — post a digest of Open Engine work that needs Matt to
# the notification-hub (#agent-work). "Needs Matt" = any non-terminal issue
# labelled `human-action` or `pair-session`, OR any issue in Agent Needs Input.
#
# Purpose: stop human-required follow-ups from getting lost. Files nothing;
# read-only against Plane + one POST to the hub. Fire-and-forget, safe to cron.
#
# Usage:
#   bin/human-queue-digest.sh            # query + post digest (skips if empty)
#   bin/human-queue-digest.sh --dry-run  # print the digest, do NOT post
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PLANE_CLI="$SCRIPT_DIR/plane"
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Superseded-candidates state file, written by bin/superseded-oe-surfacer.sh
# (OE-308). Format: one OE per line, tab-separated `OE-<seq>\t<pr_url>\t<repo>
# \t<name>`. Absent or empty file = no candidate-cancellations to surface. The
# surfacer rewrites the file each run so cancelled / integrated OEs drop out
# automatically. See bin/superseded-oe-surfacer.sh header for the contract.
SUPERSEDED_STATE_DIR="${OE_STATE_DIR:-$HOME/.local/state/openengine}"
SUPERSEDED_STATE_FILE="$SUPERSEDED_STATE_DIR/superseded-candidates.txt"

# The plane CLI (OPENENGINE-254) encapsulates cursor pagination
# (next_page_results signal), 429 retry with backoff, control-char strip
# on response echoes, and PAT resolution via ~/.config/openengine/plane-pat.
# It replaces the hand-rolled `curl … per_page/next_cursor` loop this
# script used to carry (migrated in OPENENGINE-256).
[ -x "$PLANE_CLI" ] || { echo "ERROR: plane CLI missing at $PLANE_CLI (run bin/bootstrap-plane.sh or check the engine checkout)" >&2; exit 1; }

# --- fetch all issues via the plane CLI ---------------------------------------
# `plane list --json` returns a JSON array of every issue in the project
# (pagination handled internally). No --state filter here on purpose:
# Plane's REST endpoint ignores server-side state= (verified live
# 2026-07-09) and the classifier below already filters client-side by
# state + label. Keeping the fetch state-agnostic mirrors the
# pre-migration behavior exactly.
tmp=$(mktemp)
if ! "$PLANE_CLI" list --json > "$tmp"; then
  echo "ERROR: plane list failed — see stderr above" >&2
  rm -f "$tmp"
  exit 1
fi

# --- filter to the "needs Matt" surface ----------------------------------------
# non-terminal (exclude Agent Done + Cancelled); label human-action/pair-session
# OR state == Agent Needs Input. Emit "OE-<seq>\t<category>\t<name>".
# Input is already a JSON array (from `plane list --json`), so no -s/slurp.
rows=$("$JQ" -r \
  --arg human "$HUMAN_ACTION_LABEL" \
  --arg pair "$PAIR_SESSION_LABEL" \
  --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg done "$STATE_AGENT_DONE" \
  --arg cancelled "$STATE_CANCELLED" '
  map(select(.state != $done and .state != $cancelled))
  | map(select(
      (.labels // [] | index($human)) or
      (.labels // [] | index($pair)) or
      (.state == $needs)
    ))
  | map({
      seq: .sequence_id,
      cat: (
        if (.labels // [] | index($human)) then "human-action"
        elif (.labels // [] | index($pair)) then "pair-session"
        else "needs-input" end),
      name: (.name // "(untitled)")
    })
  | sort_by(.cat, .seq)
  | .[] | "OE-\(.seq)\t\(.cat)\t\(.name)"
' "$tmp")
rm -f "$tmp"

# --- read superseded-candidate rows (OE-308) -----------------------------------
# Written by bin/superseded-oe-surfacer.sh. Missing/empty file = zero entries.
# Kept separate from the primary "needs Matt" surface so the operator sees
# candidate-cancellations distinctly from real Needs-Input decisions.
superseded_rows=""
if [ -s "$SUPERSEDED_STATE_FILE" ]; then
  superseded_rows=$(cat "$SUPERSEDED_STATE_FILE")
fi
superseded_count=$(printf '%s' "$superseded_rows" | grep -c . || true)

count=$(printf '%s' "$rows" | grep -c . || true)
if [ "$count" -eq 0 ] && [ "$superseded_count" -eq 0 ]; then
  echo "Human Queue is clear — nothing to post."
  exit 0
fi

# --- build digest body ----------------------------------------------------------
total=$((count + superseded_count))
title="[OE Human Queue] $total item(s) need you"
body=""
if [ "$count" -gt 0 ]; then
  body+="These Open Engine items require your input to move forward:"$'\n'
  while IFS=$'\t' read -r oe cat name; do
    [ -z "$oe" ] && continue
    body+=$'\n'"• $oe [$cat] — $name"
  done <<< "$rows"
  body+=$'\n\n'
fi
if [ "$superseded_count" -gt 0 ]; then
  body+="Candidate cancellations (deliverable appears superseded — verify + cancel or note why to keep):"$'\n'
  while IFS=$'\t' read -r oe pr_url repo name; do
    [ -z "$oe" ] && continue
    body+=$'\n'"• $oe [superseded-candidate] — $name (empty-diff PR: $pr_url)"
  done <<< "$superseded_rows"
  body+=$'\n\n'
fi
body+="Open the Human Queue in Plane (filter: label human-action/pair-session, or state Agent Needs Input)."

if [ "$DRY_RUN" -eq 1 ]; then
  echo "── DRY RUN (not posting) ──────────────"
  echo "title: $title"; echo "$body"
  exit 0
fi

# --- post to notification-hub (topic=openengine) --------------------------------
[ -z "${NOTIFICATION_HUB_URL:-}" ] && { echo "NOTIFICATION_HUB_URL empty — digest not sent."; exit 0; }
today=$(date +%Y%m%d)
payload=$("$JQ" -nc \
  --arg src "openengine-human-queue-digest" \
  --arg sev "info" --arg topic "openengine" \
  --arg title "$title" --arg body "$body" \
  --arg dk "human-queue-$today" \
  '{source:$src, severity:$sev, topic:$topic, title:$title, body:$body, hints:{dedupe_key:$dk, dedupe_window_seconds:82800}}')
code=$("$CURL" -sS -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
  --max-time 8 -d "$payload" "$NOTIFICATION_HUB_URL" || echo "000")
echo "posted digest ($total items: $count needs-input, $superseded_count superseded-candidate) → hub HTTP $code"
