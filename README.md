# noctalia-ai-monitor

A [noctalia-shell](https://github.com/noctalia) plugin that monitors Claude Code sessions and lets you approve or deny permission requests directly from the desktop shell.

## Screenshot

<!-- TODO: Add screenshot here -->

## Features

- **Session monitoring** — tracks all active Claude Code sessions and their current phase (idle, processing, waiting for input, compacting, waiting for approval, ended)
- **Permission approval** — approve or deny Claude Code tool-use permission requests from a shell panel without switching to the terminal
- **Bar widget** — compact status button in the system bar; pulses amber when approval is needed
- **Toast notifications** — desktop notification when a permission request arrives
- **Terminal focus** — jump directly to the terminal running the relevant Claude Code session (niri compositor, Linux only)
- **Tool input preview** — human-readable summary of what the pending tool call will do (Bash command, file path, edit diff, web search query, etc.)
- **Auto-restart** — bridge process restarts automatically with exponential backoff on crash
- **Auto-install hooks** — installs Claude Code hooks on plugin startup

## Requirements

- [noctalia-shell](https://github.com/noctalia) >= 3.7.0
- Python 3.10+
- Claude Code with hooks support
- Linux (niri compositor required for terminal-focus feature)

## Installation

### 1. Install the plugin

Copy the plugin directory into the noctalia-shell plugins directory:

```bash
cp -r ai-monitor ~/.config/quickshell/noctalia-shell/plugins/
```

Or symlink it for development:

```bash
ln -s /path/to/ai-monitor ~/.config/quickshell/noctalia-shell/plugins/ai-monitor
```

### 2. Enable the plugin in noctalia-shell

Open the shell settings, navigate to **Plugins**, and enable **AI Monitor**.

### 3. Install Claude Code hooks

Hooks are installed automatically when the plugin starts (if **Auto-install hooks** is enabled in settings). To install manually, right-click the bar widget and choose **Install Hooks**, or click **Reinstall Hooks** in the plugin settings panel.

The hook file is copied to `~/.claude/hooks/ai-monitor-hook.py` and the following events are registered in `~/.claude/settings.json`:

| Event | Timeout |
|---|---|
| SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop, SubagentStop, PreCompact, SessionEnd | 5 s |
| PermissionRequest | 300 s |

## Configuration

Open the plugin settings from the bar widget (right-click → **Plugin Settings**) or from the panel header.

| Setting | Default | Description |
|---|---|---|
| Python command | `python3` | Executable used to run `bridge.py` |
| Socket path | _(empty)_ | Unix socket path; defaults to `$XDG_RUNTIME_DIR/ai-monitor.sock` |
| Notify on approval | `true` | Show a toast notification when a permission request arrives |
| Auto-install hooks | `true` | Install Claude Code hooks automatically on plugin startup |

## Usage

1. Start Claude Code in any terminal. The bar widget icon updates to reflect the session phase.
2. When Claude Code requests a permission, the widget pulses amber and a notification appears.
3. Click the bar widget to open the panel. Select the session to see the pending tool call details.
4. Click **Approve** or **Deny**. Claude Code resumes or cancels the operation immediately.
5. Click **Jump to Terminal** to focus the terminal window running that session.

### IPC

Other shell components can control the plugin via IPC:

```qml
IpcHandler.call("plugin:ai-monitor", "togglePanel", [screen, anchor])
IpcHandler.call("plugin:ai-monitor", "approve", [sessionId, toolUseId])
IpcHandler.call("plugin:ai-monitor", "deny",    [sessionId, toolUseId, reason])
```

## Architecture

```
Claude Code process
    │  hook events (stdin/stdout JSON)
    ▼
claude-hook.py          ← installed to ~/.claude/hooks/
    │  Unix socket (JSON lines)
    ▼
bridge.py serve         ← long-running process, managed by Main.qml
    │  JSONL state_update on stdout
    ▼
Main.qml                ← plugin core; parses state, exposes to UI
    ├── BarWidget.qml   ← system bar button
    ├── Panel.qml       ← session list + approval detail
    └── Settings.qml    ← configuration UI
```

**bridge.py** runs as a persistent asyncio server on two Unix sockets:

- `ai-monitor.sock` — receives hook events from Claude Code
- `ai-monitor.sock.ctl` — receives control commands (approve, deny, status) from the shell

For `PermissionRequest` events the hook connection is held open until the user approves or denies. All other events close immediately. Ended sessions are purged after 5 minutes; stale pending approvals time out after 5 minutes and are automatically denied.

## Security

- Both sockets are created with mode `0600` (owner read/write only).
- Symlinks at the socket path are rejected to prevent symlink attacks.
- The socket is placed in `$XDG_RUNTIME_DIR` by default, which is only accessible to the current user.
- Tool input fields longer than 2000 characters are truncated before being sent to the UI.

## Development

```bash
# Run the bridge manually for testing
python3 bridge.py serve --socket /tmp/test-ai-monitor.sock

# Check bridge state
python3 bridge.py status --socket /tmp/test-ai-monitor.sock

# Approve a pending request
python3 bridge.py approve --socket /tmp/test-ai-monitor.sock \
  --session <session_id> --tool-use-id <tool_use_id>

# Install hooks pointing to a local plugin directory
python3 bridge.py install-hook --plugin-dir .
```

All bridge subcommands emit a single JSON line on stdout:

```json
{ "ok": true }
{ "ok": false, "error": "...", "detail": "..." }
```

### Adding a new hook event

1. Add the event name to `HOOK_EVENTS` and `_EVENT_HANDLERS` in `bridge.py`.
2. Implement `_on_<event_name>` on `BridgeServer`.
3. Handle the event in `claude-hook.py` if it requires extra fields.

## License

MIT — see [LICENSE](LICENSE).
