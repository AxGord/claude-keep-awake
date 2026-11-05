#!/bin/bash
# session-pid.sh: hooks key sessions by CLAUDE_PID (the CLI exports it to hooks
# on macOS, Linux and Windows); without it, fall back to the hook's PPID.
set -u
unset CLAUDE_PID
LIB="$(cd "$(dirname "$0")/.." && pwd)/scripts/session-pid.sh"
fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got [$2], want [$3])"; fail=1; fi; }

got=$(CLAUDE_PID=4242 bash -c ". '$LIB'; echo \$PARENT_PID")
check "CLAUDE_PID set -> PARENT_PID=CLAUDE_PID" "$got" 4242

got=$(bash -c ". '$LIB'; echo \$PARENT_PID:\$PPID" | awk -F: '{print ($1==$2) ? "ppid" : $1"!="$2}')
check "CLAUDE_PID unset -> PARENT_PID=PPID" "$got" ppid

sleep 30 & S=$!
got=$(KEEP_AWAKE_PROC_NAME=sleep bash -c ". '$LIB'; session_pid_live $S && echo live || echo dead")
check "session_pid_live: live process of PROC_NAME" "$got" live
got=$(KEEP_AWAKE_PROC_NAME=claude bash -c ". '$LIB'; session_pid_live $S && echo live || echo dead")
check "session_pid_live: other process name -> dead" "$got" dead
kill $S 2>/dev/null; wait $S 2>/dev/null
got=$(KEEP_AWAKE_PROC_NAME=sleep bash -c ". '$LIB'; session_pid_live $S && echo live || echo dead")
check "session_pid_live: exited process -> dead" "$got" dead

[ $fail = 0 ] && echo "RESULT: PASS" || { echo "RESULT: FAIL"; exit 1; }
