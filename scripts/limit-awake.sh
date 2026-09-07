#!/bin/bash
# StopFailure hook: the turn ended on an API error. A usage-limit stop is the one
# ending where releasing the Mac is wrong — Claude Code's own
# autoContinueAtUsageLimit waits out the reset and re-prompts itself, but only if
# the machine is still awake, and its arming is not reliable. So record the reset
# time (plus this session's messaging socket) in limit/<cli-pid>: the daemon holds
# past the paused/aborted-turn rules until reset+grace, then either sees that a
# hook fired (the CLI resumed on its own) or injects a continue prompt itself.
# Every other error — and the setting explicitly off — falls through to the normal
# aborted-turn path, so the Mac sleeps exactly as before. This only records
# intent: the daemon (alive for the whole turn that hit the limit) does the
# holding, so the hook never starts one.
set -u

# Single read captures full JSON (NUL delimiter → reads to EOF). 1s cap.
IFS= read -r -t 1 -d '' HOOK_INPUT || true
# Keyed by Claude CLI PID, matching keep-awake.sh (session_id is unstable).
PARENT_PID="${PPID:-$$}"

STATE_DIR="${HOME}/.claude/keep-awake-state"

# Kill-switch: if this file exists, do nothing (Mac may sleep normally).
[ -e "$STATE_DIR/disabled" ] && exit 0

# StopFailure also fires for overloaded/auth/billing/server errors — those are
# dead ends with no known resume time, so only a rate limit is held for.
# Closing quotes rule out longer values that merely share the prefix.
[[ $HOOK_INPUT == *'"hook_event_name":"StopFailure"'* ]] || exit 0
[[ $HOOK_INPUT == *'"error":"rate_limit"'* ]] || exit 0

# ---------- setting gate ----------
# Holding only makes sense if the CLI intends to auto-continue. Mirror Claude
# Code's settings precedence; the key is absent by default and defaults to on.
CWD=$(printf '%s' "$HOOK_INPUT" | grep -oE '"cwd":"[^"]+"' | head -1 | sed -E 's/.*:"([^"]+)"/\1/')
[ -n "$CWD" ] || CWD="$PWD"
MANAGED_SETTINGS="${KEEP_AWAKE_MANAGED_SETTINGS:-/Library/Application Support/ClaudeCode/managed-settings.json}"

setting_value() {  # <file> → prints true|false, nothing if the key is absent
  [ -f "$1" ] || return 0
  grep -oE '"autoContinueAtUsageLimit"[[:space:]]*:[[:space:]]*(true|false)' "$1" 2>/dev/null \
    | head -1 | sed -E 's/.*(true|false)$/\1/'
}

AUTO_CONTINUE=""
for f in "$MANAGED_SETTINGS" \
         "$CWD/.claude/settings.local.json" \
         "$CWD/.claude/settings.json" \
         "$HOME/.claude/settings.json"; do
  AUTO_CONTINUE=$(setting_value "$f")
  [ -n "$AUTO_CONTINUE" ] && break
done
[ "$AUTO_CONTINUE" = false ] && exit 0

# ---------- reset time ----------
# Wordings seen: "resets 4:30pm (Asia/Nicosia)", "resets 3am (...)",
# "limit resets 16:00", "limit resets at 16:00.", "(reset 19:10 EEST".
# The clock time must directly follow "resets"/"resets at": a weekly limit
# ("resets Aug 23 at 3pm") never matches and is never held for, while a message
# naming both a weekly and a 5h reset still yields the 5h one. The zone is only
# trusted in the parenthesized Area/City form (2+ components); anything else
# parses as local time.
MATCH=$(printf '%s' "$HOOK_INPUT" \
  | grep -oE 'resets?( at)? *([0-9]{1,2}(:[0-9]{2})?[apAP][mM]|[0-9]{1,2}:[0-9]{2})( \(([A-Za-z_]+/)+[A-Za-z_]+\))?' \
  | head -1)
[ -n "$MATCH" ] || exit 0

TIME=$(printf '%s' "$MATCH" | grep -oE '[0-9]{1,2}(:[0-9]{2})?[apAP][mM]|[0-9]{1,2}:[0-9]{2}' | head -1)
ZONE=$(printf '%s' "$MATCH" | sed -nE 's/.*\((([A-Za-z_]+\/)+[A-Za-z_]+)\)$/\1/p')
[ -z "$ZONE" ] || [ -f "/usr/share/zoneinfo/$ZONE" ] || ZONE=""  # an unknown TZ would silently mean UTC

tz_date() { if [ -n "$ZONE" ]; then TZ="$ZONE" date "$@"; else date "$@"; fi; }

# Meridiem is folded into a 24h hour here rather than left to strptime: BSD date
# silently ignores %p ("Warning: Ignoring 2 extraneous characters"), so 4:30pm
# would parse as 04:30. Seconds are pinned too — unspecified fields default to
# the current time, not zero.
HOUR=${TIME%%:*}; HOUR=${HOUR%%[apAP]*}
MINUTE=00
case "$TIME" in *:*) MINUTE=${TIME#*:}; MINUTE=${MINUTE%%[apAP]*} ;; esac
case "$TIME" in
  *[pP][mM]) [ "$((10#$HOUR))" -lt 12 ] && HOUR=$((10#$HOUR + 12)) ;;
  *[aA][mM]) [ "$((10#$HOUR))" = 12 ] && HOUR=0 ;;
esac

TODAY=$(tz_date +%Y-%m-%d)
STAMP=$(printf '%s %02d:%s:00' "$TODAY" "$((10#$HOUR))" "$MINUTE")
EPOCH=$(tz_date -j -f '%Y-%m-%d %H:%M:%S' "$STAMP" +%s 2>/dev/null || tz_date -d "$STAMP" +%s 2>/dev/null)
case "$EPOCH" in ''|*[!0-9]*) exit 0 ;; esac

NOW=$(date +%s)
# The banner gives a clock time, not a date: a reset that already passed today is
# tomorrow's. A window beyond 6h (a 5h limit plus slack) is a different limit
# (weekly, or a wording we misread) — not ours to hold for.
[ "$EPOCH" -le "$NOW" ] && EPOCH=$((EPOCH + 86400))
[ $((EPOCH - NOW)) -gt 21600 ] && exit 0

# ---------- marker ----------
# No lock: one CLI process owns this file, and the daemon only reads/removes it.
# The messaging socket is the injection channel if the CLI's own auto-continue
# never fires; empty lines are fine, the daemon then just holds and releases.
# The token lets whoever reads it inject prompts into this session — owner-only
# dir and file. Written via rename so the daemon never sees a half-written marker
# (it drops what it cannot parse).
mkdir -p "$STATE_DIR/limit" && chmod 700 "$STATE_DIR/limit"
MARKER="$STATE_DIR/limit/$PARENT_PID"
(umask 077; printf '%s\n%s\n%s\n' "$EPOCH" "${CLAUDE_CODE_MESSAGING_SOCKET:-}" "${CLAUDE_CODE_MESSAGING_TOKEN:-}" > "$MARKER.tmp") \
  && mv -f "$MARKER.tmp" "$MARKER"

# A limit stop can end the very first turn, before any hook registered the
# session — and the daemon only holds for sessions it knows. Touching the file
# now also stamps it BEFORE the reset epoch, which is what lets the daemon tell
# "a hook fired after the reset" (the CLI resumed) from "nothing happened".
mkdir -p "$STATE_DIR/sessions"
echo "$PARENT_PID" > "$STATE_DIR/sessions/$PARENT_PID"
