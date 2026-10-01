#!/bin/bash
# Regression test: the daemon holds the Mac for background work a session
# launched (bg/<pid>, written by stop-awake.sh) even while the session is paused
# — the 60s idle_prompt Notification fires regardless of running tasks — and
# lets go once that work is done, turns out to be a server, or passes its cap.
#  - subagent: live while its transcript's last message is not the final text
#  - shell: live while its output file has holders; a holder listening on TCP
#    for 30s is a server; capped at 1h since first seen
# Drives the real daemon binary against an isolated state dir.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN=$(mktemp)
swiftc -O "$ROOT/src/keep-awake-daemon.swift" -o "$BIN" || { echo "COMPILE FAIL"; exit 1; }

T=$(mktemp -d /tmp/kabg.XXXXXX)
export KEEP_AWAKE_STATE_DIR="$T" KEEP_AWAKE_PROC_NAME=sleep
mkdir -p "$T/sessions" "$T/paused" "$T/bg"
ERR="$T/daemon.err"
SUBTR="$T/agent-a1.jsonl"
DID="" SID="" TASK="" SRV=""
cleanup() { kill $DID $SID $TASK $SRV 2>/dev/null; rm -rf "$T" "$BIN"; }
trap cleanup EXIT INT TERM

sleep 600 & SID=$!; disown
echo "$SID" > "$T/sessions/$SID"
: > "$T/paused/$SID"  # idle_prompt fired: without background work this session is idle
BG="$T/bg/$SID"

fail=0
chk(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }
rel(){ grep -c "no active session" "$ERR"; }
held(){ grep -c "hold acquired" "$ERR"; }
entry(){ printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$BG"; }  # rewrite → new mtime → cache miss
wait_for(){ local i; for i in $(seq "$1"); do eval "$2" && return 0; sleep 1; done; return 1; }

TOOL_USE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1"}],"stop_reason":null}}'
FINAL_NULL='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Report: done"}],"stop_reason":null}}'
FINAL_END='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Report: done"}],"stop_reason":"end_turn"}}'
HOOK='{"type":"attachment","attachment":{"type":"hook_success"}}'
now=$(date +%s)

# 1. Subagent mid-work (last line a tool_use) → HOLD despite the paused marker.
printf '%s\n' "$TOOL_USE" > "$SUBTR"
entry "$now" subagent a1 "$SUBTR"
"$BIN" >/dev/null 2>"$ERR" & DID=$!; disown
sleep 3
chk "running subagent => daemon HOLDS despite paused" '[ "$(rel)" -eq 0 ]'
chk "hold is announced in the log" 'grep -q "background work holds session $SID: subagent a1" "$ERR"'

# 2. Subagent's final text with stop_reason null, still fresh → keeps holding;
#    once quiet 90s (mtime aged) → done → RELEASE.
printf '%s\n%s\n' "$FINAL_NULL" "$HOOK" > "$SUBTR"
entry "$now" subagent a1 "$SUBTR"
sleep 2
chk "fresh null-stop final text => still HOLDS (may be mid-message)" '[ "$(rel)" -eq 0 ]'
touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$SUBTR"
entry "$now" subagent a1 "$SUBTR"
chk "quiet null-stop final text => RELEASES" 'wait_for 5 "[ \$(rel) -ge 1 ]"'

# 3. end_turn → done at once; a running shell task (file held) → HOLD.
printf '%s\n' "$FINAL_END" > "$SUBTR"
OUT="$T/tasks/bbuild.output"; mkdir -p "$T/tasks"
sleep 600 > "$OUT" 2>&1 & TASK=$!; disown
b=$(held)
entry "$now" shell bbuild "$OUT"
chk "running shell task => daemon re-HOLDS" 'wait_for 5 "[ \$(held) -gt $b ]"'

# 4. Shell task finishes (no holders) → RELEASE.
b=$(rel)
kill $TASK 2>/dev/null; TASK=""
sleep 1; entry "$now" shell bbuild "$OUT"
chk "finished shell task => RELEASES" 'wait_for 5 "[ \$(rel) -gt $b ]"'

# 5. Shell task past the 1h cap → no hold even while running.
sleep 600 > "$OUT" 2>&1 & TASK=$!; disown
b=$(held)
entry "$((now - 3601))" shell bbuild "$OUT"
sleep 3
chk "shell task over the 1h cap => stays RELEASED" '[ "$(held)" -eq $b ]'
kill $TASK 2>/dev/null; TASK=""

# 6. Server (holder keeps listening on TCP) → held briefly, RELEASED after 30s.
SOUT="$T/tasks/bsrv.output"
python3 -m http.server 0 --bind 127.0.0.1 > "$SOUT" 2>&1 & SRV=$!; disown
wait_for 10 "lsof -nP -a -p $SRV -iTCP -sTCP:LISTEN -t >/dev/null 2>&1"
b=$(held); r=$(rel)
entry "$now" shell bsrv "$SOUT"
chk "listening shell task => held at first (could be a test's port)" 'wait_for 5 "[ \$(held) -gt $b ]"'
chk "listening 30s => server => RELEASES" 'wait_for 60 "[ \$(rel) -gt $r ]"'

exit $fail
