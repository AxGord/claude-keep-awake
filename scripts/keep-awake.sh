#!/bin/bash
read -t 1 -r INPUT
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
PID_FILE="/tmp/claude-caffeinate-${SESSION_ID:-default}.pid"

if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
fi

caffeinate -dis -t 1800 </dev/null >/dev/null 2>&1 &
echo $! > "$PID_FILE"
disown $! 2>/dev/null
