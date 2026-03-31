# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that prevents your computer from sleeping while Claude Code is working. Supports macOS, Linux, and Windows.

## Features

- Automatically activates when you submit a prompt or Claude uses a tool
- Per-session tracking — multiple Claude Code sessions are handled independently
- Auto-expires after 30 minutes of inactivity
- Cleans up on session end — no orphaned processes
- Cross-platform: macOS, Linux (systemd), Windows (Git Bash)

## Quick Start

Install from the Claude Code plugin marketplace:

```
claude plugin add claude-keep-awake
```

Or install manually:

```bash
git clone https://github.com/AxGord/claude-keep-awake.git
claude plugin add ./claude-keep-awake
```

## How It Works

The plugin uses Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to manage a platform-specific sleep inhibitor:

| Hook | Action |
|------|--------|
| `UserPromptSubmit` | Starts/refreshes sleep inhibitor (30 min timeout) |
| `PostToolUse` | Starts/refreshes sleep inhibitor (30 min timeout) |
| `Stop` | Kills inhibitor process and cleans up PID file |

Each session stores its inhibitor PID in `/tmp/claude-caffeinate-<session_id>.pid`. When a new prompt or tool use triggers the hook, any existing process is killed and a fresh 30-minute timer starts.

### Platform Details

| OS | Method | What it prevents |
|----|--------|-----------------|
| **macOS** | `caffeinate -dis` | Display, idle, and system sleep |
| **Linux** | `systemd-inhibit` (fallback: `gnome-session-inhibit`) | Idle and suspend |
| **Windows** | `SetThreadExecutionState` via PowerShell | Display and system sleep |

## Configuration

The default timeout is **1800 seconds** (30 minutes). To change it, edit `scripts/keep-awake.sh` and modify the `TIMEOUT` variable:

```bash
TIMEOUT=1800  # Change to your desired timeout in seconds
```

## Requirements

- **macOS** — no extra dependencies (`caffeinate` is built-in)
- **Linux** — `systemd-inhibit` (available on all systemd-based distros) or `gnome-session-inhibit`
- **Windows** — Git Bash or similar bash environment with access to `powershell.exe`

## License

[MIT](LICENSE)
