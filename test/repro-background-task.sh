#!/bin/bash
# Regression test: a tool launched with run_in_background outlives the turn.
# Claude ends the turn (Stop fires) while the task still runs. The session must
# stay registered across that Stop so the Mac is kept awake, and be released on
# the Stop that follows the task's completion.
#
# Liveness model: PostToolUse fires at launch and its tool_response names the
# task's output file; Claude holds that file open for the task's whole lifetime.
# keep-awake.sh records the path; stop-awake.sh probes it with lsof. A held file
# means the task runs (keep the session); a freed file means it finished (drop
# the marker, release). This survives a user who walks away without re-prompting
# — the old marker, cleared only on UserPromptSubmit, leaked until the watchdog.
# Here a held-open file stands in for Claude's still-running background task.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAIL=0

HOME="$(mktemp -d)"; export HOME
# Sessions here are keyed by this test's bash PID, not a `claude` process, so the
# PID-identity guard would otherwise reap them. Tell the scripts to expect bash.
export KEEP_AWAKE_PROC_NAME=bash
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

# A held-open file stands in for Claude's running background task output.
TASKOUT="$HOME/tasks/bdeadbeef.output"
mkdir -p "$HOME/tasks"
sleep 600 > "$TASKOUT" 2>&1 &   # holds TASKOUT open like a still-running task
HOLDER=$!
wait_lsof() {  # poll until lsof's view of TASKOUT matches <held|free>
  local want="$1" i
  for i in $(seq 1 20); do
    if lsof "$TASKOUT" >/dev/null 2>&1; then [ "$want" = held ] && return 0
    else [ "$want" = free ] && return 0; fi
    sleep 0.1
  done
}
wait_lsof held

# 1. Launch the background task: PostToolUse carries the output path, record it.
emit keep-awake.sh "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 600\",\"run_in_background\":true},\"tool_response\":{\"stdout\":\"Command running in background with ID: bdeadbeef. Output is being written to: $TASKOUT.\"}}"
chk "PostToolUse run_in_background -> bg marker set" "$BG" exist
chk "PostToolUse run_in_background -> session registered" "$SESS" exist

# 2. Stop fires while the task still runs (file held): session + marker kept.
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop with task running -> session kept" "$SESS" exist
chk "Stop with task running -> bg marker kept" "$BG" exist

# 3. Task finishes (output file freed): the next Stop drops marker + session.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; wait_lsof free
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop after task done -> bg marker cleared" "$BG" absent
chk "Stop after task done -> session released" "$SESS" absent

# 4. Control: a normal foreground tool must NOT set the bg marker.
emit keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
chk "PostToolUse normal tool -> no bg marker" "$BG" absent

# 5. Control: PreToolUse no longer owns the marker (the path is PostToolUse-only).
rm -f "$BG"
emit keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sleep 30","run_in_background":true}}'
chk "PreToolUse run_in_background -> no bg marker (PostToolUse owns it)" "$BG" absent

kill "$HOLDER" 2>/dev/null
[ -n "${DUMMY:-}" ] && kill "$DUMMY" 2>/dev/null
rm -rf "$HOME"
exit $FAIL
