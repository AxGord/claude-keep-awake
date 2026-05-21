#!/bin/bash
# Regression test: the Mac must be allowed to sleep while AskUserQuestion
# blocks waiting for the user, and must resume once the user answers.
#
# Dispatch lives in hooks.json (PreToolUse matcher "AskUserQuestion"
# declared after the catch-all keep-awake.sh). This test verifies (a)
# the matcher is present and (b) the underlying scripts behave correctly
# when invoked in the order hooks.json runs them.
set -u
ROOT="/Users/axg/dev/claude/keep-awake"
SCRIPTS="$ROOT/scripts"
FAIL=0

# (a) hooks.json wires PreToolUse "AskUserQuestion" → pause-awake.sh,
#     declared after the catch-all keep-awake.sh.
HOOKS="$ROOT/hooks/hooks.json"
python3 - "$HOOKS" <<'PY' && echo "  PASS: hooks.json wires AskUserQuestion → pause-awake.sh (after keep-awake)" \
  || { echo "  FAIL: hooks.json AskUserQuestion dispatch missing or wrong order"; FAIL=1; }
import json, sys
entries = json.load(open(sys.argv[1]))["hooks"]["PreToolUse"]
def cmd(e): return e["hooks"][0]["command"]
ok = (
    len(entries) >= 2
    and "matcher" not in entries[0] and "keep-awake.sh" in cmd(entries[0])
    and entries[1].get("matcher") == "AskUserQuestion" and "pause-awake.sh" in cmd(entries[1])
)
sys.exit(0 if ok else 1)
PY

# (b) underlying scripts behave correctly.
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

# Simulate hooks.json ordering: catch-all keep-awake.sh runs first, then
# pause-awake.sh (matched on AskUserQuestion). Marker must end up set.
HOME="$(mktemp -d)"; export HOME
PAUSED="$HOME/.claude/keep-awake-state/paused/$$"
echo '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' | bash "$SCRIPTS/keep-awake.sh" >/dev/null 2>&1
echo '{"hook_event_name":"PreToolUse","tool_name":"AskUserQuestion"}' | bash "$SCRIPTS/pause-awake.sh" >/dev/null 2>&1
assert "PreToolUse AskUserQuestion (keep-awake then pause-awake) -> sleep" paused

run keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"AskUserQuestion"}'
assert "PostToolUse AskUserQuestion (answered) -> resume" awake

run keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
assert "PreToolUse normal tool -> resume" awake

exit $FAIL
