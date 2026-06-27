#!/bin/bash
# Unregister this Claude Code session. If it was the last live session,
# terminate the daemon (which performs its own cleanup).
set -u

# Keyed by Claude CLI PID, matching keep-awake.sh (session_id is unstable).
read -t 1 -r _ || true  # drain hook stdin
PARENT_PID="${PPID:-$$}"

STATE_DIR="${HOME}/.claude/keep-awake-state"
SESSIONS_DIR="$STATE_DIR/sessions"
PAUSED_DIR="$STATE_DIR/paused"
BG_DIR="$STATE_DIR/bg"
DAEMON_PID_FILE="$STATE_DIR/daemon.pid"
LOCK_DIR="$STATE_DIR/.lock"

[ -d "$STATE_DIR" ] || exit 0

acquire_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i+1))
    [ $i -gt 50 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; i=0; }
    sleep 0.1
  done
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

# A session PID counts as live only if the process exists AND is still a
# `claude` process. A bare kill -0 also passes when the OS recycles a dead
# session's PID to an unrelated process (observed: AudioComponentRegistrar) —
# that phantom would otherwise keep the daemon awake forever. Process name is
# overridable (KEEP_AWAKE_PROC_NAME) for tests and non-native installs.
SESSION_PROC_NAME="${KEEP_AWAKE_PROC_NAME:-claude}"
session_pid_live() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
    */"$SESSION_PROC_NAME"|"$SESSION_PROC_NAME") return 0 ;;
    *) return 1 ;;
  esac
}

has_live_sessions() {
  for f in "$SESSIONS_DIR"/*; do
    [ -e "$f" ] || continue
    local pid; pid=$(cat "$f" 2>/dev/null) || continue
    session_pid_live "$pid" && return 0
    rm -f "$f"
  done
  return 1
}

acquire_lock

# A background task launched this (or a prior) turn outlives it. keep-awake.sh
# recorded each task's output file; Claude holds that file open for the task's
# whole lifetime, so lsof tells us which are still running. Keep the session
# registered while any is; prune finished ones so the marker drains to empty and
# the session unregisters on the Stop that follows the last task's completion —
# not on a user prompt that may never come.
BG_MARKER="$BG_DIR/$PARENT_PID"
if [ -e "$BG_MARKER" ]; then
  remaining=""
  while IFS= read -r task_out; do
    [ -n "$task_out" ] || continue
    lsof "$task_out" >/dev/null 2>&1 && remaining+="$task_out"$'\n'
  done < "$BG_MARKER"
  if [ -n "$remaining" ]; then
    printf '%s' "$remaining" > "$BG_MARKER"  # drop finished tasks, keep running ones
    exit 0  # task still running → keep session; trap releases the lock
  fi
  rm -f "$BG_MARKER"  # all tasks finished → fall through to unregister
fi

rm -f "$SESSIONS_DIR/$PARENT_PID"
rm -f "$PAUSED_DIR/$PARENT_PID"

if ! has_live_sessions; then
  if [ -f "$DAEMON_PID_FILE" ]; then
    PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null) || PID=""
    if [ -n "$PID" ]; then
      kill -TERM "$PID" 2>/dev/null || true
      pkill -P "$PID" 2>/dev/null || true  # Linux systemd-inhibit child sleep
    fi
    rm -f "$DAEMON_PID_FILE"
  fi
fi
