# claude-keep-awake

[![npm version](https://img.shields.io/npm/v/claude-keep-awake.svg)](https://www.npmjs.com/package/claude-keep-awake)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that prevents your Mac from sleeping while Claude Code is working. Uses macOS `caffeinate` to keep display, disk, and system awake during active sessions.

## Features

- Automatically activates when you submit a prompt or Claude uses a tool
- Per-session tracking — multiple Claude Code sessions are handled independently
- Auto-expires after 30 minutes of inactivity
- Cleans up on session end — no orphaned processes

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

The plugin uses Claude Code [hooks](https://docs.anthropic.com/en/docs/claude-code/hooks) to manage the macOS `caffeinate` utility:

| Hook | Action |
|------|--------|
| `UserPromptSubmit` | Starts/refreshes `caffeinate` (30 min timeout) |
| `PostToolUse` | Starts/refreshes `caffeinate` (30 min timeout) |
| `Stop` | Kills `caffeinate` and cleans up PID file |

Each session stores its `caffeinate` PID in `/tmp/claude-caffeinate-<session_id>.pid`. When a new prompt or tool use triggers the hook, any existing process is killed and a fresh 30-minute timer starts.

## Configuration

The default timeout is **1800 seconds** (30 minutes). To change it, edit `scripts/keep-awake.sh` and modify the `-t` value:

```bash
caffeinate -dis -t 1800  # Change 1800 to your desired timeout in seconds
```

Flags used:
- `-d` — prevent display sleep
- `-i` — prevent idle sleep
- `-s` — prevent system sleep

## Requirements

- macOS (uses `caffeinate`, which is built into macOS)

## License

[MIT](LICENSE)
