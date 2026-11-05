# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that prevents your computer from sleeping while Claude Code is working. Supports macOS (including **closed-lid** keep-awake on Apple Silicon), Linux, and Windows.

## Features

- Activates on prompt submit / tool use, releases on session end
- **Releases while Claude waits for you** — a session blocked on a permission prompt, `AskUserQuestion`, plan approval, a turn you interrupted with `Esc`, or a turn stopped by an API error stops requesting wake (per-session: other working sessions still keep the Mac awake) — unless background work it launched is still running
- **Holds across a usage-limit stop** — when Claude Code's own `autoContinueAtUsageLimit` is on (the default), a 5-hour limit stop keeps the Mac awake until the reset so the CLI's built-in auto-continue can fire; if it doesn't, the plugin re-prompts the session itself. With the setting off the Mac sleeps as before
- **Stays awake across background work** — async subagents, workflows and `run_in_background` builds/tests outlive the turn (Claude's `Stop` fires while they still run); the session stays held until they finish — even if you walk away, and even after the 60 s idle notification. Servers and watchers (`npm run dev`, a process that keeps listening on a TCP port, `Monitor`) don't hold the Mac; a background shell process holds at most 1 h, agents as long as they work
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

1. **`scripts/keep-awake.sh`** — fires on every `UserPromptSubmit`, `PreToolUse`, and `PostToolUse` hook. Registers the current session in `~/.claude/keep-awake-state/sessions/<cli-pid>`, clears any pause marker for it, and starts a daemon if none is running. Sessions are keyed by the Claude CLI process PID (stable for the process lifetime), not `session_id` (which changes on `/clear`, `/compact`, resume — UUID keying leaked one file per session_id that `Stop` never reaped). A live PID alone isn't trusted: the OS can recycle a dead session's PID to an unrelated process, so every liveness check also confirms the PID is still a `claude` process (`…/claude` or, for a backgrounded session, the installer's versioned binary `…/claude/versions/<ver>`; overridable via `KEEP_AWAKE_PROC_NAME`) — otherwise such a phantom would pin the daemon forever. A `PostToolUse` of `Monitor` records its `taskId` as `monitor:<id>` in `~/.claude/keep-awake-state/bgout/<cli-pid>` (a Monitor is listed as a shell task at `Stop` and must never hold); on older CLIs a `run_in_background` `PostToolUse` also records the task's output-file path there.
2. **`scripts/pause-awake.sh`** — fires on the `Notification` hook (Claude needs a permission, or has been idle waiting for input ≥60s). `AskUserQuestion` blocks waiting for the user but (unlike permission prompts / plan approval) emits no `Notification` event, so `keep-awake.sh` inspects its stdin JSON on `PreToolUse` and execs `pause-awake.sh` inline when `tool_name` is `AskUserQuestion` — splitting it into a parallel matcher entry in `hooks.json` raced with `keep-awake.sh`'s marker-clear and never stuck. Writes `~/.claude/keep-awake-state/paused/<cli-pid>`, marking that this session is *not* working. The daemon stops preventing sleep only when **every** live session is idle — paused, or its turn aborted (see *Aborted turns* below); any session still working keeps the Mac awake. The next `keep-awake.sh` hook (resume) removes the marker.
3. **`scripts/stop-awake.sh`** — fires on the `Stop` hook. Unless background work the turn launched still runs (then it writes `bg/<cli-pid>` and leaves the session registered until completion revives Claude — see *Background work*), removes the session file (and its pause and transcript markers). If it was the last live session, terminates the daemon.
4. **`scripts/limit-awake.sh`** — fires on the `StopFailure` hook (a turn ended on an API error; no `Stop` fires). Only a `rate_limit` stop matters: if Claude Code's `autoContinueAtUsageLimit` is not explicitly `false` in the settings hierarchy, it parses the reset clock time from the rendered limit message and records a pending hold in `~/.claude/keep-awake-state/limit/<cli-pid>` (reset epoch, this session's messaging socket and token) for the daemon to act on — see *Usage-limit stops* below. Every other error, a weekly limit, or the setting off → no marker, the Mac sleeps as before.

**Pause/resume latency**: pausing is immediate on a permission prompt or `AskUserQuestion`, ~60s on pure idle (Claude Code's built-in idle-notification threshold) — after which the OS's normal sleep timers apply. Resuming is ≤1s (the daemon polls at 1 Hz) after the first hook fires on your answer; pauses shorter than a minute never cause an actual sleep since idle-sleep timers are minutes.

**Background work**: when Claude launches async work — a subagent, a workflow, a `run_in_background` shell task — and has nothing left to do, the turn ends and `Stop` fires *while the work still runs*; the work's completion revives Claude, and that revival turn ends with another `Stop`. So `stop-awake.sh` decides on every `Stop` from the payload's `background_tasks` — the CLI's own list of in-flight work — whether to keep the session registered, and writes the work worth holding to `bg/<cli-pid>` (`first_seen` / type / id / path). Held: `subagent`, `workflow` and `teammate` tasks (they always finish; no age cap), and `shell` tasks unless they are a `Monitor` (its `taskId` is recorded at `PostToolUse` — a Monitor reports as a shell task) or their command looks like a server or watcher (runner-bound: `npm|pnpm|yarn|bun [run] dev|start|serve|watch|preview`, `vite`, `next dev`, `rails s`, `manage.py runserver`, `uvicorn`, `nodemon`, `http.server`, `docker compose up`, `--watch`, `tail -f`, `tsc -w`, … — a bare word such as `git checkout dev` never matches). Other task types (MCP tasks, remote sessions, `monitor`) are not held. The macOS daemon re-checks every 15 s: a shell task through its output file, which the task's own processes hold open while it runs — no holder left → finished; a holder listening on TCP for 30 s → a server the command patterns missed (a test binding a port briefly is not); a subagent through its transcript (`…/<session>/subagents/agent-<id>.jsonl`) — its final assistant text, an API error, an interrupt, or 30 min of silence → done. A shell task holds at most **1 h** since first seen — a background process running that long is suspect and must not pin the Mac; the expired entry keeps its original `first_seen`, so the cap doesn't re-arm on the next `Stop`. While `bg/<cli-pid>` holds, the daemon treats the session as active over the `paused` marker and the aborted-turn rule: the 60 s idle `Notification` fires regardless of running tasks, and the work runs whether or not Claude waits for the user. Workflows and teammates have no liveness probe: if the revival turn after one finishes ends without a `Stop` (`Esc`, a pending prompt), the stale entry holds until the next `Stop` or the 2 h hook-idle watchdog. A shell task's output file is found under Claude's tmp dir (`<tmp>/claude-<uid>/<project>/<session>/tasks/<id>.output`) — current CLIs report only `backgroundTaskId` at launch. A CLI without `background_tasks` (< 2.1.145) falls back to holding while a shell output file recorded at launch (older CLIs reported its path) is still open. Two earlier designs leaked: clearing the marker on `UserPromptSubmit` pinned the Mac until the 2 h watchdog (the revival fires no `UserPromptSubmit`), and tracking only `run_in_background` shell output files missed async subagents entirely — the Mac slept while they worked.

**Aborted turns**: two turn endings fire *no* `Stop` and *no* `Notification` — so the session would stay registered and unpaused and pin the Mac until the 2 h watchdog. Pressing `Esc` records the abort in the session transcript as a final `[Request interrupted by user]` (or `…for tool use]`) message. A usage-limit or API-error stop (e.g. *"You've hit your session limit"*, 429, overloaded) appends a synthetic assistant message whose transcript line carries `"isApiErrorMessage": true` — matched by that flag, not the banner text, so every error wording counts. `keep-awake.sh` stores each session's transcript path in `~/.claude/keep-awake-state/transcripts/<cli-pid>`, and the daemon's 1 Hz poll treats a session as idle when its transcript's last message is either marker — releasing within ~1 s (unless background work it launched still holds — see *Background work*). A genuinely running foreground tool is never mistaken for this: its `tool_use` entry is written at tool *start*, so a live tool leaves a trailing `tool_use` with no result (never an abort marker) and the Mac stays awake. The next prompt re-registers the session.

**Usage-limit stops**: a 5-hour limit stop is the one aborted turn worth *not* releasing on. Claude Code (≥ 2.1.234) can wait out the reset and re-prompt itself (`autoContinueAtUsageLimit`, on by default) — but only if the machine is still awake, and its arming is known to be unreliable. `scripts/limit-awake.sh` runs on the `StopFailure` hook (fires *instead of* `Stop` when a turn ends on an API error); for `error: rate_limit` it reads the setting with Claude Code's precedence (managed → project local → project → user; absent = on), parses the reset clock time from the rendered message (`resets 4:30pm (Asia/Nicosia)`), and writes `~/.claude/keep-awake-state/limit/<cli-pid>` = reset epoch / messaging socket / token. While that marker is pending the daemon treats the session as active — over the `paused` marker (the 60 s idle `Notification` fires after a limit stop), over the `isApiErrorMessage` transcript rule, and past the 2 h hook-idle watchdog (bounded at 6 h). Any hook firing removes the marker, and so does any newer transcript entry (a local command such as `/rate-limit-options` or `/low-priority`, a typed prompt, the CLI's own auto-continue), so a resume — or an explicit "don't continue" — ends the hold naturally; only `Esc` during the CLI's own wait leaves no trace and is not detected. If the marker is still there 90 s after the reset, the CLI did not resume: the daemon connects to the session's messaging socket (`CLAUDE_CODE_MESSAGING_SOCKET` / `CLAUDE_CODE_MESSAGING_TOKEN`, the channel Claude Code uses for messages between sessions — undocumented, peer protocol 1, may change with CLI versions) and sends a *continue* prompt; the session picks it up as a message from another session and resumes the task. Any failure just releases the Mac as before. Weekly limits (`resets Sep 9 at 3pm`), resets more than 6 h away, and every other error type are not held.

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
│   ├── <cli-pid>           # background work holding the session: first_seen / type / id / path (shell output file, subagent transcript)
│   └── ...
├── bgout/
│   ├── <cli-pid>           # output-file paths of that session's background shell tasks (id → file), `monitor:<id>` for Monitors
│   └── ...
├── transcripts/
│   ├── <cli-pid>           # path to that session's transcript (daemon reads its tail for aborted turns: Esc / limit / API error)
│   └── ...
├── limit/
│   ├── <cli-pid>           # pending usage-limit hold: reset epoch / messaging socket / token (daemon re-prompts at reset+90s)
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
