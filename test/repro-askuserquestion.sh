#!/bin/bash
# Regression test: the Mac must be allowed to sleep while AskUserQuestion
# blocks waiting for the user, and must resume once the user answers.
#
# Dispatch is inline in keep-awake.sh (it reads stdin, detects PreToolUse
# AskUserQuestion, execs pause-awake.sh). A previous hooks.json-matcher
# approach raced: pause-awake.sh's `: > marker` finished before
# keep-awake.sh's `rm -f marker`, leaving the Mac awake.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAIL=0

run() {  # <hook-script> <event-json> -> runs it in a fresh isolated HOME
  HOME="$(mktemp -d)"; export HOME
  PAUSED="$HOME/.claude/keep-awake-state/paused/$$"
  echo "$2" | bash "$SCRIPTS/$1" >/dev/null 2>&1
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

# A hypothetical "AskUserQuestionFoo" tool must not misfire: the substring
# match includes the closing quote of the JSON value, so prefix-match alone
# can't trigger pause.
run keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestionFoo"}'
assert "PreToolUse AskUserQuestionFoo (closing-quote guard) -> resume" awake

exit $FAIL
