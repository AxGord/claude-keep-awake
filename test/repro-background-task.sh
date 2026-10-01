#!/bin/bash
# Regression test: background work launched in a turn outlives it. Claude ends
# the turn (Stop fires) while the work still runs, then is revived by its
# completion; that revival turn ends with another Stop. The session must stay
# registered across Stops while finite background work runs, and be released
# once it is done — but never held for work that may run forever.
#
# stop-awake.sh reads the Stop payload's background_tasks (the CLI's list of
# in-flight work): subagents/workflows hold (no age cap); monitors, other task
# types and server-like shell commands don't; a shell task holds at most 1 h
# since first seen. Shell tasks carry the output path keep-awake.sh recorded at
# PostToolUse and subagents their transcript, so the daemon can later drop a
# finished task, a listening server or a finished/silent subagent. A CLI without background_tasks
# falls back to lsof on the recorded output files; a held-open file stands in
# for a still-running task there.
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

stop_with() {  # <background_tasks JSON array>
  neutralize_daemon
  emit stop-awake.sh "{\"session_id\":\"s1\",\"transcript_path\":\"$HOME/proj/s1.jsonl\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"last_assistant_message\":\"ok\",\"background_tasks\":$1,\"session_crons\":[{\"id\":\"c1\",\"schedule\":\"* * * * *\",\"recurring\":true,\"prompt\":\"x\"}]}"
}
register() { emit keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'; }
has_line() {  # <desc> <fixed-string>
  grep -qF -- "$2" "$BG" 2>/dev/null && echo "  PASS: $1" || { echo "  FAIL: $1"; FAIL=1; }
}
BGOUT="$ST/bgout/$$"
# Description carries an escaped `{"id":` and `"command":"` — must not split the entry.
SUB='{"id":"a1b2c3","type":"subagent","status":"running","description":"Review {\"id\":\"zz\",\"type\":\"shell\"} \"command\":\"npm run dev\" \\","agent_type":"general-purpose"}'
WF='{"id":"w1","type":"workflow","status":"running","description":"review","name":"review-changes"}'
TM='{"id":"tm1","type":"teammate","status":"running","description":"helper"}'
MCP='{"id":"t1","type":"MCP task","status":"running","description":"remote job","server":"s","tool":"t"}'
MON='{"id":"m1","type":"monitor","status":"running","description":"watch deploy","server":"s","tool":"t"}'
DEV='{"id":"b1","type":"shell","status":"running","description":"dev server","command":"bash -c '"'"'npm run dev'"'"'"}'
BUILD='{"id":"bdeadbeef","type":"shell","status":"running","description":"build","command":"git checkout dev && make all 2>/dev/null; echo \"done\""}'
MONSH='{"id":"bmon1","type":"shell","status":"running","description":"poll CI","command":"until gh run view 1 | grep -q done; do sleep 30; done"}'

# 1. Async subagent running at Stop -> held, transcript path derived from transcript_path.
register
stop_with "[$SUB]"
chk "subagent running -> session kept" "$SESS" exist
has_line "subagent recorded with its transcript" $'\tsubagent\ta1b2c3\t'"$HOME/proj/s1/subagents/agent-a1b2c3.jsonl"
has_line "escaped {\"id\": in description not parsed as a task" $'\tsubagent\ta1b2c3'
grep -q $'\tzz\t' "$BG" 2>/dev/null && { echo "  FAIL: phantom task from description"; FAIL=1; } || echo "  PASS: no phantom task from description"

# 2. first_seen survives later Stops; subagents have no age cap.
now=$(date +%s); old=$((now - 7200))
printf '%s\tsubagent\ta1b2c3\t\n' "$old" > "$BG"
stop_with "[$SUB,$WF,$TM]"
chk "subagent running 2h -> still kept (no cap for agents)" "$SESS" exist
has_line "first_seen preserved across Stops" "$old"$'\tsubagent\ta1b2c3'
has_line "workflow held" $'\tworkflow\tw1\t'
has_line "teammate held" $'\tteammate\ttm1\t'
first_new=$(awk -F'\t' '$3 == "w1" { print $1 }' "$BG")
[ $((first_new >= now)) -eq 1 ] && echo "  PASS: new id gets first_seen=now" || { echo "  FAIL: new id first_seen=$first_new"; FAIL=1; }

# 3. Unknown / non-finite types are not held.
stop_with "[$MCP,$MON]"
chk "MCP task + monitor only -> session released" "$SESS" absent

# 4. Server-like shell command -> not held.
register
stop_with "[$DEV]"
chk "shell \"bash -c 'npm run dev'\" -> session released" "$SESS" absent

# 5. A Monitor runs as a shell task: recorded at launch, never held.
register
emit keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"Monitor","tool_input":{"command":"until x; do sleep 30; done","description":"poll CI"},"tool_response":{"taskId":"bmon1","timeoutMs":300000,"persistent":false}}'
stop_with "[$MONSH]"
chk "Monitor shell task -> session released" "$SESS" absent

# 6. Finite shell task (bare word 'dev' is not a server): held with its output
#    path. Current CLIs report no path at launch ({backgroundTaskId}), so
#    stop-awake.sh finds <id>.output under Claude's tmp dir.
register
TASKS_ROOT="$HOME/claude-tmp"; export KEEP_AWAKE_TASKS_ROOT="$TASKS_ROOT"
mkdir -p "$TASKS_ROOT/-proj/s1/tasks"; : > "$TASKS_ROOT/-proj/s1/tasks/bdeadbeef.output"
emit keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"make all","run_in_background":true},"tool_response":{"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bdeadbeef"}}'
stop_with "[$BUILD,$MON]"
chk "shell build running -> session kept" "$SESS" exist
has_line "shell entry carries output path found under tmp dir" $'\tshell\tbdeadbeef\t'"$TASKS_ROOT/-proj/s1/tasks/bdeadbeef.output"

# 7. Shell capped at 1h since first seen; the cap is sticky (no re-arm next Stop).
printf '%s\tshell\tbdeadbeef\t%s\n' "$((now - 3601))" "$TASKS_ROOT/-proj/s1/tasks/bdeadbeef.output" > "$BG"
stop_with "[$BUILD]"
chk "shell held >1h -> session released" "$SESS" absent
has_line "expired shell keeps original first_seen" "$((now - 3601))"$'\tshell\tbdeadbeef'
register
stop_with "[$BUILD]"
chk "expired shell next Stop -> still released (cap not re-armed)" "$SESS" absent

# 8. Work done (empty list) -> released, markers cleared.
register
stop_with "[]"
chk "no background work -> session released" "$SESS" absent
chk "no background work -> bg marker cleared" "$BG" absent
chk "no background work -> bgout cleared" "$BGOUT" absent

# 9. Hook stdin not closed within the read timeout -> no crash, session released.
register
neutralize_daemon
( sleep 2 ) | bash "$SCRIPTS/stop-awake.sh" >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && echo "  PASS: unclosed stdin -> rc 0" || { echo "  FAIL: unclosed stdin -> rc $rc"; FAIL=1; }
chk "unclosed stdin -> session released" "$SESS" absent

# ---------- fallback: CLI without background_tasks ----------
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

# 10. Launch the background task: PostToolUse carries the output path, record it.
emit keep-awake.sh "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"sleep 600\",\"run_in_background\":true},\"tool_response\":{\"stdout\":\"Command running in background with ID: bdeadbeef. Output is being written to: $TASKOUT.\"}}"
chk "PostToolUse run_in_background -> output path recorded (fallback)" "$BGOUT" exist
chk "PostToolUse run_in_background -> session registered" "$SESS" exist

# 11. Stop fires while the task still runs (file held): session + marker kept.
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop with task running -> session kept" "$SESS" exist
chk "Stop with task running -> bg marker kept" "$BG" exist

# 12. Task finishes (output file freed): the next Stop drops marker + session.
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; wait_lsof free
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "Stop after task done -> bg marker cleared" "$BG" absent
chk "Stop after task done -> bgout cleared" "$BGOUT" absent
chk "Stop after task done -> session released" "$SESS" absent

# 13. Control: a normal foreground tool must NOT set the bg marker.
emit keep-awake.sh '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
chk "PostToolUse normal tool -> no output path recorded" "$BGOUT" absent

# 14. Control: PreToolUse no longer owns the marker (the path is PostToolUse-only).
rm -f "$BGOUT"
emit keep-awake.sh '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"sleep 30","run_in_background":true}}'
chk "PreToolUse run_in_background -> no output path (PostToolUse owns it)" "$BGOUT" absent

kill "$HOLDER" 2>/dev/null
[ -n "${DUMMY:-}" ] && kill "$DUMMY" 2>/dev/null
rm -rf "$HOME"
exit $FAIL
