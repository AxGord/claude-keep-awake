#!/bin/bash
# Regression test: a tool launched with run_in_background outlives the turn.
# Claude ends the turn (Stop fires) while the task still runs, then is revived
# by its completion. The session must stay registered across that Stop so the
# Mac is kept awake, and must be released on the next real Stop.
#
# Empirically (see commit message): PreToolUse carries "run_in_background":true,
# Stop fires ~immediately after the turn ends, and completion revives Claude
# with UserPromptSubmit as the first hook — the marker's clear signal.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAIL=0

HOME="$(mktemp -d)"; export HOME
ST="$HOME/.claude/keep-awake-state"
BG="$ST/bg/$$"
SESS="$ST/sessions/$$"
DUMMY=

emit() { echo "$2" | bash "$SCRIPTS/$1" >/dev/null 2>&1; }

# keep-awake.sh adopts an already-running real daemon into daemon.pid via pgrep.
# Replace it with a throwaway process so stop-awake.sh's kill path can never
# terminate the user's real daemon during the test.
neutralize_daemon() {
  [ -n "${DUMMY:-}" ] && kill "$DUMMY" 2>/dev/null
  mkdir -p "$ST"
  sleep 600 & DUMMY=$!
  disown "$DUMMY" 2>/dev/null  # suppress job-control "Terminated" noise on kill
  echo "$DUMMY" > "$ST/daemon.pid"
}

chk() {  # <desc> <path> <exist|absent>
  if [ "$3" = exist ]; then
    [ -e "$2" ] && echo "  PASS: $1" || { echo "  FAIL: $1 (expected present)"; FAIL=1; }
  else
    [ -e "$2" ] && { echo "  FAIL: $1 (expected absent)"; FAIL=1; } || echo "  PASS: $1"
  fi
}

# 1. Launch a background task: mark bg, register session.
emit keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sleep 30","run_in_background":true}}'
chk "PreToolUse run_in_background -> bg marker set" "$BG" exist
chk "PreToolUse run_in_background -> session registered" "$SESS" exist

# 2. Stop fires while the task still runs: session must be kept.
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop with bg pending -> session kept" "$SESS" exist

# 3. Task completes, reviving Claude: UserPromptSubmit clears the marker.
emit keep-awake.sh '{"hook_event_name":"UserPromptSubmit"}'
chk "UserPromptSubmit -> bg marker cleared" "$BG" absent
chk "UserPromptSubmit -> session still registered" "$SESS" exist

# 4. Real Stop, no bg pending: session released.
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop without bg -> session released" "$SESS" absent

# 5. Control: a normal foreground tool must NOT set the bg marker.
emit keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
chk "PreToolUse normal tool -> no bg marker" "$BG" absent

[ -n "${DUMMY:-}" ] && kill "$DUMMY" 2>/dev/null
rm -rf "$HOME"
exit $FAIL
