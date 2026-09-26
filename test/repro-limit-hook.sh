#!/bin/bash
# Regression test for the StopFailure hook (scripts/limit-awake.sh): a usage-limit
# stop must leave a limit/<cli-pid> marker (reset epoch, messaging socket, token)
# only when Claude Code's own autoContinueAtUsageLimit is on — absent or true in
# the settings hierarchy — and only for a same-day 5h reset. Weekly limits, other
# API errors, other events, the setting explicitly off, and the plugin
# kill-switch must all leave no marker, so the Mac sleeps exactly as before.
#
# Reset times are generated relative to now (+2h) so the hook's 6h cap never
# trips regardless of when the test runs.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/scripts/limit-awake.sh"
FAIL=0
export CLAUDE_CODE_MESSAGING_SOCKET=/tmp/x.sock CLAUDE_CODE_MESSAGING_TOKEN=abc123

payload() {  # <error> <text> [cwd] [event] -> StopFailure-shaped hook JSON
  printf '{"session_id":"s","transcript_path":"/tmp/t.jsonl","cwd":"%s","hook_event_name":"%s","error":"%s","last_assistant_message":"%s"}' \
    "${3:-/tmp}" "${4:-StopFailure}" "$1" "$2"
}
TMPS=""
fresh_home() { HOME="$(mktemp -d)"; export HOME; TMPS="$TMPS $HOME"; }
run() {  # <json> -> runs the hook in a fresh isolated HOME; sets MARKER
  fresh_home
  export KEEP_AWAKE_MANAGED_SETTINGS="$HOME/no-managed-settings.json"
  MARKER="$HOME/.claude/keep-awake-state/limit/$$"
  printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1
}
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; FAIL=1; }
expect_marker() {  # <desc> <HH:MM> [TZ] — epoch in (now, now+24h], wall clock matches
  [ -f "$MARKER" ] || { fail "$1 (no marker)"; return; }
  local epoch now hhmm
  epoch=$(sed -n 1p "$MARKER"); now=$(date +%s)
  if [ -n "${3:-}" ]; then hhmm=$(TZ="$3" date -r "$epoch" +%H:%M); else hhmm=$(date -r "$epoch" +%H:%M); fi
  if [ "$epoch" -gt "$now" ] && [ $((epoch - now)) -le 86400 ] && [ "$hhmm" = "$2" ]; then pass "$1"
  else fail "$1 (epoch=$epoch now=$now hhmm=$hhmm want=$2)"; fi
}
expect_none() { if [ -e "$MARKER" ]; then fail "$1 (marker written)"; else pass "$1"; fi; }

ZONE=Asia/Nicosia
AMPM=$(LC_ALL=C TZ=$ZONE date -v+2H '+%-I:%M%p' | tr 'APM' 'apm')       # e.g. 4:30pm
AMPM_WANT=$(TZ=$ZONE date -v+2H +%H:%M)
HOURS=$(LC_ALL=C TZ=$ZONE date -v+2H '+%-I%p' | tr 'APM' 'apm')          # e.g. 3pm
HOURS_WANT=$(TZ=$ZONE date -v+2H +%H:00)
H24=$(date -v+2H +%H:%M)                                      # local, no zone

run "$(payload rate_limit "You've hit your session limit · resets $AMPM ($ZONE)")"
expect_marker "5h limit, am/pm with zone -> marker at $AMPM_WANT $ZONE" "$AMPM_WANT" "$ZONE"
[ "$(sed -n 2p "$MARKER")" = /tmp/x.sock ] && pass "marker line 2 = socket" || fail "marker line 2 = socket"
[ "$(sed -n 3p "$MARKER")" = abc123 ] && pass "marker line 3 = token" || fail "marker line 3 = token"

run "$(payload rate_limit "You've hit your session limit · resets $HOURS ($ZONE)")"
expect_marker "5h limit, hours only ($HOURS) -> :00" "$HOURS_WANT" "$ZONE"

run "$(payload rate_limit "Claude AI usage limit resets $H24")"
expect_marker "24h wording without zone -> local time" "$H24"

run "$(payload rate_limit "You've hit your weekly limit · resets Sep 9 at 3pm ($ZONE)")"
expect_none "weekly limit (date form) -> no marker"

run "$(payload rate_limit "Your weekly limit resets Sep 9 at 3pm. Your 5-hour limit resets $AMPM ($ZONE)")"
expect_marker "weekly + 5h in one message -> the 5h reset is held" "$AMPM_WANT" "$ZONE"

FAR=$(LC_ALL=C TZ=$ZONE date -v+7H '+%-I:%M%p' | tr 'APM' 'apm')
run "$(payload rate_limit "resets $FAR ($ZONE)")"
expect_none "reset 7h away (beyond the 6h cap) -> no marker"

PAST=$(LC_ALL=C TZ=$ZONE date -v-2M '+%-I:%M%p' | tr 'APM' 'apm')
run "$(payload rate_limit "resets $PAST ($ZONE)")"
expect_none "reset 2 min ago rolls to tomorrow -> beyond cap -> no marker"

ZONE3=America/Argentina/Buenos_Aires
AMPM3=$(LC_ALL=C TZ=$ZONE3 date -v+2H '+%-I:%M%p' | tr 'APM' 'apm')
run "$(payload rate_limit "resets $AMPM3 ($ZONE3)")"
expect_marker "3-component zone ($ZONE3) parsed in that zone" "$(TZ=$ZONE3 date -v+2H +%H:%M)" "$ZONE3"

run "$(payload rate_limit "resets $AMPM ($ZONE)")"
SESS="$HOME/.claude/keep-awake-state/sessions/$$"
if [ -f "$SESS" ] && [ "$(stat -f %m "$SESS")" -lt "$(sed -n 1p "$MARKER")" ]; then
  pass "sessions/<pid> stamped before the reset epoch"; else fail "sessions/<pid> stamped before the reset epoch"; fi
[ "$(stat -f %Lp "$MARKER")" = 600 ] && pass "marker is owner-only (0600)" || fail "marker mode $(stat -f %Lp "$MARKER")"
[ "$(stat -f %Lp "$(dirname "$MARKER")")" = 700 ] && pass "limit/ dir is owner-only (0700)" || fail "limit/ dir mode $(stat -f %Lp "$(dirname "$MARKER")")"

run "$(payload overloaded "API overloaded · resets $AMPM ($ZONE)")"
expect_none "error=overloaded -> no marker"

run "$(payload rate_limit "resets $AMPM ($ZONE)" /tmp Stop)"
expect_none "hook_event_name=Stop -> no marker"

run_with_user_setting() {  # <true|false> <json>
  fresh_home
  export KEEP_AWAKE_MANAGED_SETTINGS="$HOME/no-managed-settings.json"
  MARKER="$HOME/.claude/keep-awake-state/limit/$$"
  mkdir -p "$HOME/.claude"
  printf '{"autoContinueAtUsageLimit": %s}' "$1" > "$HOME/.claude/settings.json"
  printf '%s' "$2" | bash "$HOOK" >/dev/null 2>&1
}
run_with_user_setting false "$(payload rate_limit "resets $AMPM ($ZONE)")"
expect_none "user settings autoContinueAtUsageLimit=false -> no marker"
run_with_user_setting true "$(payload rate_limit "resets $AMPM ($ZONE)")"
expect_marker "user settings autoContinueAtUsageLimit=true -> marker" "$AMPM_WANT" "$ZONE"

# Project-local settings win over user settings (Claude Code precedence).
PROJ="$(mktemp -d)"; mkdir -p "$PROJ/.claude"
printf '{"autoContinueAtUsageLimit": false}' > "$PROJ/.claude/settings.local.json"
run_with_user_setting true "$(payload rate_limit "resets $AMPM ($ZONE)" "$PROJ")"
expect_none "project local=false over user=true -> no marker"
printf '{"autoContinueAtUsageLimit": true}' > "$PROJ/.claude/settings.local.json"
run_with_user_setting false "$(payload rate_limit "resets $AMPM ($ZONE)" "$PROJ")"
expect_marker "project local=true over user=false -> marker" "$AMPM_WANT" "$ZONE"
rm -rf "$PROJ"

( unset CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN
  HOME="$(mktemp -d)"; export HOME KEEP_AWAKE_MANAGED_SETTINGS="$HOME/none.json"; trap 'rm -rf "$HOME"' EXIT
  printf '%s' "$(payload rate_limit "resets $AMPM ($ZONE)")" | bash "$HOOK" >/dev/null 2>&1
  M=$(ls "$HOME"/.claude/keep-awake-state/limit/* 2>/dev/null | head -1)  # keyed by the subshell PID (no BASHPID in bash 3.2)
  if [ -f "$M" ] && [ "$(wc -l < "$M")" -eq 3 ] && [ -z "$(sed -n 2p "$M")" ] && [ -z "$(sed -n 3p "$M")" ]; then
    echo "  PASS: no messaging env -> marker with empty socket/token lines"
  else echo "  FAIL: no messaging env -> marker with empty socket/token lines"; exit 1; fi ) || FAIL=1

fresh_home; export KEEP_AWAKE_MANAGED_SETTINGS="$HOME/none.json"
MARKER="$HOME/.claude/keep-awake-state/limit/$$"
mkdir -p "$HOME/.claude/keep-awake-state"; : > "$HOME/.claude/keep-awake-state/disabled"
printf '%s' "$(payload rate_limit "resets $AMPM ($ZONE)")" | bash "$HOOK" >/dev/null 2>&1
expect_none "kill-switch 'disabled' -> no marker"

rm -rf $TMPS
echo
[ "$FAIL" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$FAIL"
