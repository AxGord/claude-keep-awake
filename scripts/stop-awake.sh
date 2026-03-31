#!/bin/bash
read -t 1 -r INPUT
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
PID_FILE="/tmp/claude-caffeinate-${SESSION_ID:-default}.pid"

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  kill "$PID" 2>/dev/null
  # On Linux with systemd-inhibit, also kill child sleep process
  pkill -P "$PID" 2>/dev/null
  rm -f "$PID_FILE"
fi
