# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://code.claude.com/docs/en/overview) plugin that prevents your computer from sleeping while Claude Code is working. On **Apple Silicon** it keeps the Mac awake with the **lid closed**, without `sudo`, without an external display and without code-signing. Also supports macOS Intel, Linux and Windows.

## Features

- Activates on prompt submit / tool use, releases on session end
- **Releases while Claude waits for you** — permission prompts, `AskUserQuestion`, plan approval, `Esc`, API errors (per session; unless background work is still running)
- **Holds across a usage-limit stop** — keeps the Mac awake until the reset so Claude Code's auto-continue can fire, and re-prompts the session if it doesn't
- **Stays awake across background work** — async subagents, workflows and `run_in_background` builds/tests; servers and watchers never hold
- **Releases when the internet is gone** — macOS daemon lets the Mac sleep after 30 s offline, resumes instantly on reconnect
- **One shared daemon per machine** — sessions are reference-counted; self-monitoring covers crashes and hung CLIs
- **macOS Apple Silicon: stays awake with the lid closed** — no `sudo`, no code-signing, with audible Bottle/Submarine lid feedback
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

Four hook scripts register each Claude CLI session (keyed by its PID) with one shared per-machine daemon: `keep-awake.sh` on prompt/tool hooks, `pause-awake.sh` when Claude waits for you, `stop-awake.sh` on `Stop`, and `limit-awake.sh` on usage-limit stops. The daemon holds the OS sleep prevention while any live session is working and releases it when all are idle, offline or gone. On macOS it is a Swift binary (`IOPMAssertion` plus an IOKit clamshell selector); on Linux `systemd-inhibit`; on Windows `SetThreadExecutionState`.

Full details — hooks, pause/resume latency, background work, aborted turns, usage-limit stops, network loss, the daemon table, closed-lid internals, state files — in [docs/how-it-works.md](docs/how-it-works.md).

**Kill-switch**: create `~/.claude/keep-awake-state/disabled` to make the hooks a no-op (Mac sleeps normally); delete it to resume. Takes effect on the next hook in any active session.

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

## Requirements

- **macOS** — Xcode Command Line Tools for `swiftc` (`xcode-select --install`). Without it, falls back to plain `caffeinate` (no closed-lid support).
- **Linux** — `systemd-inhibit` (standard on systemd distros) or `gnome-session-inhibit`
- **Windows** — Git Bash with access to `powershell.exe`

## See also

- [claude-notify-sounds](https://github.com/AxGord/claude-notify-sounds) — sounds when Claude finishes, needs permission or hits a usage limit
- [Claude Workflow](https://axgord.github.io/claude-workflow/) — workflows for Claude Code agents: state machines, gates, a task queue, a shared thread pool and a live map

## License

[MIT](LICENSE)