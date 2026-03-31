#!/bin/bash
read -t 1 -r INPUT
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
PID_FILE="/tmp/claude-caffeinate-${SESSION_ID:-default}.pid"
readonly TIMEOUT=1800

if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
fi

BG_PID=""
case "$(uname -s)" in
  Darwin)
    caffeinate -dis -t "$TIMEOUT" </dev/null >/dev/null 2>&1 &
    BG_PID=$!
    ;;
  Linux)
    if command -v systemd-inhibit >/dev/null 2>&1; then
      systemd-inhibit --what=sleep:idle --who=claude-keep-awake --why=working sleep "$TIMEOUT" </dev/null >/dev/null 2>&1 &
      BG_PID=$!
    elif command -v gnome-session-inhibit >/dev/null 2>&1; then
      gnome-session-inhibit --inhibit suspend --reason "Claude Code working" sleep "$TIMEOUT" </dev/null >/dev/null 2>&1 &
      BG_PID=$!
    fi
    ;;
  MINGW*|MSYS*|CYGWIN*)
    powershell.exe -NoProfile -WindowStyle Hidden -Command "
      Add-Type -MemberDefinition '[DllImport(\"kernel32.dll\")] public static extern uint SetThreadExecutionState(uint esFlags);' -Name W -Namespace K;
      [K.W]::SetThreadExecutionState([uint32](0x80000000 -bor 0x00000001 -bor 0x00000002));
      Start-Sleep -Seconds $TIMEOUT
    " </dev/null >/dev/null 2>&1 &
    BG_PID=$!
    ;;
esac

if [ -n "$BG_PID" ]; then
  echo "$BG_PID" > "$PID_FILE"
  disown "$BG_PID" 2>/dev/null
fi
