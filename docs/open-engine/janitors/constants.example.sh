#!/bin/bash
# Example Open Engine Plane constants. Copy to constants.sh and fill in your own
# instance's values. constants.sh is gitignored in the private engine repo and is
# never published. Every value below is a placeholder.
#
# The janitor scripts in this directory `source` constants.sh for the Plane host,
# project/label/state UUIDs, and issue references. They read the Plane API token
# from a file on disk (PAT_FILE, see each script), never from a literal here.

PLANE_BASE="https://<your-plane-host>"
PLANE_WORKSPACE="<your-workspace-slug>"
PLANE_PROJECT="<your-project-uuid>"

AGENT_LABEL="<agent-instructions-label-uuid>"
# Execution-mode labels for work that needs a human (skipped by the runner gate,
# surfaced by human-queue-digest.sh). IDs are workspace-specific.
HUMAN_ACTION_LABEL="<human-action-label-uuid>"     # needs a person's hands
PAIR_SESSION_LABEL="<pair-session-label-uuid>"     # do interactively, supervised
OPENENGINE_CORE_CONTEXT_ISSUE="<core-context-issue-uuid>"
OPENENGINE_STATUS_LEDGER_ISSUE="<status-ledger-issue-uuid>"
OPENENGINE_SKILL_DIRECTORY_ISSUE="<skill-directory-issue-uuid>"
MATT_CLAUDE_HEARTBEAT_COMMENT="<claude-heartbeat-comment-uuid>"
MATT_CODEX_HEARTBEAT_COMMENT="<codex-heartbeat-comment-uuid>"

STATE_STANDING="<state-uuid>"
STATE_AGENT_TODO="<state-uuid>"
STATE_AGENT_WORKING="<state-uuid>"
STATE_AGENT_NEEDS_INPUT="<state-uuid>"
STATE_AGENT_REVIEW="<state-uuid>"
STATE_AGENT_DONE="<state-uuid>"
STATE_CANCELLED="<state-uuid>"

OPENENGINE_USER_ID="<default-assignee-user-uuid>"

# Optional notification-hub endpoint. Runners POST lifecycle events here.
# Empty disables hub notifications cleanly.
NOTIFICATION_HUB_URL=""
