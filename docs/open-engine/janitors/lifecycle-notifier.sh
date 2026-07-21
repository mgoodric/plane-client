#!/usr/bin/env bash
# lifecycle-notifier.sh — emit Open Engine lifecycle notifications that the
# runner cannot: created / done / cancelled / moved-to-<state>.
#
# Why this exists
#   The runner only announces the three transitions it drives during a fire:
#   started (claim), resumed, and paused (needs input). Everything else —
#   an issue being *created* (by you via to-engine, or by an agent as a
#   follow-up), *closed* (Agent Done / Cancelled), or *moved* between states
#   (by you in the Plane UI, an agent, or the runner) — happens outside a fire
#   and was previously invisible in #agent-work.
#
#   This is a standalone poller (sibling to human-queue-digest.sh). Each run it
#   lists every OPENENGINE issue, diffs against the last snapshot, and POSTs one
#   notification per change to the notification-hub.
#
# Behavior
#   - FIRST RUN establishes a baseline snapshot and emits NOTHING (no backfill
#     flood of "created" for every pre-existing issue).
#   - Skips → Agent Working and → Agent Needs Input so it never double-notifies
#     the runner's own started/resumed/paused pings.
#   - Files nothing in Plane. Read-only GET + fire-and-forget POSTs to the hub.
#     Safe to run on a short interval.
#
# Snapshot: $LIFECYCLE_SNAPSHOT (default ~/.config/openengine/lifecycle-snapshot.json)
#   JSON object keyed by issue UUID: { "<uuid>": {seq, state, name} }.
#
# Usage:
#   bin/lifecycle-notifier.sh              # diff vs snapshot, POST changes, save snapshot
#   bin/lifecycle-notifier.sh --dry-run    # print changes; do NOT post, do NOT write snapshot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/constants.sh"

CURL=/usr/bin/curl
JQ=/opt/homebrew/bin/jq
PAT_FILE="$HOME/.config/openengine/plane-pat"
SNAP="${LIFECYCLE_SNAPSHOT:-$HOME/.config/openengine/lifecycle-snapshot.json}"
DRY_RUN=0; [ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -r "$PAT_FILE" ] || { echo "ERROR: PAT missing at $PAT_FILE (run bin/refresh-pat.sh)" >&2; exit 1; }
PAT=$(cat "$PAT_FILE")
API="$PLANE_BASE/api/v1/workspaces/$PLANE_WORKSPACE/projects/$PLANE_PROJECT/issues/"

# --- fetch all issues (cursor pagination; mirrors human-queue-digest.sh) --------
tmp=$(mktemp); : > "$tmp"
cursor=""; fetch_ok=1
for _ in $(seq 1 20); do   # 20-page safety cap
  url="$API?per_page=100"; [ -n "$cursor" ] && url="$url&cursor=$cursor"
  page=$("$CURL" -sS -H "X-API-Key: $PAT" "$url" --max-time 25) || { fetch_ok=0; break; }
  # A valid issues page has a .results array. Anything else (a 401/500 error
  # body — curl without --fail exits 0 on those) means an incomplete fetch.
  if ! echo "$page" | "$JQ" -e 'has("results") and (.results|type=="array")' >/dev/null 2>&1; then
    fetch_ok=0; break
  fi
  echo "$page" | "$JQ" -c '.results[]?' >> "$tmp" 2>/dev/null || true
  more=$(echo "$page" | "$JQ" -r '.next_page_results // false' 2>/dev/null || echo false)
  cursor=$(echo "$page" | "$JQ" -r '.next_cursor // ""' 2>/dev/null || echo "")
  [ "$more" = "true" ] && [ -n "$cursor" ] || break
done

# --- build current snapshot: { "<uuid>": {seq,state,name} } ----------------------
CUR=$("$JQ" -cs 'map({key: .id, value: {seq: .sequence_id, state: .state, name: (.name // "(untitled)")}}) | from_entries' "$tmp")
rm -f "$tmp"

# --- SAFETY: never act on an incomplete or empty fetch --------------------------
# Persisting a wiped/partial snapshot would make the next healthy run emit a
# "created" for every (re)appearing issue — a notification flood on a routine
# PAT rotation or Plane restart. If any page failed or the result is empty, skip
# the whole run: no baseline, no diff, no snapshot write. The snapshot is left
# exactly as it was so the next good fetch diffs against real prior state.
issue_count=$("$JQ" -r 'length' <<<"$CUR" 2>/dev/null || echo 0)
if [ "$fetch_ok" -ne 1 ] || [ "${issue_count:-0}" -eq 0 ]; then
  echo "fetch incomplete or empty (issues=$issue_count, fetch_ok=$fetch_ok) — skipping run; snapshot preserved."
  exit 0
fi

# --- first run: establish baseline, emit nothing --------------------------------
if [ ! -f "$SNAP" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY RUN: no snapshot at $SNAP — first real run would baseline $(echo "$CUR" | "$JQ" 'length') issues and emit nothing."
    exit 0
  fi
  mkdir -p "$(dirname "$SNAP")"
  printf '%s' "$CUR" > "$SNAP.tmp.$$" && mv -f "$SNAP.tmp.$$" "$SNAP"
  echo "baseline established: $(echo "$CUR" | "$JQ" 'length') issues snapshotted → $SNAP (no notifications emitted)"
  exit 0
fi
PREV=$(cat "$SNAP")

# --- friendly state names -------------------------------------------------------
STATE_NAMES=$("$JQ" -nc \
  --arg standing "$STATE_STANDING" --arg todo "$STATE_AGENT_TODO" \
  --arg working "$STATE_AGENT_WORKING" --arg needs "$STATE_AGENT_NEEDS_INPUT" \
  --arg review "$STATE_AGENT_REVIEW" --arg sdone "$STATE_AGENT_DONE" --arg cancelled "$STATE_CANCELLED" \
  '{($standing):"Standing",($todo):"Agent Todo",($working):"Agent Working",($needs):"Agent Needs Input",($review):"Agent Review",($sdone):"Agent Done",($cancelled):"Cancelled"}')

# --- diff: emit one event row per relevant change (TSV: evt seq id name state) ---
# evt ∈ created | done | cancelled | moved. Transitions to Agent Working /
# Agent Needs Input are suppressed (runner owns those pings).
events=$("$JQ" -n -r \
  --argjson prev "$PREV" --argjson cur "$CUR" --argjson names "$STATE_NAMES" \
  --arg DONE "$STATE_AGENT_DONE" --arg CANCELLED "$STATE_CANCELLED" \
  --arg WORKING "$STATE_AGENT_WORKING" --arg NEEDS "$STATE_AGENT_NEEDS_INPUT" '
  [ $cur | to_entries[]
    | .key as $id | .value as $c | ($prev[$id]) as $p
    | if $p == null then
        {evt:"created", seq:$c.seq, id:$id, name:$c.name, st:($names[$c.state] // "?")}
      elif ($p.state != $c.state) then
        ( if   $c.state == $DONE                              then {evt:"done"}
          elif $c.state == $CANCELLED                         then {evt:"cancelled"}
          elif ($c.state == $WORKING or $c.state == $NEEDS)   then {evt:"skip"}
          else                                                    {evt:"moved"} end )
        + {seq:$c.seq, id:$id, name:$c.name, st:($names[$c.state] // "?")}
      else {evt:"skip"} end ]
  | map(select(.evt != "skip"))
  | .[] | [.evt, (.seq|tostring), .id, .name, .st] | @tsv ')

# --- strip the routing prefix so titles read cleanly ----------------------------
strip_prefix() { printf '%s' "$1" | sed -E 's/^\[agent instructions\]\[(matt-claude|matt-codex)\]\[[^]]+\][[:space:]]*//'; }
plane_url()    { printf '%s/projects/projects/%s/issues/%s' "${PLANE_BASE#https://}" "$PLANE_PROJECT" "$1"; }

# --- post one notification to the hub -------------------------------------------
hub_post() {
  local severity="$1" title="$2" body="$3" dedupe_key="$4"
  [ -z "${NOTIFICATION_HUB_URL:-}" ] && { echo "  NOTIFICATION_HUB_URL empty — skip: $title"; return 0; }
  local payload
  payload=$("$JQ" -nc \
    --arg src "openengine-lifecycle-notifier" \
    --arg sev "$severity" --arg topic "openengine" \
    --arg title "$title" --arg body "$body" --arg dk "$dedupe_key" \
    '{source:$src, severity:$sev, topic:$topic, title:$title, body:$body, hints:{dedupe_key:$dk, dedupe_window_seconds:3600}}')
  local code
  code=$("$CURL" -sS -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" \
    --max-time 8 -d "$payload" "$NOTIFICATION_HUB_URL" || echo "000")
  echo "  posted [$severity] $title → hub HTTP $code"
}

# --- walk the events ------------------------------------------------------------
emitted=0
if [ -n "$events" ]; then
  while IFS=$'\t' read -r evt seq id name st; do
    [ -z "$evt" ] && continue
    clean=$(strip_prefix "$name")
    url=$(plane_url "$id")
    case "$evt" in
      created)   title="🆕 [OE-$seq created] $clean";      summary="A new Open Engine issue was created (currently in $st)." ; dk="oe-$seq-created" ;;
      done)      title="✅ [OE-$seq done] $clean";          summary="This issue was completed (moved to Agent Done)."          ; dk="oe-$seq-done" ;;
      cancelled) title="🚫 [OE-$seq cancelled] $clean";     summary="This issue was cancelled."                                ; dk="oe-$seq-cancelled" ;;
      moved)     title="↔️ [OE-$seq → $st] $clean";         summary="This issue moved to $st."                                 ; dk="oe-$seq-moved-$(printf '%s' "$st" | tr 'A-Z ' 'a-z-')" ;;
      *)         continue ;;
    esac
    body=$(printf '%s\n\nOpen in Plane: %s' "$summary" "$url")
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "── DRY RUN would post ──"; echo "  title: $title"; echo "  body:  $summary  ($url)"; echo "  dedupe: $dk"
    else
      hub_post "info" "$title" "$body" "$dk"
    fi
    emitted=$((emitted+1))
  done <<< "$events"
fi

# --- persist the new snapshot (real runs only) ----------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN complete: $emitted change(s) detected; snapshot NOT written."
else
  printf '%s' "$CUR" > "$SNAP.tmp.$$" && mv -f "$SNAP.tmp.$$" "$SNAP"
  echo "done: $emitted notification(s) emitted; snapshot updated → $SNAP"
fi
