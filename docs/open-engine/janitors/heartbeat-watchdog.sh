#!/bin/bash
# Open Engine heartbeat watchdog (v2 — multi-runtime)
#
# Watches every AGENT STATUS heartbeat comment on OPENENGINE-3 and emits a
# local macOS notification when ANY of them has not been updated within the
# threshold (30 min) during waking hours (07:00–23:00 America/Los_Angeles).
#
# Each agent_code:comment_id pair is checked independently; stale agents get
# their own per-agent notification so the body text is unambiguous.
#
# v2 changes vs v1:
#   - HEARTBEAT scalar → AGENTS array (agent_code:comment_id pairs)
#   - One Plane GET per agent (still all read-only)
#   - One notification per stale agent (vs one combined)
#   - Exit code: 1 if ANY stale, 0 if all healthy
#
# This is observability, not part of the engine protocol:
#   - Plane interaction is read-only (one GET per agent on its heartbeat).
#     The watchdog never POSTs, never PATCHes, never mutates Plane state.
#   - Notification is delivered via osascript (Notification Center) and an
#     append-only log file. There is no recursive dependency: the watchdog
#     does not itself become a heartbeat the engine consumes.
#
# Sleep-mode limitation (out of scope per OE-8):
#   If the Mac is asleep, neither the runners nor this watchdog tick. That
#   means a sleeping Mac produces no alert, which is the desired behavior.
#
# Exit codes:
#   0  all heartbeats healthy (or outside waking hours)
#   1  one or more stale heartbeats detected (per-agent notifications fired)
#   2  hard failure (network error, parse error, missing PAT, etc.) on
#      ANY agent — the run is aborted at the first hard failure

set -o pipefail

PAT_FILE=~/.config/openengine/plane-pat
LOG=~/Library/Logs/openengine-watchdog.log

BASE="https://<your-plane-host>"
WS="<your-workspace-slug>"
OE="<your-project-uuid>"
LEDGER="<your-status-ledger-issue-uuid>"

# Agents to watch — add new lines (agent_code:heartbeat_comment_id) here.
# Heartbeat comment ids are top-level comments on OPENENGINE-3 (the ledger).
AGENTS=(
  "matt-claude:<heartbeat-comment-uuid>"
  "matt-codex:<heartbeat-comment-uuid>"
)

JQ=/opt/homebrew/bin/jq
CURL=/usr/bin/curl
PANDOC=/opt/homebrew/bin/pandoc
OSASCRIPT=/usr/bin/osascript

THRESHOLD_SECONDS=1800     # 30 minutes
WAKE_HOUR_START=7          # 07:00 local
WAKE_HOUR_END=23           # 23:00 local (notifications fire through 22:59)

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

# --- waking-hours gate ---------------------------------------------------
LOCAL_HOUR=$(TZ="America/Los_Angeles" date +%H)
LOCAL_HOUR=$((10#$LOCAL_HOUR))    # strip leading zero
if [ "$LOCAL_HOUR" -lt "$WAKE_HOUR_START" ] || [ "$LOCAL_HOUR" -ge "$WAKE_HOUR_END" ]; then
  log "SLEEP local_hour=$LOCAL_HOUR (outside ${WAKE_HOUR_START}-${WAKE_HOUR_END} PT, skipping)"
  exit 0
fi

# --- PAT load ------------------------------------------------------------
if [ ! -r "$PAT_FILE" ]; then
  log "FAIL PAT cache not readable at $PAT_FILE"
  exit 2
fi
PAT=$(cat "$PAT_FILE")
if [ -z "$PAT" ]; then
  log "FAIL PAT cache empty"
  exit 2
fi

# --- per-agent check -----------------------------------------------------
NOW_EPOCH=$(date -u +%s)
STALE_COUNT=0

for entry in "${AGENTS[@]}"; do
  AGENT_CODE="${entry%%:*}"
  COMMENT_ID="${entry#*:}"

  RAW=$("$CURL" -sL -H "X-API-Key: $PAT" \
    "$BASE/api/v1/workspaces/$WS/projects/$OE/issues/$LEDGER/comments/$COMMENT_ID/" \
    --max-time 15)
  CURL_EXIT=$?
  if [ "$CURL_EXIT" != "0" ] || [ -z "$RAW" ]; then
    log "FAIL agent=$AGENT_CODE curl exit=$CURL_EXIT body_bytes=${#RAW}"
    exit 2
  fi

  PLAIN=$(printf '%s' "$RAW" | "$JQ" -r '.comment_html // ""' | "$PANDOC" -f html -t plain 2>/dev/null)
  if [ -z "$PLAIN" ]; then
    log "FAIL agent=$AGENT_CODE pandoc produced empty plaintext"
    exit 2
  fi

  HB_STR=$(printf '%s' "$PLAIN" | grep -oE 'Last heartbeat: [^\n]*' | head -1 | sed -E 's/Last heartbeat:[[:space:]]+//')
  if [ -z "$HB_STR" ]; then
    log "FAIL agent=$AGENT_CODE could not parse 'Last heartbeat:' from comment"
    exit 2
  fi

  HB_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$HB_STR" +%s 2>/dev/null)
  if [ -z "$HB_EPOCH" ]; then
    log "FAIL agent=$AGENT_CODE could not parse heartbeat timestamp '$HB_STR' as ISO8601"
    exit 2
  fi
  AGE=$((NOW_EPOCH - HB_EPOCH))

  if [ "$AGE" -gt "$THRESHOLD_SECONDS" ]; then
    AGE_MIN=$((AGE / 60))
    log "STALE agent=$AGENT_CODE age=${AGE}s (${AGE_MIN}m) last_heartbeat=$HB_STR threshold=${THRESHOLD_SECONDS}s"
    "$OSASCRIPT" -e "display notification \"${AGENT_CODE} heartbeat stale (${AGE_MIN} min)\" with title \"Open Engine watchdog\" sound name \"Frog\"" >/dev/null 2>&1
    STALE_COUNT=$((STALE_COUNT + 1))
  else
    log "OK agent=$AGENT_CODE age=${AGE}s last_heartbeat=$HB_STR"
  fi
done

[ "$STALE_COUNT" -gt 0 ] && exit 1
exit 0
