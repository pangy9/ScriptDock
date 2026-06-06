# ScriptDock

[简体中文](README.zh-CN.md)

ScriptDock is a macOS menu bar app that gives you a single place to register, monitor, and control all your local long-running scripts — dev servers, SSH tunnels, sync jobs, bots, anything that should stay alive in the background.

![Dashboard](assets/screenshots/dashboard.png)

![Menu Bar](assets/screenshots/菜单栏.png)

![Edit Task](assets/screenshots/edit_task.png)

## Why ScriptDock

If you run local scripts that need to stay alive, you have probably tried some combination of:

- `nohup`, `disown`, `&` in a terminal you then accidentally close
- `tmux` / `screen` sessions you forget about and can never find
- `launchd` `.plist` files you hand-edit and then `launchctl load` over and over
- a handful of terminal tabs, each running something you need to keep an eye on

The problems are always the same: you can not see what is running, you can not find the logs when something breaks, you can not tell which process grabbed port 3000, and restarting a stopped service means re-typing or re-finding the right command.

ScriptDock fixes this by giving every script a home in a persistent, searchable dashboard where you can start, stop, restart, and read logs without leaving the app.

## Highlights

- **Process supervisor** — ScriptDock manages child processes directly via `Foundation.Process`. Daemon tasks auto-restart on crash while ScriptDock is running; one-shot tasks run once and report their exit code. Run-at-load tasks recover when ScriptDock starts.
- **Real-time dashboard** — sidebar groups tasks by status (Running / Stopped); select any task to see live logs, port usage, and PID in the detail panel.
- **Inline controls** — play, stop, and restart buttons directly in the sidebar. No context-switching.
- **Log viewer** — ring-buffered stdout and stderr streams with live tail, search, and stream switching. Timestamps are injected at the pipe level — no wrapper scripts, no buffering issues.
- **Port monitoring** — automatically detects ports from `openURL`, `--port` flags, SSH `-L` forwards, and `PORT` environment variables. One click to kill a process blocking a port you need.
- **Task modes** — choose between *Daemon* (auto-restart on crash while ScriptDock is running) and *One-shot* (run once, show exit code).
- **MCP server** — built-in Model Context Protocol server lets AI assistants (Claude Code, Cursor) list your processes, read logs, start and stop tasks, and register new ones without you leaving the editor.
- **Safe by default** — commands are explicit argv arrays (no shell injection surface), task IDs are restricted to safe characters, everything runs as your user with no `sudo`.

## Getting Started

### Requirements

- macOS 14.0+

### Build from Source

```bash
git clone https://github.com/pangy9/ScriptDock.git
cd ScriptDock
make
open ScriptDock.app
```

On first launch, ScriptDock creates its config and log directories:

```text
~/Library/Application Support/ScriptDock/scripts.json
~/Library/Application Support/ScriptDock/logs/
```

### Download

Download `ScriptDock.zip` from the [latest release](https://github.com/pangy9/ScriptDock/releases/latest), unzip, and move to `/Applications`.

Since the app is not signed with an Apple Developer certificate, macOS will block the first open. To bypass:

```bash
xattr -cr /Applications/ScriptDock.app
```

Then open the app normally.

## Configuration

Edit `scripts.json` (or use the built-in task editor) to add tasks:

```json
{
  "tasks": [
    {
      "id": "dev-server",
      "name": "Dev Server",
      "programArguments": ["/usr/local/bin/node", "server.js", "--port", "3000"],
      "workingDirectory": "/Users/you/projects/my-app",
      "mode": "daemon",
      "runAtLoad": true,
      "keepAlive": true,
      "keepRunningOnQuit": false,
      "ports": [3000],
      "environment": { "NODE_ENV": "development" }
    },
    {
      "id": "api-health",
      "name": "API Health Check",
      "programArguments": ["curl", "-s", "https://api.example.com/health"],
      "mode": "oneshot"
    }
  ]
}
```

Each task uses an argv array. `mode` can be `daemon` (auto-restart on crash while ScriptDock is running) or `oneshot` (run once). For backward compatibility, tasks without `mode` infer it from `keepAlive`/`runAtLoad`. ScriptDock sends a stop signal to running tasks when you quit the app unless `keepRunningOnQuit` is set to `true`. Reload config from the menu bar or Dashboard at any time.

## MCP Integration

ScriptDock ships an MCP server so AI coding assistants can manage your processes directly.

### Claude Code

```bash
claude mcp add scriptdock -- /Applications/ScriptDock.app/Contents/MacOS/scriptdock-mcp
```

### Cursor / Other MCP Clients

```json
{
  "mcpServers": {
    "scriptdock": {
      "command": "/Applications/ScriptDock.app/Contents/MacOS/scriptdock-mcp"
    }
  }
}
```

### Available Tools

| Tool | Description |
| --- | --- |
| `list_processes` | List all processes with status |
| `start_process` | Start a process |
| `stop_process` | Stop a running process |
| `restart_process` | Restart a process |
| `get_process_status` | Detailed status of a process |
| `get_process_logs` | Read stdout/stderr logs |
| `check_ports` | Check which processes use specified ports |
| `kill_port_blockers` | Kill processes blocking specified ports |
| `register_process` | Register a new process via MCP |

## Privacy

ScriptDock runs entirely on your Mac. It does not send task definitions, logs, environment variables, or any other data to external services. The supervisor API binds only to `127.0.0.1:26216`.

## Support

If ScriptDock helps you, a star or donation helps support continued development:

<a href="https://paypal.me/pangy9">
  <img src="https://img.shields.io/badge/PayPal-Donate-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate with PayPal">
</a>

<img src="assets/screenshots/wechat_sponsor.jpg" width="300" alt="WeChat Sponsor">

## License

MIT
