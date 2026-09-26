#!/bin/bash
# Regression: a usage-limit stop must HOLD the Mac until the reset and re-prompt
# the session if the CLI's own auto-continue never fired.
#
# limit-awake.sh (StopFailure hook) leaves limit/<pid> = reset epoch / messaging
# socket / token. While it is pending the daemon must hold even though the
# transcript ends with an API-error stop AND a paused marker exists (the 60s idle
# Notification fires after a limit stop). At reset+grace: a hook that touched
# sessions/<pid> after the reset means the CLI resumed on its own → no inject;
# otherwise the daemon connects to the session's messaging socket and sends the
# auth + user-message lines, holds one more grace period, then releases. Markers
# beyond the 6h cap, for dead PIDs, or without a socket are dropped.
#
# Drives the real daemon binary against an isolated state dir and a fake inbox
# (a Unix-socket server that logs every received line).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN=$(mktemp)
swiftc -O "$ROOT/src/keep-awake-daemon.swift" -o "$BIN" || { echo "COMPILE FAIL"; exit 1; }

T=$(mktemp -d /tmp/kalim.XXXXXX)  # short: Unix socket paths are capped at 104 bytes
export KEEP_AWAKE_STATE_DIR="$T" KEEP_AWAKE_PROC_NAME=sleep KEEP_AWAKE_LIMIT_GRACE_SEC=3
mkdir -p "$T/sessions" "$T/transcripts" "$T/paused" "$T/limit"
ERR="$T/daemon.err"
TR="$T/conv.jsonl"
SOCK="$T/inbox.sock"
INBOX="$T/inbox.log"; : > "$INBOX"
DID="" SID="" SRV=""
cleanup() { kill $DID $SID $SRV 2>/dev/null; rm -rf "$T" "$BIN"; }
trap cleanup EXIT INT TERM

sleep 600 & SID=$!; disown
echo "$SID" > "$T/sessions/$SID"
echo "$TR"  > "$T/transcripts/$SID"

PROMPT='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}'
WORKING='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1"}]}}'
API_ERROR='{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 3:40am (Asia/Nicosia)"}]}}'
LOCAL_CMD='{"type":"user","message":{"role":"user","content":"<command-name>/rate-limit-options</command-name>"}}'

# Fake inbox: append every line each connection sends to $INBOX.
python3 - "$SOCK" "$INBOX" <<'PY' & SRV=$!
import socket, sys
path, out = sys.argv[1], sys.argv[2]
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(5)
while True:
    c, _ = srv.accept()
    data = b''
    while True:
        chunk = c.recv(4096)
        if not chunk: break
        data += chunk
    with open(out, 'ab') as f: f.write(data)
    c.close()
PY
disown
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
[ -S "$SOCK" ] || { echo "FAIL: inbox server never bound $SOCK"; exit 1; }

fail=0
chk(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }
rel(){ grep -c "no active session" "$ERR"; }
held(){ grep -c "hold acquired" "$ERR"; }
marker(){ printf '%s\n%s\n%s\n' "$(( $(date +%s) + $1 ))" "$2" "$3" > "$T/limit/$SID"; }

# 1. Limit stop: API-error transcript + paused marker + pending limit marker → HOLD.
printf '%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" > "$TR"
: > "$T/paused/$SID"
marker 4 "$SOCK" tok123
"$BIN" >/dev/null 2>"$ERR" & DID=$!; disown
sleep 3
chk "limit marker pending => daemon HOLDS despite API error + paused" '! grep -q releasing "$ERR"'
chk "hold is announced in the log" 'grep -q "limit stop: holding session $SID until" "$ERR"'

# 2. Reset + grace (t≈7) passes with no hook activity → inject. The injection is
#    the session's next user prompt, so the paused marker is cleared; the hold
#    bridges one more grace (until t≈10), then the transcript decides.
b=$(rel); sleep 5   # t≈8: injected, marker rewritten
chk "auth line reached the inbox" 'grep -q "\"type\":\"auth\",\"token\":\"tok123\"" "$INBOX"'
chk "continue prompt reached the inbox" 'grep -q "Usage limit has reset" "$INBOX"'
chk "injection logged" 'grep -q "limit reset: injected continue into session $SID" "$ERR"'
chk "marker rewritten as injected" '[ "$(sed -n 4p "$T/limit/$SID")" = injected ]'
chk "paused marker cleared by the injection" '[ ! -e "$T/paused/$SID" ]'
# The CLI accepted the prompt: it is now the transcript's newest message.
printf '%s\n%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" "$PROMPT" > "$TR"; sleep 4   # t≈12: injected hold over
chk "injected hold over => marker dropped" '[ ! -e "$T/limit/$SID" ]'
chk "…prompt in transcript => daemon keeps HOLDING (live turn)" '[ "$(rel)" -eq "$b" ]'
# That turn hits the limit again (or the CLI never took the prompt) → release.
printf '%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" > "$TR"; sleep 3
chk "transcript ending in the API error again => daemon RELEASES" '[ "$(rel)" -gt "$b" ]'

# 3. The CLI resumed on its own: sessions/<pid> touched after the reset → no inject.
n=$(wc -l < "$INBOX"); b=$(held)
marker 3 "$SOCK" tok123; sleep 4
chk "new marker => daemon re-HOLDS" '[ "$(held)" -gt "$b" ]'
touch "$T/sessions/$SID"; sleep 4
chk "hook after reset => 'resumed on its own' logged" 'grep -q "limit reset: session $SID resumed on its own → no inject" "$ERR"'
chk "…no second injection" '[ "$(wc -l < "$INBOX")" -eq "$n" ]'
chk "…marker dropped" '[ ! -e "$T/limit/$SID" ]'

# 3b. The user acted without any hook firing: a local command (/rate-limit-options
#     "Don't continue", /low-priority, …) is logged as a user entry, so the
#     transcript no longer ends in the API error → the hold is over, no inject.
#     Judged only once the marker is older than the grace (the error line and the
#     StopFailure hook race by milliseconds at the stop itself).
n=$(wc -l < "$INBOX")
marker 6 "$SOCK" tok123
printf '%s\n%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" "$LOCAL_CMD" > "$TR"; sleep 5   # t≈5: age > grace(3), reset still 1 s away
chk "transcript moved on (local command) => marker dropped before the reset" '[ ! -e "$T/limit/$SID" ]'
chk "…logged as moved on" 'grep -q "limit reset: session $SID moved on (transcript) → no inject" "$ERR"'
sleep 5   # past reset+grace: nothing must have been injected
chk "…no injection" '[ "$(wc -l < "$INBOX")" -eq "$n" ]'
printf '%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" > "$TR"; sleep 2   # back to the limit-stop shape

# 4. Marker without a messaging socket → hold, then release with a logged reason.
marker 3 "" ""; sleep 8
chk "no socket => 'failed (no messaging socket)' logged" 'grep -q "failed (no messaging socket) → releasing" "$ERR"'
chk "…marker dropped" '[ ! -e "$T/limit/$SID" ]'

# 5. Marker beyond the 6h cap (weekly limit / misparse) → dropped, never held.
b=$(held); marker $((7 * 3600)) "$SOCK" tok123; sleep 3
chk "over-cap marker => dropped" 'grep -q "limit marker for session $SID invalid/expired → dropped" "$ERR"'
chk "…and not held" '[ "$(held)" -eq "$b" ]'

# 6. Marker for a dead PID → dropped.
sleep 1 & DEAD=$!; wait "$DEAD"
printf '%s\n%s\n%s\n' "$(( $(date +%s) + 100 ))" "$SOCK" tok123 > "$T/limit/$DEAD"; sleep 3
chk "dead-PID marker => dropped" '[ ! -e "$T/limit/$DEAD" ]'

echo
[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$fail"
