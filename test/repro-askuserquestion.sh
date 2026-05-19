#!/bin/bash
# Regression test: the Mac must be allowed to sleep while AskUserQuestion
# blocks waiting for the user, and must resume once the user answers.
set -u
SCRIPTS="/Users/axg/dev/claude/keep-awake/scripts"
FAIL=0

run() {  # <hook-script> <event-json> -> runs it in a fresh isolated HOME
  HOME="$(mktemp -d)"; export HOME
  PAUSED="$HOME/.claude/keep-awake-state/paused/$$"
  echo "$2" | bash "$SCRIPTS/$1" >/dev/null 2>&1
}
run_nonl() {  # same, but feed stdin WITHOUT a trailing newline
  HOME="$(mktemp -d)"; export HOME
  PAUSED="$HOME/.claude/keep-awake-state/paused/$$"
  printf '%s' "$2" | bash "$SCRIPTS/$1" >/dev/null 2>&1
}
assert() {  # <desc> <paused|awake>
  if [ "$2" = paused ]; then
    [ -e "$PAUSED" ] && echo "  PASS: $1" || { echo "  FAIL: $1 (expected paused)"; FAIL=1; }
  else
    [ -e "$PAUSED" ] && { echo "  FAIL: $1 (expected awake)"; FAIL=1; } || echo "  PASS: $1"
  fi
  rm -rf "$HOME"
}

run pause-awake.sh '{"hook_event_name":"Notification"}'
assert "Notification (plan/permission) -> sleep" paused

run keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
assert "PreToolUse AskUserQuestion -> sleep" paused

run keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
assert "PostToolUse AskUserQuestion (answered) -> resume" awake

run keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert "PreToolUse normal tool -> resume" awake

run_nonl keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}'
assert "PreToolUse AskUserQuestion, no trailing newline -> sleep" paused

exit $FAIL
