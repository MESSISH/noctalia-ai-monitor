#!/usr/bin/env python3
"""
AI Monitor Hook for Claude Code
- Sends session state to ai-monitor bridge via Unix socket
- For PermissionRequest: waits for user decision from the bridge
"""
import json
import os
import socket
import subprocess
import sys

_runtime_dir = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
SOCKET_PATH = os.environ.get("AI_MONITOR_SOCKET", os.path.join(_runtime_dir, "ai-monitor.sock"))
TIMEOUT_SECONDS = 300  # 5 minutes for permission decisions


def get_tty():
    """Get the TTY of the Claude process (parent) - Linux version"""

    ppid = os.getppid()

    try:
        result = subprocess.run(
            ["ps", "-p", str(ppid), "-o", "tty="],
            capture_output=True,
            text=True,
            timeout=2,
        )
        tty = result.stdout.strip()
        if tty and tty != "??" and tty != "?":
            # Linux: ps returns "pts/0", we need "/dev/pts/0"
            if not tty.startswith("/dev/"):
                tty = "/dev/" + tty
            return tty
    except (OSError, subprocess.SubprocessError, ValueError):
        pass

    # Fallback: try current process stdin/stdout
    try:
        return os.ttyname(sys.stdin.fileno())
    except (OSError, AttributeError):
        pass
    try:
        return os.ttyname(sys.stdout.fileno())
    except (OSError, AttributeError):
        pass
    return None


def send_event(state):
    """Send event to bridge, return response if any"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        is_permission = state.get("event") == "PermissionRequest"
        sock.settimeout(TIMEOUT_SECONDS if is_permission else 10)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(state).encode() + b"\n")

        # For permission requests, wait for response (use event field, not status)
        if state.get("event") == "PermissionRequest":
            # Read until we get a complete line (handles fragmented responses)
            MAX_RESPONSE_SIZE = 64 * 1024  # 64KB safety limit
            data = b""
            while b"\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                data += chunk
                if len(data) > MAX_RESPONSE_SIZE:
                    break
            if data:
                return json.loads(data.decode())

        return None
    except (socket.error, OSError, json.JSONDecodeError, UnicodeDecodeError) as exc:
        print(f"[ai-monitor-hook] send_event failed: {exc}", file=sys.stderr)
        return None
    finally:
        sock.close()


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(1)

    session_id = data.get("session_id", "unknown")
    event = data.get("hook_event_name", "")
    cwd = data.get("cwd", "")
    tool_input = data.get("tool_input", {})

    claude_pid = os.getppid()
    tty = get_tty()

    state = {
        "session_id": session_id,
        "cwd": cwd,
        "event": event,
        "pid": claude_pid,
        "tty": tty,
    }

    if event == "UserPromptSubmit":
        pass

    elif event == "PreToolUse":
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PostToolUse":
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

    elif event == "PermissionRequest":
        state["tool"] = data.get("tool_name")
        state["tool_input"] = tool_input
        tool_use_id = data.get("tool_use_id")
        if tool_use_id:
            state["tool_use_id"] = tool_use_id

        response = send_event(state)

        if response:
            decision = response.get("decision", "ask")
            reason = response.get("reason", "")

            if decision == "allow":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {"behavior": "allow"},
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

            elif decision == "deny":
                output = {
                    "hookSpecificOutput": {
                        "hookEventName": "PermissionRequest",
                        "decision": {
                            "behavior": "deny",
                            "message": reason or "Denied by user via AI Monitor",
                        },
                    }
                }
                print(json.dumps(output))
                sys.exit(0)

        # No response or "ask" - let Claude Code show its normal UI
        sys.exit(0)

    elif event == "Notification":
        notification_type = data.get("notification_type")
        if notification_type == "permission_prompt":
            sys.exit(0)
        state["notification_type"] = notification_type
        state["message"] = data.get("message")

    elif event in ("Stop", "SubagentStop", "SessionStart", "SessionEnd", "PreCompact"):
        pass

    else:
        pass  # Unknown event — bridge will log and ignore

    send_event(state)


if __name__ == "__main__":
    main()
