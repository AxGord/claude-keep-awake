#!/bin/bash
# Unregister this Claude Code session. If it was the last live session,
# terminate the daemon (which performs its own cleanup).
set -u

# Keyed by Claude CLI PID, matching keep-awake.sh (session_id is unstable).
# Single read captures full JSON (NUL delimiter → reads to EOF). 1s cap.
HOOK_INPUT=""  # stays set under `set -u` even if the read times out
IFS= read -r -t 1 -d '' HOOK_INPUT || true
PARENT_PID="${PPID:-$$}"

STATE_DIR="${HOME}/.claude/keep-awake-state"
SESSIONS_DIR="$STATE_DIR/sessions"
PAUSED_DIR="$STATE_DIR/paused"
BG_DIR="$STATE_DIR/bg"
BGOUT_DIR="$STATE_DIR/bgout"
TRANSCRIPTS_DIR="$STATE_DIR/transcripts"
LIMIT_DIR="$STATE_DIR/limit"
DAEMON_PID_FILE="$STATE_DIR/daemon.pid"
LOCK_DIR="$STATE_DIR/.lock"

[ -d "$STATE_DIR" ] || exit 0

acquire_lock() {
  local i=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    i=$((i+1))
    [ $i -gt 50 ] && { rm -rf "$LOCK_DIR" 2>/dev/null; i=0; }
    sleep 0.1
  done
}
release_lock() { rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap release_lock EXIT

# A session PID counts as live only if the process exists AND is still a
# `claude` process. A bare kill -0 also passes when the OS recycles a dead
# session's PID to an unrelated process (observed: AudioComponentRegistrar) —
# that phantom would otherwise keep the daemon awake forever. Process name is
# overridable (KEEP_AWAKE_PROC_NAME) for tests and non-native installs.
# A backgrounded session runs straight from the installer's versioned binary
# (…/claude/versions/<ver>) rather than via the `claude` symlink — same CLI.
SESSION_PROC_NAME="${KEEP_AWAKE_PROC_NAME:-claude}"
session_pid_live() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
    */"$SESSION_PROC_NAME"|"$SESSION_PROC_NAME"|*/"$SESSION_PROC_NAME"/versions/*) return 0 ;;
    *) return 1 ;;
  esac
}

has_live_sessions() {
  for f in "$SESSIONS_DIR"/*; do
    [ -e "$f" ] || continue
    local pid; pid=$(cat "$f" 2>/dev/null) || continue
    session_pid_live "$pid" && return 0
    rm -f "$f"
  done
  return 1
}

acquire_lock

# ---------- background work ----------
# The turn is over but work it launched may still run: async subagents,
# workflows, run_in_background shell tasks. Their completion revives Claude, and
# that revival turn ends with another Stop — so keeping the session registered
# now and re-deciding on every Stop releases the Mac once the work is done.
# Stop's background_tasks is the CLI's own list of in-flight work. Held:
#  - subagent / workflow / teammate: always finishes. A subagent records its
#    transcript, which the daemon reads to catch one that ended or went silent.
#  - shell: a build/test — unless it is a Monitor (id recorded by keep-awake.sh)
#    or its command looks like a server/watcher. The daemon also drops a shell
#    task whose processes exited or listen on TCP (a server this regex missed).
#    Capped at BG_SHELL_MAX_HOLD_SEC since first seen: a process running that
#    long is suspect and must not pin the Mac. An expired entry stays in the
#    marker with its original first_seen, so the cap can't re-arm next Stop.
#  - anything else (MCP tasks, remote sessions, internal jobs): not held.
# bg/<pid> lines: first_seen<TAB>type<TAB>id<TAB>path (shell: output file,
# subagent: transcript).
BG_SHELL_MAX_HOLD_SEC=3600
BG_MARKER="$BG_DIR/$PARENT_PID"
BGOUT_MARKER="$BGOUT_DIR/$PARENT_PID"
NOW=$(date +%s)

# Server/watcher commands, bound to a runner or to command position so a bare
# word (`git checkout dev`, `rsync … server:`, `pip install uvicorn`) never
# matches; the daemon's TCP-listen probe catches the rest. Boundaries include
# quotes (`bash -c 'npm run dev'`) but not `/`; `--watch=false` is not a watcher.
SRV_B="(^|[[:space:];&|(\"'\\\\])"
SRV_E="([[:space:]:;&|)\"'\\\\]|\$)"
SRV_CMD="(^|[;&|(\"'\\\\])[[:space:]]*((npx|bunx|exec|env|time|uv run|poetry run) +)?"
SERVER_CMD_RE="${SRV_B}(npm|pnpm|yarn|bun)( run)? (dev|start|serve|watch|preview)${SRV_E}|${SRV_B}(next|vite|nuxt|astro) (dev|preview)${SRV_E}|${SRV_CMD}vite[[:space:]]*(\$|[;&|)\"'\\\\]|--)|${SRV_B}(hugo|jekyll|ng|artisan|mkdocs) serve${SRV_E}|${SRV_B}rails s(erver)?${SRV_E}|manage\\.py runserver|${SRV_B}flask run${SRV_E}|${SRV_CMD}(uvicorn|gunicorn|nodemon|live-server|http-server|webpack-dev-server|browser-sync|fswatch|watch)${SRV_E}|-m http\\.server|${SRV_B}jupyter (notebook|lab)${SRV_E}|docker[- ]compose +up|--watch(All)?(=true)?${SRV_E}|${SRV_CMD}tail [^;&|]*(-[[:alpha:]]*[fF]|--follow)|${SRV_CMD}tsc [^;&|]*-w${SRV_E}"
is_server_cmd() {
  local c="$1" rc=1
  c=${c//\\n/ }; c=${c//\\t/ }  # JSON-escaped newlines/tabs are separators too
  shopt -s nocasematch
  [[ $c =~ $SERVER_CMD_RE ]] && rc=0
  shopt -u nocasematch
  return $rc
}

held=""; expired=""
hold_task() {  # <type> <id> <path> [max-hold-sec]
  local first line
  first=$(awk -F'\t' -v id="$2" '$3 == id { print $1; exit }' "$BG_MARKER" 2>/dev/null)
  [ -n "$first" ] || first=$NOW
  line="$first"$'\t'"$1"$'\t'"$2"$'\t'"$3"$'\n'
  if [ -n "${4:-}" ] && [ $((NOW - first)) -ge "$4" ]; then expired+="$line"; else held+="$line"; fi
}
shell_output() {  # <id> → output file: recorded at launch (older CLIs), else found by name
  local p
  p=$(grep -F "/$1.output" "$BGOUT_MARKER" 2>/dev/null | tail -1)
  # Current CLIs report no path at launch: Claude keeps task output under
  # <tmp>/claude-<uid>/<project>/<session>/tasks/<id>.output.
  [ -n "$p" ] || p=$(find "${KEEP_AWAKE_TASKS_ROOT:-${CLAUDE_CODE_TMPDIR:-/tmp}/claude-$(id -u)}/" \
    -maxdepth 4 -path "*/tasks/$1.output" 2>/dev/null | head -1)
  printf '%s' "$p"
}

listed=0
if [[ $HOOK_INPUT == *'"background_tasks":'* ]]; then
  tpath=$(printf '%s' "$HOOK_INPUT" | grep -oE '"transcript_path":"[^"]+"' | head -1 | sed -E 's/.*:"([^"]+)"/\1/')
  # Compact JSON, keys in schema order; strings escape quotes as \", so the
  # value pattern can't run past a string's end.
  TASK_RE='"id":"([^"]*)","type":"([^"]*)"'
  while IFS= read -r entry; do
    [[ $entry =~ $TASK_RE ]] || continue
    listed=1
    id=${BASH_REMATCH[1]}; type=${BASH_REMATCH[2]}
    case "$type" in
      subagent) hold_task subagent "$id" "${tpath:+${tpath%.jsonl}/subagents/agent-$id.jsonl}" ;;
      workflow|teammate) hold_task "$type" "$id" "" ;;
      shell)
        grep -qxF "monitor:$id" "$BGOUT_MARKER" 2>/dev/null && continue
        cmd=""
        [[ $entry == *'"command":"'* ]] && { cmd=${entry#*\"command\":\"}; cmd=${cmd%\"}; }
        is_server_cmd "$cmd" && continue
        hold_task shell "$id" "$(shell_output "$id")" "$BG_SHELL_MAX_HOLD_SEC"
        ;;
    esac
  done < <(printf '%s' "$HOOK_INPUT" | grep -oE '\{"id":"[^"]*","type":"[^"]*","status":"[^"]*"(,"description":"(\\.|[^"\\])*")?(,"command":"(\\.|[^"\\])*")?')
elif [ -e "$BGOUT_MARKER" ]; then
  # CLI without background_tasks: only shell tasks are known, live while their
  # output file is held open.
  while IFS= read -r task_out; do
    [[ $task_out == /*.output ]] || continue
    lsof "$task_out" >/dev/null 2>&1 || continue
    listed=1
    id=${task_out##*/}; id=${id%.output}
    hold_task shell "$id" "$task_out" "$BG_SHELL_MAX_HOLD_SEC"
  done < "$BGOUT_MARKER"
fi

# Atomic replace: the daemon reads the marker without the lock.
if [ -n "$held$expired" ]; then
  mkdir -p "$BG_DIR"
  printf '%s' "$held$expired" > "$BG_MARKER.tmp.$$" && mv -f "$BG_MARKER.tmp.$$" "$BG_MARKER"
else
  rm -f "$BG_MARKER"
fi
[ $listed -eq 1 ] || rm -f "$BGOUT_MARKER"  # nothing in flight → drop the id map
[ -n "$held" ] && exit 0  # background work still running → keep session; trap releases the lock

rm -f "$SESSIONS_DIR/$PARENT_PID"
rm -f "$PAUSED_DIR/$PARENT_PID"
rm -f "$TRANSCRIPTS_DIR/$PARENT_PID"
rm -f "$LIMIT_DIR/$PARENT_PID"

if ! has_live_sessions; then
  if [ -f "$DAEMON_PID_FILE" ]; then
    PID=$(cat "$DAEMON_PID_FILE" 2>/dev/null) || PID=""
    if [ -n "$PID" ]; then
      kill -TERM "$PID" 2>/dev/null || true
      pkill -P "$PID" 2>/dev/null || true  # Linux systemd-inhibit child sleep
    fi
    rm -f "$DAEMON_PID_FILE"
  fi
fi
