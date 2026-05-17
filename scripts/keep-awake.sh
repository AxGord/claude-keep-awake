#!/bin/bash
# Register this Claude Code session with the keep-awake daemon.
# First registration starts the daemon; subsequent calls just refresh.
# Falls back to plain caffeinate / systemd-inhibit / Windows API if swiftc unavailable.
set -u

# Key sessions by the Claude CLI process PID, not session_id: a single CLI
# process changes session_id (on /clear, /compact, resume) but its PID is
# stable for its whole lifetime. UUID keying leaked one file per session_id
# that Stop never reaped, holding the daemon awake indefinitely.
read -t 1 -r _ || true  # drain hook stdin
PARENT_PID="${PPID:-$$}"

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${HOME}/.claude/keep-awake-state"

# Kill-switch: if this file exists, do nothing (Mac may sleep normally).
[ -e "$STATE_DIR/disabled" ] && exit 0

SESSIONS_DIR="$STATE_DIR/sessions"
PAUSED_DIR="$STATE_DIR/paused"
DAEMON_PID_FILE="$STATE_DIR/daemon.pid"
LOCK_DIR="$STATE_DIR/.lock"

mkdir -p "$SESSIONS_DIR"

# ---------- lock: atomic via mkdir, force-clear if held >5s ----------
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

# ---------- helpers ----------
daemon_alive() {
  [ -f "$DAEMON_PID_FILE" ] || return 1
  local pid; pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

reap_dead_sessions() {
  for f in "$SESSIONS_DIR"/*; do
    [ -e "$f" ] || continue
    local pid; pid=$(cat "$f" 2>/dev/null) || true
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
      rm -f "$PAUSED_DIR/${pid:-$(basename "$f")}"
    fi
  done
}

start_daemon() {
  # Adopt an already-running daemon (e.g. from another plugin copy or after a
  # wiped state dir). Avoids duplicate daemons claiming the same assertions.
  if [ "$(uname -s)" = "Darwin" ]; then
    local existing; existing=$(pgrep -x keep-awake-daemon 2>/dev/null | head -1)
    if [ -n "$existing" ]; then
      echo "$existing" > "$DAEMON_PID_FILE"
      return 0
    fi
  fi
  case "$(uname -s)" in
    Darwin)
      local bin="$PLUGIN_DIR/bin/keep-awake-daemon"
      local src="$PLUGIN_DIR/src/keep-awake-daemon.swift"
      if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
        if command -v swiftc >/dev/null 2>&1; then
          mkdir -p "$PLUGIN_DIR/bin"
          swiftc -O "$src" -o "$bin" 2>/dev/null || bin=""
        else
          bin=""
        fi
      fi
      if [ -n "$bin" ] && [ -x "$bin" ]; then
        nohup "$bin" </dev/null >/dev/null 2>&1 &
        echo $! > "$DAEMON_PID_FILE"
        disown $! 2>/dev/null || true
      else
        # Fallback: plain caffeinate (no clamshell override, no sound).
        nohup caffeinate -dis </dev/null >/dev/null 2>&1 &
        echo $! > "$DAEMON_PID_FILE"
        disown $! 2>/dev/null || true
      fi
      ;;
    Linux)
      if command -v systemd-inhibit >/dev/null 2>&1; then
        nohup systemd-inhibit --what=sleep:idle --who=claude-keep-awake --why=working sleep 86400 </dev/null >/dev/null 2>&1 &
      elif command -v gnome-session-inhibit >/dev/null 2>&1; then
        nohup gnome-session-inhibit --inhibit suspend --reason "Claude Code working" sleep 86400 </dev/null >/dev/null 2>&1 &
      else
        return 0
      fi
      echo $! > "$DAEMON_PID_FILE"
      disown $! 2>/dev/null || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      nohup powershell.exe -NoProfile -WindowStyle Hidden -Command "
        Add-Type -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint esFlags);' -Name W -Namespace K;
        [K.W]::SetThreadExecutionState([uint32](0x80000000 -bor 0x00000001 -bor 0x00000002));
        Start-Sleep -Seconds 86400
      " </dev/null >/dev/null 2>&1 &
      echo $! > "$DAEMON_PID_FILE"
      disown $! 2>/dev/null || true
      ;;
  esac
}

# ---------- main ----------
acquire_lock
echo "$PARENT_PID" > "$SESSIONS_DIR/$PARENT_PID"
rm -f "$PAUSED_DIR/$PARENT_PID"  # resume: a hook fired → Claude is working again
reap_dead_sessions
daemon_alive || start_daemon
