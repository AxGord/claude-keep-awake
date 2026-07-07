#!/bin/bash
# Regression test: a session file whose PID the OS has recycled to an unrelated
# process must NOT keep the Mac awake. A bare `kill -0` passes for the reused
# PID, so the scripts also verify the process identity (its comm) and reap the
# phantom. Here KEEP_AWAKE_PROC_NAME=bash makes this test's own bash sessions
# valid; a `sleep` process (comm=sleep) stands in for the recycled-PID phantom.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
FAIL=0

HOME="$(mktemp -d)"; export HOME
export KEEP_AWAKE_PROC_NAME=bash
ST="$HOME/.claude/keep-awake-state"
SESSIONS="$ST/sessions"
SELF="$SESSIONS/$$"
DUMMY=
PHANTOM=

emit() { echo "$2" | bash "$SCRIPTS/$1" >/dev/null 2>&1; }

# keep-awake.sh adopts a running real daemon into daemon.pid via pgrep. Replace
# it with a throwaway process so stop-awake.sh's kill path can't hit the user's
# real daemon during the test.
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

# A phantom session: a live non-bash process (comm=sleep) recorded as a session.
mkdir -p "$SESSIONS"
sleep 600 & PHANTOM=$!
disown "$PHANTOM" 2>/dev/null
echo "$PHANTOM" > "$SESSIONS/$PHANTOM"

# 1. Any hook runs keep-awake.sh -> reap_dead_sessions drops the phantom (its
#    PID is alive but no longer the expected process), keeps the real session.
neutralize_daemon
emit keep-awake.sh '{"hook_event_name":"UserPromptSubmit"}'
chk "reap: recycled-PID phantom removed" "$SESSIONS/$PHANTOM" absent
chk "reap: real (matching-name) session kept" "$SELF" exist

# 2. With only the phantom left, stop-awake sees no live session -> kills daemon.
rm -f "$SELF"
echo "$PHANTOM" > "$SESSIONS/$PHANTOM"
neutralize_daemon
emit stop-awake.sh '{"hook_event_name":"Stop"}'
chk "has_live_sessions: phantom-only -> phantom reaped" "$SESSIONS/$PHANTOM" absent
chk "has_live_sessions: phantom-only -> daemon released" "$ST/daemon.pid" absent

kill "$PHANTOM" 2>/dev/null
[ -n "${DUMMY:-}" ] && kill "$DUMMY" 2>/dev/null
rm -rf "$HOME"
exit $FAIL
