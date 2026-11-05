# Sourced by the hook scripts: CLI process identity, shared so it can't drift.
# Sets SESSION_PROC_NAME, defines session_pid_live, and sets PARENT_PID to the
# Claude CLI PID that sessions are keyed by (session_id is unstable: it changes
# on /clear, /compact, resume; the CLI PID is stable for its whole lifetime).

# A session PID counts as live only if the process exists AND is still a
# `claude` process. A bare kill -0 also passes when the OS recycles a dead
# session's PID to an unrelated process (observed: AudioComponentRegistrar) —
# that phantom would otherwise keep the daemon awake forever. Process name is
# overridable (KEEP_AWAKE_PROC_NAME) for tests and non-native installs.
# A backgrounded session runs straight from the installer's versioned binary
# (…/claude/versions/<ver>) rather than via the `claude` symlink — same CLI.
# macOS `comm` is the full exe path; Linux `comm` is the bare name, so such a
# session shows comm=<ver> there — match its /proc exe path instead.
SESSION_PROC_NAME="${KEEP_AWAKE_PROC_NAME:-claude}"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Git Bash/MSYS can't see native processes: no kill -0, no `ps -o`, no /proc
    # entry. The CLI PID here is a Windows PID (CLAUDE_PID); `ps -W` lists native
    # processes with their WINPID (column 4) and exe path. One `ps -W` per check.
    session_pid_live() {
      [ -n "$1" ] || return 1
      ps -W 2>/dev/null | awk -v w="$1" -v n="$SESSION_PROC_NAME" '
        $4 == w {
          c = tolower($0); n = tolower(n)
          if (c ~ ("[\\\\/]" n "(\\.exe)?$") || c ~ ("[\\\\/]" n "[\\\\/]versions[\\\\/]")) f = 1
        }
        END { exit !f }'
    }
    ;;
  *)
    session_pid_live() {
      local pid="$1"
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
      case "$(ps -p "$pid" -o comm= 2>/dev/null)" in
        */"$SESSION_PROC_NAME"|"$SESSION_PROC_NAME"|*/"$SESSION_PROC_NAME"/versions/*) return 0 ;;
      esac
      case "$(readlink "/proc/$pid/exe" 2>/dev/null)" in
        */"$SESSION_PROC_NAME"/versions/*) return 0 ;;
      esac
      return 1
    }
    ;;
esac

# The CLI exports its own PID to hooks as CLAUDE_PID (on Windows, the Windows
# PID of claude.exe) — verified on macOS, Linux and Windows with 2.1.318.
# Fallback for CLIs without it: the hook's parent. Claude runs a hook as
# `/bin/sh -c '<command>'`; bash-as-sh (macOS, Fedora, Arch) execs the single
# command, so PPID is the CLI, but dash (Debian/Ubuntu) forks it, so PPID is a
# transient `sh` — step over exactly that one shell. (On Windows the fallback is
# hopeless: a hook started by native claude.exe has PPID 1.)
if [ -n "${CLAUDE_PID:-}" ]; then
  PARENT_PID="$CLAUDE_PID"
else
  PARENT_PID="${PPID:-$$}"
  case "$(ps -p "$PARENT_PID" -o comm= 2>/dev/null)" in
    sh|dash|*/sh|*/dash)
      _cli_pid=$(ps -p "$PARENT_PID" -o ppid= 2>/dev/null | tr -d ' ')
      session_pid_live "$_cli_pid" && PARENT_PID="$_cli_pid"
      unset _cli_pid
      ;;
  esac
fi
