#!/bin/bash
# Pause this Claude Code session: it's blocked waiting for the user (permission
# prompt, AskUserQuestion, plan approval) — Claude isn't working, so this
# session should stop requesting wake. The daemon releases the Mac only if
# NO other session is still active, so a working session keeps it awake.
# Resumed by keep-awake.sh on the next UserPromptSubmit/PreToolUse/PostToolUse.
set -u

# Keyed by Claude CLI PID, matching keep-awake.sh (session_id is unstable).
read -t 1 -r _ || true  # drain hook stdin
PARENT_PID="${PPID:-$$}"

STATE_DIR="${HOME}/.claude/keep-awake-state"

# Kill-switch: if this file exists, do nothing (Mac may sleep normally anyway).
[ -e "$STATE_DIR/disabled" ] && exit 0

# No global lock: the marker is unique per PID (one CLI process, no concurrent
# writer for the same file); taking the shared lock from Notification would
# only contend with other sessions' keep-awake.sh calls.
PAUSED_DIR="$STATE_DIR/paused"
mkdir -p "$PAUSED_DIR"
: > "$PAUSED_DIR/$PARENT_PID"
