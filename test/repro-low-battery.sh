#!/bin/bash
# Regression: on battery, the daemon must stop holding the Mac at or below
# KEEP_AWAKE_MIN_BATTERY percent (default 25) or with Low Power Mode on, so a
# closed-lid session can't drain it to the emergency hibernate at ~1 %.
# On AC the cutoff must not apply.
#
# The cutoff is driven through KEEP_AWAKE_MIN_BATTERY: 100 is "always below",
# 0 disables the percentage check. Which half runs depends on the power source
# right now; run it once plugged in and once on battery.
#
# Drives the real daemon binary against an isolated state dir, asserting
# hold/release decisions from its log.
set -u
unset CLAUDE_PID  # run from inside Claude Code: key hooks on this test, not the real CLI

[ "$(uname -s)" = "Darwin" ] || { echo "SKIP: macOS only"; exit 0; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN=$(mktemp)
swiftc -O "$ROOT/src/keep-awake-daemon.swift" -o "$BIN" || { echo "COMPILE FAIL"; exit 1; }

T=$(mktemp -d)
export KEEP_AWAKE_STATE_DIR="$T" KEEP_AWAKE_PROC_NAME=sleep
mkdir -p "$T/sessions"
sleep 600 & SID=$!
echo "$SID" > "$T/sessions/$SID"

fail=0
chk(){ if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; fail=1; fi; }
DID=""
run(){  # run <cutoff> <log>: start a daemon with that cutoff, let it tick
  [ -n "$DID" ] && { kill "$DID" 2>/dev/null; wait "$DID" 2>/dev/null; }
  KEEP_AWAKE_MIN_BATTERY="$1" "$BIN" >/dev/null 2>"$2" & DID=$!
  sleep 3
}

if pmset -g batt | grep -q "AC Power"; then
  echo "on AC power"
  run 100 "$T/ac.err"
  chk "on AC, cutoff 100% => daemon HOLDS" '! grep -q releasing "$T/ac.err"'
  echo "  (unplug and run again to test the battery release)"
else
  echo "on battery ($(pmset -g batt | grep -o '[0-9]*%'))"
  run 100 "$T/low.err"
  chk "on battery, cutoff 100% => daemon RELEASES" 'grep -q "battery at .*cutoff 100%.* → releasing\|Low Power Mode on battery → releasing" "$T/low.err"'
  if pmset -g | grep -q "lowpowermode *1"; then
    run 0 "$T/lpm.err"
    chk "Low Power Mode, cutoff off => daemon RELEASES" 'grep -q "Low Power Mode on battery → releasing" "$T/lpm.err"'
  else
    run 0 "$T/off.err"
    chk "cutoff 0 (off), no Low Power Mode => daemon HOLDS" '! grep -q releasing "$T/off.err"'
  fi
fi

kill "$DID" "$SID" 2>/dev/null
wait 2>/dev/null
rm -rf "$T" "$BIN"
[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
