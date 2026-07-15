# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that prevents your computer from sleeping while Claude Code is working. Supports macOS (including **closed-lid** keep-awake on Apple Silicon), Linux, and Windows.

## Features

- Activates on prompt submit / tool use, releases on session end
- **Releases while Claude waits for you** — a session blocked on a permission prompt, `AskUserQuestion`, plan approval, a turn you interrupted with `Esc`, or a turn stopped by a usage limit / API error stops requesting wake (per-session: other working sessions still keep the Mac awake)
- **Stays awake across background tasks** — a tool launched with `run_in_background` outlives the turn (Claude's `Stop` fires while it still runs); the session stays registered until the task's output file is closed (`lsof`), so the Mac isn't released mid-task — even if you walk away without prompting again
- **Releases when the internet is gone** — macOS daemon watches the default route via `NWPathMonitor`; after 30 s offline the Mac is allowed to sleep (Claude can't reach the API anyway). Resumes instantly on reconnect.
- **One shared daemon per machine** — multiple Claude Code sessions reference-count automatically
- **macOS Apple Silicon: stays awake with the lid closed** without an external display, without `sudo`, without code-signing
- Audible lid feedback on macOS — Bottle on close, Submarine on open (only while keep-awake is actively overriding the lid; silent when the Mac is taking the normal sleep path)
- Self-monitor: daemon exits if all registered sessions die (covers Claude Code crashes), or if no hook fires for 2h (covers a hung-but-alive CLI)
- Cross-platform: macOS, Linux (systemd / gnome-session), Windows (Git Bash + PowerShell)

## Quick Start

Install from the official [community marketplace](https://github.com/anthropics/claude-plugins-community):

```bash
claude plugin marketplace add anthropics/claude-plugins-community
claude plugin install keep-awake@claude-community
```

(or inside Claude Code: `/plugin install keep-awake@claude-community`)

Or straight from this repo:

```bash
claude plugin marketplace add AxGord/claude-keep-awake
claude plugin install keep-awake@claude-keep-awake
```

## How It Works

Three coordinated pieces:

1. **`scripts/keep-awake.sh`** — fires on every `UserPromptSubmit`, `PreToolUse`, and `PostToolUse` hook. Registers the current session in `~/.claude/keep-awake-state/sessions/<cli-pid>`, clears any pause marker for it, and starts a daemon if none is running. Sessions are keyed by the Claude CLI process PID (stable for the process lifetime), not `session_id` (which changes on `/clear`, `/compact`, resume — UUID keying leaked one file per session_id that `Stop` never reaped). A live PID alone isn't trusted: the OS can recycle a dead session's PID to an unrelated process, so every liveness check also confirms the PID is still a `claude` process (overridable via `KEEP_AWAKE_PROC_NAME`) — otherwise such a phantom would pin the daemon forever. A `PostToolUse` carrying `run_in_background:true` appends the task's output-file path (from the tool response) to `~/.claude/keep-awake-state/bg/<cli-pid>`, recording a task that will outlive the turn; `stop-awake.sh` probes those paths with `lsof` to tell which are still running.
2. **`scripts/pause-awake.sh`** — fires on the `Notification` hook (Claude needs a permission, or has been idle waiting for input ≥60s). `AskUserQuestion` blocks waiting for the user but (unlike permission prompts / plan approval) emits no `Notification` event, so `keep-awake.sh` inspects its stdin JSON on `PreToolUse` and execs `pause-awake.sh` inline when `tool_name` is `AskUserQuestion` — splitting it into a parallel matcher entry in `hooks.json` raced with `keep-awake.sh`'s marker-clear and never stuck. Writes `~/.claude/keep-awake-state/paused/<cli-pid>`, marking that this session is *not* working. The daemon stops preventing sleep only when **every** live session is idle — paused, or its turn aborted (see *Aborted turns* below); any session still working keeps the Mac awake. The next `keep-awake.sh` hook (resume) removes the marker.
3. **`scripts/stop-awake.sh`** — fires on the `Stop` hook. Unless the session has a pending background-task marker (then it's left registered until completion revives Claude), removes the session file (and its pause and transcript markers). If it was the last live session, terminates the daemon.

**Pause/resume latency**: pausing is immediate on a permission prompt or `AskUserQuestion`, ~60s on pure idle (Claude Code's built-in idle-notification threshold) — after which the OS's normal sleep timers apply. Resuming is ≤1s (the daemon polls at 1 Hz) after the first hook fires on your answer; pauses shorter than a minute never cause an actual sleep since idle-sleep timers are minutes.

**Background tasks**: when Claude launches a tool with `run_in_background` and then has nothing left to do, the turn ends and `Stop` fires *while the task is still running* — without the `bg` marker the session would be unregistered and (if it were the last one) the daemon killed, letting the Mac sleep mid-task. Claude Code exposes no per-task completion hook, so we infer liveness from the task's output file: Claude holds it open for the task's whole lifetime, so `lsof` on it is true exactly while the task runs. `keep-awake.sh` records one output path per line at `PostToolUse`; on each `Stop`, `stop-awake.sh` `lsof`-probes them, prunes the finished ones, and keeps the session registered only while at least one is still held. The session releases on the `Stop` that follows the last task's completion (the completion revives Claude; that revival turn ends with a `Stop`). The earlier design cleared the marker on `UserPromptSubmit` instead — but the revival fires no `UserPromptSubmit`, so a user who walked away after launching a task pinned the Mac awake until the 2 h watchdog. Because each task is tracked by its own file, concurrent tasks are handled precisely (no flag-vs-counter loss); the watchdog remains the backstop for the rare case where no post-completion `Stop` ever fires.

**Aborted turns**: two turn endings fire *no* `Stop` and *no* `Notification` — so the session would stay registered and unpaused and pin the Mac until the 2 h watchdog. Pressing `Esc` records the abort in the session transcript as a final `[Request interrupted by user]` (or `…for tool use]`) message. A usage-limit or API-error stop (e.g. *"You've hit your session limit"*, 429, overloaded) appends a synthetic assistant message whose transcript line carries `"isApiErrorMessage": true` — matched by that flag, not the banner text, so every error wording counts. `keep-awake.sh` stores each session's transcript path in `~/.claude/keep-awake-state/transcripts/<cli-pid>`, and the daemon's 1 Hz poll treats a session as idle when its transcript's last message is either marker — releasing within ~1 s. A genuinely running foreground tool is never mistaken for this: its `tool_use` entry is written at tool *start*, so a live tool leaves a trailing `tool_use` with no result (never an abort marker) and the Mac stays awake. The next prompt re-registers the session.

**Network-loss release** (macOS Swift daemon only): the daemon registers an `NWPathMonitor` for the default route. When the route goes unsatisfied (Wi-Fi off, Ethernet unplugged, no usable interface) the daemon waits 30 s — to ride out brief flaps like Wi-Fi roam or captive-portal reauth — then releases assertions and re-enables clamshell sleep, exactly as if every session had paused. On the next satisfied path it re-acquires immediately. Holding sleep-prevention while Claude can't reach the API would just burn battery, so this trades a brief offline grace for letting the Mac sleep when it should.

**Kill-switch**: create `~/.claude/keep-awake-state/disabled` to make the hooks a no-op (Mac sleeps normally); delete it to resume. Takes effect on the next hook in any active session.

The daemon is platform-specific:

| OS | Daemon | What it prevents |
|----|--------|------------------|
| **macOS Apple Silicon / Intel** | Swift binary compiled from `src/keep-awake-daemon.swift` | `IOPMAssertion` (idle/display/system) + IOKit selector 12 (`kPMSetClamshellSleepState`) → blocks both idle sleep and lid-close sleep |
| **macOS (no Xcode CLT)** | Fallback: `caffeinate -dis` | Idle/display/system sleep only; **lid-close still triggers DarkWake** |
| **Linux** | `systemd-inhibit --what=sleep:idle` (fallback: `gnome-session-inhibit`) | Idle and suspend |
| **Windows** | `SetThreadExecutionState` via PowerShell | Display and system sleep |

### Closed-lid keep-awake on macOS

The Swift daemon uses an undocumented but publicly accessible IOKit selector (`kPMSetClamshellSleepState = 12` on `IOPMrootDomain`). Setting it to `1` makes the kernel ignore the lid-close event, keeping the system **fully awake** instead of entering DarkWake. Verified on Apple Silicon + macOS Sequoia, on both AC and battery, without any external display.

**AC↔battery transitions**: the dark→full wake cycle triggered by plugging or unplugging power invalidates the clamshell-disable flag (Apple's own pmconfigd re-evaluates it on full wake). The daemon defends with three layers:
- `IORegisterForSystemPower` callback: on `kIOMessageCanSystemSleep` issues `IOCancelPowerChange` (active veto) while sleep-prevention is held — or `IOAllowPowerChange` when every session is paused; on `kIOMessageSystemHasPoweredOn` re-applies assertions and selector 12 (only if still held)
- `IOPSCreateLimitedPowerNotification` callback: on every AC↔battery edge re-applies state
- 30s heartbeat: re-issues selector 12 as a safety net

Main loop is `CFRunLoopRun()` (not `dispatchMain()`) so CFRunLoop sources used by these IOKit notifications actually fire.

**Known limitation — AC-plug forced sleep on Apple Silicon**: when AC is plugged in while the lid is closed, macOS schedules a brief forced sleep (~5s) that bypasses all userspace sleep-prevention paths. The kernel sends `kIOMessageSystemWillSleep` directly — there is no `kIOMessageCanSystemSleep` to veto. No IOPMAssertion type, selector 12, `IOPMConnectionCreate`, or `pmset acwake` setting prevents this on AS. The only known workaround is `sudo pmset -a disablesleep 1` (root-only) — used by Amphetamine's "Power Protect" via a passwordless sudoers fragment. This plugin keeps the no-root, no-entitlement design and auto-recovers via `kIOMessageSystemHasPoweredOn` re-apply; the brief micro-sleep is unavoidable.

To warn the user *before* they close the lid in this unsafe window, the daemon writes `~/.claude/keep-awake-state/lid-unsafe-until` (UNIX timestamp) on AC plug-in and removes it when full wake completes. Use the `scripts/statusline-keep-awake.sh` snippet in your Claude Code statusLine to display a countdown — see "Statusline integration" below.

When you close the lid **with keep-awake active**:
- The built-in display brightness is set to 0 via the private `DisplayServices` framework (backlight off)
- The system stays at full clock; Claude Code processes do not get throttled
- An audible **Bottle** chime confirms the keep-awake is active
- On open, **Submarine** chime confirms normal operation resumed; brightness fades back to its saved value over ~500ms (minimum restore floor 0.05 if saved was lower)

When you close the lid **while keep-awake is released** (no active session, or network has been offline >30 s), the daemon skips the chime and the brightness override — the Mac takes the normal sleep path and you won't hear anything.

If `swiftc` is not available, the plugin falls back to plain `caffeinate -dis` — that still prevents idle sleep, but lid-close on Apple Silicon will throw the system into DarkWake (network limited, processes throttled).

### State files

```
~/.claude/keep-awake-state/
├── daemon.pid              # current daemon PID
├── disabled                # optional kill-switch; if present, hooks no-op
├── lid-unsafe-until        # UNIX timestamp; present briefly after AC plug-in
├── sessions/
│   ├── <cli-pid>           # Claude CLI process PID, one file per live CLI process
│   └── ...
├── paused/
│   ├── <cli-pid>           # present while that session is blocked waiting for the user
│   └── ...
├── bg/
│   ├── <cli-pid>           # output-file paths of run_in_background tasks still outliving the turn
│   └── ...
├── transcripts/
│   ├── <cli-pid>           # path to that session's transcript (daemon reads its tail for aborted turns: Esc / limit / API error)
│   └── ...
└── .lock                   # atomic mkdir lock for state mutations
```

### Statusline integration (optional)

Show a countdown in your Claude Code statusLine while AC-plug forced sleep is pending:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/keep-awake/scripts/statusline-keep-awake.sh"
  }
}
```

Outputs `⚠ Don't close lid: 12s` while the unsafe window is active, nothing otherwise. To combine with an existing statusline, call both commands and concatenate their output.

Log: `/tmp/keep-awake-daemon.log` (truncated on each daemon restart).

## Requirements

- **macOS** — Xcode Command Line Tools for `swiftc` (`xcode-select --install`). Without it, falls back to plain `caffeinate` (no closed-lid support).
- **Linux** — `systemd-inhibit` (standard on systemd distros) or `gnome-session-inhibit`
- **Windows** — Git Bash with access to `powershell.exe`

## License

[MIT](LICENSE)
