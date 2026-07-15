#!/bin/bash
# Regression: an aborted turn (Esc interrupt or API-error stop) must let the
# Mac sleep.
#
# Esc fires no Stop and no Notification, so the session stays registered and
# unpaused — pre-fix it held the Mac until the 2h watchdog. The daemon now reads
# the session transcript tail: if the last user/assistant message starts with
# "[Request interrupted by user" the turn was aborted → release. Claude Code
# writes two variants — "...user]" (Esc idle) and "...user for tool use]" (Esc
# while a tool runs) — both must be caught. A usage-limit/API-error stop (429,
# overloaded, auth) is the same hook-less dead end: the CLI appends a synthetic
# assistant message whose line carries top-level "isApiErrorMessage": true —
# matched by flag, not banner text. A genuinely running foreground tool is NOT
# confused for either: its tool_use line is written at tool START, so a live
# tool leaves a trailing tool_use with no tool_result, never an abort marker.
#
# Drives the real daemon binary against an isolated state dir and a synthetic
# transcript, asserting hold/release decisions from its log.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN=$(mktemp)
swiftc -O "$ROOT/src/keep-awake-daemon.swift" -o "$BIN" || { echo "COMPILE FAIL"; exit 1; }

T=$(mktemp -d)
export KEEP_AWAKE_STATE_DIR="$T" KEEP_AWAKE_PROC_NAME=sleep
mkdir -p "$T/sessions" "$T/transcripts"
ERR="$T/daemon.err"
TR="$T/conv.jsonl"

sleep 600 & SID=$!
echo "$SID"  > "$T/sessions/$SID"
echo "$TR"   > "$T/transcripts/$SID"

WORKING='{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"t1"}]}}'
INTERRUPT='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
INTERRUPT_TOOL='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}'
PROMPT='{"type":"user","message":{"role":"user","content":[{"type":"text","text":"keep going"}]}}'
API_ERROR='{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","apiErrorStatus":429,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 3:40am (Asia/Nicosia)"}]}}'
META='{"type":"pr-link","url":"x"}'

fail=0
chk(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }
rel(){ grep -c "no active session" "$ERR"; }
held(){ grep -c "hold acquired" "$ERR"; }

# 1. Control: a tool is in flight (trailing tool_use, no result) → must HOLD.
printf '%s\n%s\n' "$PROMPT" "$WORKING" > "$TR"
"$BIN" >/dev/null 2>"$ERR" & DID=$!
sleep 3
chk "tool in flight (trailing tool_use) => daemon HOLDS" '! grep -q releasing "$ERR"'

# 2. Interrupt while idle → RELEASE (trailing metadata line must be ignored).
b=$(rel); printf '%s\n%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$INTERRUPT" "$META" > "$TR"; sleep 3
chk "interrupt marker last message => daemon RELEASES" '[ "$(rel)" -gt "$b" ]'

# 3. Resume: a newer prompt arrives after the interrupt → HOLD again.
b=$(held); printf '%s\n%s\n' "$INTERRUPT" "$PROMPT" > "$TR"; sleep 3
chk "newer prompt after interrupt => daemon re-HOLDS" '[ "$(held)" -gt "$b" ]'

# 4. Interrupt while a TOOL ran writes the "for tool use" variant → RELEASE.
b=$(rel); printf '%s\n%s\n' "$PROMPT" "$INTERRUPT_TOOL" > "$TR"; sleep 3
chk "interrupt 'for tool use' variant => daemon RELEASES" '[ "$(rel)" -gt "$b" ]'

# 5. Turn ended by a usage-limit/API error (synthetic assistant message,
#    isApiErrorMessage:true, trailing metadata ignored) → RELEASE.
#    Case 4 left the daemon released; re-hold first so the release is a transition.
printf '%s\n' "$PROMPT" > "$TR"; sleep 3
b=$(rel); printf '%s\n%s\n%s\n%s\n' "$PROMPT" "$WORKING" "$API_ERROR" "$META" > "$TR"; sleep 3
chk "API-error stop (isApiErrorMessage) => daemon RELEASES" '[ "$(rel)" -gt "$b" ]'

# 6. Resume: a newer prompt arrives after the limit stop → HOLD again.
b=$(held); printf '%s\n%s\n' "$API_ERROR" "$PROMPT" > "$TR"; sleep 3
chk "newer prompt after API-error stop => daemon re-HOLDS" '[ "$(held)" -gt "$b" ]'

kill "$DID" "$SID" 2>/dev/null
rm -rf "$T" "$BIN"
echo
[ "$fail" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$fail"
