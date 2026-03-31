#!/bin/bash
read -t 1 -r INPUT
SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | cut -d'"' -f4)
PID_FILE="/tmp/claude-caffeinate-${SESSION_ID:-default}.pid"

if [ -f "$PID_FILE" ]; then
  kill "$(cat "$PID_FILE")" 2>/dev/null
  rm -f "$PID_FILE"
fi
