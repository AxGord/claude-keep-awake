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

has_live_sessions() {
  for f in "$SESSIONS_DIR"/*; do
    [ -e "$f" ] || continue
    local pid; pid=$(cat "$f" 2>/dev/null) || continue
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && return 0
    rm -f "$f"
  done
  return 1
}

acquire_lock
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
