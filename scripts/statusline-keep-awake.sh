#!/bin/bash
# Output a warning when an AC-plug event is within macOS's "lid unsafe" window.
# Designed for Claude Code statusLine. Outputs nothing if no warning is active.
FILE="${HOME}/.claude/keep-awake-state/lid-unsafe-until"
[ -r "$FILE" ] || exit 0
UNTIL=$(cat "$FILE" 2>/dev/null) || exit 0
NOW=$(date +%s)
REMAINING=$((UNTIL - NOW))
[ "$REMAINING" -le 0 ] && exit 0
echo "⚠ Don't close lid: ${REMAINING}s"
