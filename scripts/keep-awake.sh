#!/bin/bash
# Register this Claude Code session with the keep-awake daemon.
# First registration starts the daemon; subsequent calls just refresh.
# Falls back to plain caffeinate / systemd-inhibit / Windows API if swiftc unavailable.
set -u

# Key sessions by the Claude CLI process PID, not session_id: a single CLI
# process changes session_id (on /clear, /compact, resume) but its PID is
# stable for its whole lifetime. UUID keying leaked one file per session_id
# that Stop never reaped, holding the daemon awake indefinitely.
# Single read captures full JSON (NUL delimiter → reads to EOF). 1s cap.
IFS= read -r -t 1 -d '' HOOK_INPUT || true
PARENT_PID="${PPID:-$$}"

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${HOME}/.claude/keep-awake-state"

# Kill-switch: if this file exists, do nothing (Mac may sleep normally).
[ -e "$STATE_DIR/disabled" ] && exit 0

# AskUserQuestion blocks waiting for the user with no Notification event (unlike
# permission prompts / plan approval). Dispatch inline: a parallel matcher hook
# raced with our marker-clear below (this script runs the lock/daemon path and
# finishes ~30ms after pause-awake.sh's instant `: > marker`, so the clear won).
# Closing-quote in the substring rules out "AskUserQuestionFoo"; requiring both
# event and tool name rules out unrelated Bash args containing the literal.
if [[ $HOOK_INPUT == *'"hook_event_name":"PreToolUse"'* \
   && $HOOK_INPUT == *'"tool_name":"AskUserQuestion"'* ]]; then
  exec bash "$PLUGIN_DIR/scripts/pause-awake.sh"
fi

SESSIONS_DIR="$STATE_DIR/sessions"
PAUSED_DIR="$STATE_DIR/paused"
BG_DIR="$STATE_DIR/bg"
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

reap_dead_sessions() {
  for f in "$SESSIONS_DIR"/*; do
    [ -e "$f" ] || continue
    local pid; pid=$(cat "$f" 2>/dev/null) || true
    if ! session_pid_live "$pid"; then
      rm -f "$f"
      rm -f "$PAUSED_DIR/${pid:-$(basename "$f")}"
      rm -f "$BG_DIR/${pid:-$(basename "$f")}"
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

# Background-task tracking. A tool launched with run_in_background outlives the
# turn: Claude ends the turn (Stop fires) while the task still runs, then is
# revived by its completion. Without this, stop-awake.sh would unregister the
# session — releasing the Mac mid-task. The revival fires no reliable hook (task
# completion is injected as a notification, not a UserPromptSubmit), so a marker
# cleared only on the next prompt leaked: a user who walked away after launching
# a task pinned the Mac awake until the 2h watchdog. Instead, tie the marker to
# the task itself. PostToolUse fires at launch and its tool_response carries the
# task's output file; Claude holds that file open for the task's whole lifetime,
# so stop-awake.sh can probe liveness with lsof. Record one output path per line.
if [[ $HOOK_INPUT == *'"hook_event_name":"PostToolUse"'* \
   && $HOOK_INPUT == *'"run_in_background":true'* ]]; then
  # Anchor on Claude's literal "written to: <path>" so a /tasks/*.output path
  # appearing in the command text itself can't be mistaken for the task's file.
  task_out=$(printf '%s' "$HOOK_INPUT" | sed -nE 's/.*written to: (\/[^"[:space:]]+\.output).*/\1/p' | head -1)
  if [ -n "$task_out" ]; then
    mkdir -p "$BG_DIR"
    printf '%s\n' "$task_out" >> "$BG_DIR/$PARENT_PID"
  fi
fi

reap_dead_sessions
daemon_alive || start_daemon
