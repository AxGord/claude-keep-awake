# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that prevents your computer from sleeping while Claude Code is working. Supports macOS (including **closed-lid** keep-awake on Apple Silicon), Linux, and Windows.

## Features

- Activates on prompt submit / tool use, releases on session end
- **One shared daemon per machine** — multiple Claude Code sessions reference-count automatically
- **macOS Apple Silicon: stays awake with the lid closed** without an external display, without `sudo`, without code-signing
- Audible lid feedback on macOS — Submarine on close, Bottle on open
- Self-monitor: daemon exits if all registered sessions die (covers Claude Code crashes)
- Cross-platform: macOS, Linux (systemd / gnome-session), Windows (Git Bash + PowerShell)

## Quick Start

```
claude plugin add claude-keep-awake
```

Or manually:

```bash
git clone https://github.com/AxGord/claude-keep-awake.git
claude plugin add ./claude-keep-awake
```

## How It Works

Two coordinated pieces:

1. **`scripts/keep-awake.sh`** — fires on every `UserPromptSubmit` and `PostToolUse` hook. Registers the current session in `~/.claude/keep-awake-state/sessions/<session_id>` and starts a daemon if none is running.
2. **`scripts/stop-awake.sh`** — fires on the `Stop` hook. Removes the session file. If it was the last live session, terminates the daemon.

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
- `IORegisterForSystemPower` callback: on `kIOMessageCanSystemSleep` issues `IOCancelPowerChange` (active veto); on `kIOMessageSystemHasPoweredOn` re-applies assertions and selector 12
- `IOPSCreateLimitedPowerNotification` callback: on every AC↔battery edge re-applies state
- 30s heartbeat: re-issues selector 12 as a safety net

Main loop is `CFRunLoopRun()` (not `dispatchMain()`) so CFRunLoop sources used by these IOKit notifications actually fire.

**Known limitation — AC-plug forced sleep on Apple Silicon**: when AC is plugged in while the lid is closed, macOS schedules a brief forced sleep (~5s) that bypasses all userspace sleep-prevention paths. The kernel sends `kIOMessageSystemWillSleep` directly — there is no `kIOMessageCanSystemSleep` to veto. No IOPMAssertion type, selector 12, `IOPMConnectionCreate`, or `pmset acwake` setting prevents this on AS. The only known workaround is `sudo pmset -a disablesleep 1` (root-only) — used by Amphetamine's "Power Protect" via a passwordless sudoers fragment. This plugin keeps the no-root, no-entitlement design and auto-recovers via `kIOMessageSystemHasPoweredOn` re-apply; the brief micro-sleep is unavoidable.

To warn the user *before* they close the lid in this unsafe window, the daemon writes `~/.claude/keep-awake-state/lid-unsafe-until` (UNIX timestamp) on AC plug-in and removes it when full wake completes. Use the `scripts/statusline-keep-awake.sh` snippet in your Claude Code statusLine to display a countdown — see "Statusline integration" below.

When you close the lid:
- The built-in display brightness is set to 0 via the private `DisplayServices` framework (backlight off)
- The system stays at full clock; Claude Code processes do not get throttled
- An audible **Submarine** chime confirms the keep-awake is active
- On open, **Bottle** chime confirms normal operation resumed; brightness fades back to its saved value over ~500ms (minimum restore floor 0.05 if saved was lower)

If `swiftc` is not available, the plugin falls back to plain `caffeinate -dis` — that still prevents idle sleep, but lid-close on Apple Silicon will throw the system into DarkWake (network limited, processes throttled).

### State files

```
~/.claude/keep-awake-state/
├── daemon.pid              # current daemon PID
├── lid-unsafe-until        # UNIX timestamp; present briefly after AC plug-in
├── sessions/
│   ├── <session-id>        # Claude Code parent PID, one file per active session
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
