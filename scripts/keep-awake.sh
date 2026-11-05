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
HOOK_INPUT=""  # stays set under `set -u` even if the read times out
IFS= read -r -t 1 -d '' HOOK_INPUT || true
. "$(dirname "$0")/session-pid.sh"  # sets PARENT_PID, session_pid_live

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
BGOUT_DIR="$STATE_DIR/bgout"
TRANSCRIPTS_DIR="$STATE_DIR/transcripts"
LIMIT_DIR="$STATE_DIR/limit"
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
    if ! session_pid_live "$pid"; then
      rm -f "$f"
      rm -f "$PAUSED_DIR/${pid:-$(basename "$f")}"
      rm -f "$BG_DIR/${pid:-$(basename "$f")}"
      rm -f "$BGOUT_DIR/${pid:-$(basename "$f")}"
      rm -f "$TRANSCRIPTS_DIR/${pid:-$(basename "$f")}"
      rm -f "$LIMIT_DIR/${pid:-$(basename "$f")}"
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
  # Watchdog for the Linux/Windows sleep-inhibitor. Runs alongside the inhibitor
  # and ends it on either of the conditions the macOS daemon also self-exits on:
  #   1. no registered CLI PID is alive, or
  #   2. no hook has touched a session file for KEEP_AWAKE_HOOK_IDLE_LIMIT
  #      seconds (keep-awake.sh rewrites $SESSIONS_DIR/<pid> on every hook, so an
  #      active session refreshes it; this also catches a hung CLI and PID reuse).
  # The Stop hook is the clean teardown; the watchdog covers a CLI that exits
  # without firing it (crash, kill -9, terminal/SSH close).
  #
  # KEEP_AWAKE_HOOK_IDLE_LIMIT is the single knob, shared with the macOS daemon
  # (which reads the same env var). Default 7200s / 2h; export it so the watchdog
  # subshell and the Swift daemon both inherit it.
  export SESSIONS_DIR SESSION_PROC_NAME
  export -f session_pid_live
  # Non-integer or 0 → default: a bad value must neither disable the idle rule
  # (bash `-ge` errors out) nor release at once.
  case "${KEEP_AWAKE_HOOK_IDLE_LIMIT:-}" in
    ''|*[!0-9]*) KEEP_AWAKE_HOOK_IDLE_LIMIT=7200 ;;
  esac
  [ "$KEEP_AWAKE_HOOK_IDLE_LIMIT" -gt 0 ] || KEEP_AWAKE_HOOK_IDLE_LIMIT=7200
  export KEEP_AWAKE_HOOK_IDLE_LIMIT
  watchdog='
    while :; do
      sleep 60
      # Windows: the holder is a sibling; once Stop killed it, this loop is moot.
      [ -n "${KEEP_AWAKE_HOLDER_PID:-}" ] && ! kill -0 "$KEEP_AWAKE_HOLDER_PID" 2>/dev/null && exit 0
      alive=0 newest=0
      for f in "$SESSIONS_DIR"/*; do
        [ -e "$f" ] || continue
        pid=$(cat "$f" 2>/dev/null) || continue
        session_pid_live "$pid" && alive=1
        m=$(stat -c %Y "$f" 2>/dev/null) || m=0
        [ "$m" -gt "$newest" ] && newest="$m"
      done
      [ "$alive" = 0 ] && break
      [ "$newest" -gt 0 ] && [ $(( $(date +%s) - newest )) -ge "${KEEP_AWAKE_HOOK_IDLE_LIMIT:-7200}" ] && break
    done'

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
      # The inhibitor wraps the watchdog: when the loop returns, bash exits and
      # the inhibit is released. stop-awake.sh (kill / pkill -P the recorded PID)
      # is the fast path on a clean Stop.
      if command -v systemd-inhibit >/dev/null 2>&1; then
        nohup systemd-inhibit --what=sleep:idle --who=claude-keep-awake --why=working bash -c "$watchdog" </dev/null >/dev/null 2>&1 &
      elif command -v gnome-session-inhibit >/dev/null 2>&1; then
        nohup gnome-session-inhibit --inhibit suspend --reason "Claude Code working" bash -c "$watchdog" </dev/null >/dev/null 2>&1 &
      else
        return 0
      fi
      echo $! > "$DAEMON_PID_FILE"
      disown $! 2>/dev/null || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # SetThreadExecutionState is per-thread and cleared on process exit, so the
      # PowerShell holder must stay alive to keep the assertion. A sibling bash
      # watchdog (same session_pid_live check, which uses `ps -W` here) kills it
      # when no session is alive or all went idle, and exits on its own once
      # stop-awake.sh killed the holder. Start-Sleep is only a hard ceiling; an
      # active session past it gets a fresh holder on its next hook.
      # 2147483651 = 0x80000003 = ES_CONTINUOUS|ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED,
      # written in decimal: PowerShell reads 0x80000000 as a negative Int32, so the
      # old `[uint32](0x80000000 -bor …)` threw and the call never happened.
      nohup powershell.exe -NoProfile -WindowStyle Hidden -Command "
        Add-Type -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint esFlags);' -Name W -Namespace K;
        [K.W]::SetThreadExecutionState([uint32]2147483651);
        Start-Sleep -Seconds 7200
      " </dev/null >/dev/null 2>&1 &
      dpid=$!
      echo "$dpid" > "$DAEMON_PID_FILE"
      disown "$dpid" 2>/dev/null || true
      KEEP_AWAKE_HOLDER_PID="$dpid" nohup bash -c "$watchdog"'; kill '"$dpid"' 2>/dev/null' </dev/null >/dev/null 2>&1 &
      disown $! 2>/dev/null || true
      ;;
  esac
}

# ---------- main ----------
acquire_lock
echo "$PARENT_PID" > "$SESSIONS_DIR/$PARENT_PID"
rm -f "$PAUSED_DIR/$PARENT_PID"  # resume: a hook fired → Claude is working again
# A hook firing also settles a pending usage-limit hold: the session is running
# again, so the daemon must stop holding for the reset (this is how it learns the
# CLI's own auto-continue fired, or that the user prompted before the reset).
rm -f "$LIMIT_DIR/$PARENT_PID"

# Record the transcript path so the daemon can spot an interrupted turn: Esc
# fires no Stop/Notification, but Claude Code appends "[Request interrupted by
# user]" to the transcript. The daemon releases the Mac when that is the last
# message. Refreshed every hook (transcript path changes on /clear, /compact).
# First match only: the top-level transcript_path precedes any nested one a
# tool_response might contain (greedy sed would pick the wrong, last one).
tpath=$(printf '%s' "$HOOK_INPUT" | grep -oE '"transcript_path":"[^"]+"' | head -1 | sed -E 's/.*:"([^"]+)"/\1/')
if [ -n "$tpath" ]; then
  mkdir -p "$TRANSCRIPTS_DIR"
  printf '%s\n' "$tpath" > "$TRANSCRIPTS_DIR/$PARENT_PID"
fi

# Background shell tasks. stop-awake.sh decides which background work holds the
# Mac from the Stop payload's background_tasks, where a Monitor (a watcher) is
# listed as a shell task like any build — so record Monitor ids at launch as
# `monitor:<id>` to keep them from ever holding. PostToolUse's tool_response is
# the tool's data: Monitor → {"taskId":…}; background Bash →
# {…,"backgroundTaskId":…} with no output path (stop-awake.sh finds
# <id>.output under Claude's tmp dir). Older CLIs put "…written to: <path>" in
# tool_response — record that path so their fallback can probe it with lsof.
if [[ $HOOK_INPUT == *'"hook_event_name":"PostToolUse"'* ]]; then
  if [[ $HOOK_INPUT == *'"tool_name":"Monitor"'* ]]; then
    mon_id=$(printf '%s' "$HOOK_INPUT" | sed -nE 's/.*"taskId":"([^"]+)".*/\1/p' | head -1)
    if [ -n "$mon_id" ]; then
      mkdir -p "$BGOUT_DIR"
      printf 'monitor:%s\n' "$mon_id" >> "$BGOUT_DIR/$PARENT_PID"
    fi
  elif [[ $HOOK_INPUT == *'"run_in_background":true'* ]]; then
    # Anchor on Claude's literal "written to: <path>" so a /tasks/*.output path
    # appearing in the command text itself can't be mistaken for the task's file.
    task_out=$(printf '%s' "$HOOK_INPUT" | sed -nE 's/.*written to: (\/[^"[:space:]]+\.output).*/\1/p' | head -1)
    if [ -n "$task_out" ]; then
      mkdir -p "$BGOUT_DIR"
      printf '%s\n' "$task_out" >> "$BGOUT_DIR/$PARENT_PID"
    fi
  fi
fi

reap_dead_sessions
daemon_alive || start_daemon
