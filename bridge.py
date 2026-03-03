#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def emit(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, ensure_ascii=False), flush=True)
    return 0


def fail(message: str, detail: str = "") -> int:
    return emit({"ok": False, "error": message, "detail": detail})


# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------

VALID_PHASES = {
    "idle",
    "processing",
    "waiting_for_input",
    "waiting_for_approval",
    "compacting",
    "ended",
}

# Map of hook event name → state transition handler name
_EVENT_HANDLERS: dict[str, str] = {
    "SessionStart": "_on_session_start",
    "UserPromptSubmit": "_on_user_prompt_submit",
    "PreToolUse": "_on_pre_tool_use",
    "PostToolUse": "_on_post_tool_use",
    "PermissionRequest": "_on_permission_request",
    "Stop": "_on_stop",
    "SubagentStop": "_on_subagent_stop",
    "Notification": "_on_notification",
    "PreCompact": "_on_pre_compact",
    "SessionEnd": "_on_session_end",
}

HOOK_COMMAND = "python3 ~/.claude/hooks/ai-monitor-hook.py"

HOOK_EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PermissionRequest",
    "Notification",
    "Stop",
    "SubagentStop",
    "PreCompact",
    "SessionEnd",
]

HOOK_TIMEOUTS: dict[str, int] = {
    "PermissionRequest": 300,
}
DEFAULT_HOOK_TIMEOUT = 5


# ---------------------------------------------------------------------------
# Server
# ---------------------------------------------------------------------------

class BridgeServer:
    """Asyncio-based Unix socket server for the AI Monitor plugin."""

    CLEANUP_INTERVAL = 60          # seconds between cleanup passes
    SESSION_ENDED_TTL = 300        # keep ended sessions for 5 min
    APPROVAL_TIMEOUT = 300         # auto-close pending approvals after 5 min

    def __init__(self, socket_path: str) -> None:
        self.socket_path = Path(socket_path)
        self.ctl_socket_path = Path(socket_path + ".ctl")

        # session_id -> session dict
        self.sessions: dict[str, dict[str, Any]] = {}

        # "session_id:tool_use_id" -> (writer, timestamp)
        self.pending_approvals: dict[str, tuple[asyncio.StreamWriter, float]] = {}

    # ------------------------------------------------------------------
    # Public entry point
    # ------------------------------------------------------------------

    def run(self) -> None:
        asyncio.run(self._main())

    async def _main(self) -> None:
        # Remove stale socket files (reject symlinks to prevent attacks)
        for p in (self.socket_path, self.ctl_socket_path):
            if p.is_symlink():
                raise RuntimeError(f"Socket path {p} is a symlink, refusing to proceed")
            if p.exists():
                p.unlink()

        main_server = await asyncio.start_unix_server(
            self._handle_hook_connection,
            path=str(self.socket_path),
        )
        os.chmod(str(self.socket_path), 0o600)

        ctl_server = await asyncio.start_unix_server(
            self._handle_ctl_connection,
            path=str(self.ctl_socket_path),
        )
        os.chmod(str(self.ctl_socket_path), 0o600)

        cleanup_task = asyncio.create_task(self._cleanup_loop())

        async with main_server, ctl_server:
            print(
                json.dumps({"type": "server_ready", "socket": str(self.socket_path)}),
                flush=True,
            )
            await asyncio.gather(
                main_server.serve_forever(),
                ctl_server.serve_forever(),
                cleanup_task,
            )

    # ------------------------------------------------------------------
    # Hook connection handler (main socket)
    # ------------------------------------------------------------------

    async def _handle_hook_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            # Use readline() — the hook appends \n and may keep the connection
            # open (PermissionRequest), so read() would block waiting for EOF.
            # Timeout prevents hung clients from leaking resources.
            raw = await asyncio.wait_for(reader.readline(), timeout=30.0)
            if not raw:
                writer.close()
                await writer.wait_closed()
                return
            event = json.loads(raw.decode())
        except asyncio.TimeoutError:
            print("[bridge] hook read timeout", file=sys.stderr, flush=True)
            writer.close()
            await writer.wait_closed()
            return
        except Exception as exc:
            print(f"[bridge] hook read error: {exc}", file=sys.stderr, flush=True)
            writer.close()
            await writer.wait_closed()
            return

        # The hook sends the event name as "event" (not "hook_event_name")
        event_name: str = event.get("event", "")
        session_id: str = event.get("session_id", "")

        handler_name = _EVENT_HANDLERS.get(event_name)
        if handler_name is None:
            print(
                f"[bridge] unknown event '{event_name}', ignoring",
                file=sys.stderr,
                flush=True,
            )
            writer.close()
            await writer.wait_closed()
            return

        handler = getattr(self, handler_name)
        keep_open = await handler(event, session_id, writer)

        if not keep_open:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

        self._emit_state()

    # ------------------------------------------------------------------
    # Event handlers
    # ------------------------------------------------------------------

    @staticmethod
    def _find_transcript(session_id: str) -> Path | None:
        """Find the conversation transcript file for a session ID."""
        projects_dir = Path.home() / ".claude" / "projects"
        if not projects_dir.exists():
            return None
        for project_dir in projects_dir.iterdir():
            if not project_dir.is_dir():
                continue
            transcript = project_dir / f"{session_id}.jsonl"
            if transcript.exists():
                return transcript
        return None

    @staticmethod
    def _read_last_response(session_id: str) -> str:
        """Read the last assistant text from the conversation transcript."""
        transcript = BridgeServer._find_transcript(session_id)
        if not transcript:
            return ""

        try:
            file_size = transcript.stat().st_size
            with open(transcript, "rb") as f:
                if file_size > 100_000:
                    f.seek(file_size - 100_000)
                raw = f.read()
            text = raw.decode("utf-8", errors="replace")
            # Skip first partial line if we seeked into the middle
            if file_size > 100_000:
                first_nl = text.find("\n")
                if first_nl >= 0:
                    text = text[first_nl + 1:]
            lines = text.splitlines(keepends=True)
        except OSError:
            return ""

        for line in reversed(lines):
            try:
                obj = json.loads(line.strip())
            except (json.JSONDecodeError, ValueError):
                continue
            if obj.get("type") != "assistant":
                continue
            content = obj.get("message", {}).get("content", [])
            for c in reversed(content if isinstance(content, list) else []):
                if isinstance(c, dict) and c.get("type") == "text":
                    text = c["text"].strip()
                    if text:
                        return text[:300]

        return ""

    def _ensure_session(self, session_id: str, event: dict[str, Any]) -> dict[str, Any]:
        if session_id not in self.sessions:
            self.sessions[session_id] = {
                "session_id": session_id,
                "cwd": event.get("cwd", ""),
                "phase": "idle",
                "tool": None,
                "tool_input": None,
                "tool_use_id": None,
                "last_response": "",
                "pid": event.get("pid"),
                "tty": event.get("tty"),
                "last_activity": time.time(),
            }
        return self.sessions[session_id]

    def _touch(self, session: dict[str, Any]) -> None:
        session["last_activity"] = time.time()

    async def _on_session_start(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "waiting_for_input"
        session["cwd"] = event.get("cwd", session["cwd"])
        session["pid"] = event.get("pid", session["pid"])
        session["tty"] = event.get("tty", session["tty"])
        self._touch(session)
        return False  # close connection

    async def _on_user_prompt_submit(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "processing"
        self._touch(session)
        return False

    async def _on_pre_tool_use(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "processing"
        session["tool"] = event.get("tool")
        session["tool_input"] = event.get("tool_input")
        session["tool_use_id"] = event.get("tool_use_id")
        self._touch(session)
        return False

    async def _on_post_tool_use(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "processing"
        self._touch(session)
        return False

    async def _on_permission_request(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "waiting_for_approval"
        session["tool"] = event.get("tool")
        session["tool_input"] = event.get("tool_input")
        tool_use_id = event.get("tool_use_id", "")
        session["tool_use_id"] = tool_use_id
        self._touch(session)

        key = f"{session_id}:{tool_use_id}"
        self.pending_approvals[key] = (writer, time.time())
        return True  # keep connection open until approved/denied

    async def _on_stop(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "waiting_for_input"
        session["tool"] = None
        session["tool_input"] = None
        session["tool_use_id"] = None
        # Read Claude's last response from the conversation transcript
        resp = self._read_last_response(session_id)
        if resp:
            session["last_response"] = resp
        self._touch(session)
        return False

    async def _on_subagent_stop(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        return await self._on_stop(event, session_id, writer)

    async def _on_notification(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        notif_type = event.get("notification_type", "")
        if notif_type == "idle_prompt":
            session["phase"] = "waiting_for_input"
        # else: leave phase unchanged, just record activity
        self._touch(session)
        return False

    async def _on_pre_compact(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "compacting"
        self._touch(session)
        return False

    async def _on_session_end(
        self, event: dict[str, Any], session_id: str, writer: asyncio.StreamWriter
    ) -> bool:
        session = self._ensure_session(session_id, event)
        session["phase"] = "ended"
        self._touch(session)
        return False

    # ------------------------------------------------------------------
    # Control connection handler (ctl socket)
    # ------------------------------------------------------------------

    async def _handle_ctl_connection(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            raw = await asyncio.wait_for(reader.read(1 << 16), timeout=30.0)
            if not raw:
                writer.close()
                await writer.wait_closed()
                return
            cmd = json.loads(raw.decode())
        except asyncio.TimeoutError:
            print("[bridge] ctl read timeout", file=sys.stderr, flush=True)
            writer.close()
            await writer.wait_closed()
            return
        except Exception as exc:
            print(f"[bridge] ctl read error: {exc}", file=sys.stderr, flush=True)
            writer.close()
            await writer.wait_closed()
            return

        action = cmd.get("action", "")

        try:
            if action == "approve":
                await self._ctl_approve(cmd, writer)
            elif action == "deny":
                await self._ctl_deny(cmd, writer)
            elif action == "status":
                await self._ctl_status(writer)
            else:
                resp = {"ok": False, "error": f"unknown action '{action}'"}
                writer.write(json.dumps(resp).encode() + b"\n")
                await writer.drain()
        except Exception as exc:
            print(f"[bridge] ctl handler error: {exc}", file=sys.stderr, flush=True)
        finally:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    async def _ctl_approve(
        self, cmd: dict[str, Any], ctl_writer: asyncio.StreamWriter
    ) -> None:
        session_id = cmd.get("session_id", "")
        tool_use_id = cmd.get("tool_use_id", "")
        key = f"{session_id}:{tool_use_id}"

        entry = self.pending_approvals.pop(key, None)
        if entry is None:
            resp = {"ok": False, "error": f"no pending approval for '{key}'"}
            ctl_writer.write(json.dumps(resp).encode() + b"\n")
            await ctl_writer.drain()
            return

        hook_writer, _ = entry
        decision = json.dumps({"decision": "allow"}).encode() + b"\n"
        try:
            hook_writer.write(decision)
            await hook_writer.drain()
            hook_writer.close()
            await hook_writer.wait_closed()
        except Exception as exc:
            print(f"[bridge] approve send error: {exc}", file=sys.stderr, flush=True)

        # Update session phase
        if session_id in self.sessions:
            self.sessions[session_id]["phase"] = "processing"
            self._touch(self.sessions[session_id])

        self._emit_state()
        resp = {"ok": True}
        ctl_writer.write(json.dumps(resp).encode() + b"\n")
        await ctl_writer.drain()

    async def _ctl_deny(
        self, cmd: dict[str, Any], ctl_writer: asyncio.StreamWriter
    ) -> None:
        session_id = cmd.get("session_id", "")
        tool_use_id = cmd.get("tool_use_id", "")
        reason = cmd.get("reason", "Denied by user")
        key = f"{session_id}:{tool_use_id}"

        entry = self.pending_approvals.pop(key, None)
        if entry is None:
            resp = {"ok": False, "error": f"no pending approval for '{key}'"}
            ctl_writer.write(json.dumps(resp).encode() + b"\n")
            await ctl_writer.drain()
            return

        hook_writer, _ = entry
        decision = json.dumps({"decision": "deny", "reason": reason}).encode() + b"\n"
        try:
            hook_writer.write(decision)
            await hook_writer.drain()
            hook_writer.close()
            await hook_writer.wait_closed()
        except Exception as exc:
            print(f"[bridge] deny send error: {exc}", file=sys.stderr, flush=True)

        # Update session phase
        if session_id in self.sessions:
            self.sessions[session_id]["phase"] = "waiting_for_input"
            self.sessions[session_id]["tool"] = None
            self.sessions[session_id]["tool_input"] = None
            self.sessions[session_id]["tool_use_id"] = None
            self._touch(self.sessions[session_id])

        self._emit_state()
        resp = {"ok": True}
        ctl_writer.write(json.dumps(resp).encode() + b"\n")
        await ctl_writer.drain()

    async def _ctl_status(self, ctl_writer: asyncio.StreamWriter) -> None:
        resp = {
            "ok": True,
            "sessions": self.sessions,
            "pending_approvals": list(self.pending_approvals.keys()),
        }
        ctl_writer.write(json.dumps(resp, ensure_ascii=False).encode() + b"\n")
        await ctl_writer.drain()

    # ------------------------------------------------------------------
    # Cleanup loop
    # ------------------------------------------------------------------

    async def _cleanup_loop(self) -> None:
        while True:
            await asyncio.sleep(self.CLEANUP_INTERVAL)
            now = time.time()

            # Remove old ended sessions
            to_remove = [
                sid
                for sid, s in self.sessions.items()
                if s["phase"] == "ended"
                and (now - s["last_activity"]) > self.SESSION_ENDED_TTL
            ]
            for sid in to_remove:
                del self.sessions[sid]

            # Auto-close stale pending approvals
            stale_keys = [
                key
                for key, (_, ts) in self.pending_approvals.items()
                if (now - ts) > self.APPROVAL_TIMEOUT
            ]
            for key in stale_keys:
                entry = self.pending_approvals.pop(key, None)
                if entry is None:
                    continue
                writer, _ = entry
                try:
                    timeout_resp = json.dumps(
                        {"decision": "deny", "reason": "Approval timed out"}
                    ).encode() + b"\n"
                    writer.write(timeout_resp)
                    await writer.drain()
                    writer.close()
                    await writer.wait_closed()
                except Exception as exc:
                    print(
                        f"[bridge] cleanup close error for '{key}': {exc}",
                        file=sys.stderr,
                        flush=True,
                    )
                # Update session state if still tracked
                parts = key.split(":", 1)
                if parts and parts[0] in self.sessions:
                    self.sessions[parts[0]]["phase"] = "waiting_for_input"
                    self.sessions[parts[0]]["tool"] = None
                    self.sessions[parts[0]]["tool_input"] = None
                    self.sessions[parts[0]]["tool_use_id"] = None
                    self._touch(self.sessions[parts[0]])

            if to_remove or stale_keys:
                self._emit_state()

    # ------------------------------------------------------------------
    # JSONL stdout emitter
    # ------------------------------------------------------------------

    @staticmethod
    def _truncate_tool_input(tool_input: Any, max_len: int = 2000) -> Any:
        """Truncate large fields in tool_input to avoid bloating JSONL output."""
        if tool_input is None or not isinstance(tool_input, dict):
            return tool_input
        result = {}
        for k, v in tool_input.items():
            if isinstance(v, str) and len(v) > max_len:
                result[k] = v[:max_len] + "…"
            else:
                result[k] = v
        return result

    def _emit_state(self) -> None:
        # Build a copy with truncated tool_input to avoid huge payloads
        sessions_out: dict[str, Any] = {}
        for sid, s in self.sessions.items():
            s_copy = dict(s)
            s_copy["tool_input"] = self._truncate_tool_input(s.get("tool_input"))
            sessions_out[sid] = s_copy
        payload = {
            "type": "state_update",
            "sessions": sessions_out,
            "pending_approvals": list(self.pending_approvals.keys()),
        }
        print(json.dumps(payload, ensure_ascii=False), flush=True)


# ---------------------------------------------------------------------------
# Short-lived client helpers
# ---------------------------------------------------------------------------

async def _send_ctl(socket_path: str, payload: dict[str, Any]) -> dict[str, Any]:
    ctl_path = socket_path + ".ctl"
    reader, writer = await asyncio.open_unix_connection(ctl_path)
    writer.write(json.dumps(payload).encode())
    writer.write_eof()
    await writer.drain()
    raw = await reader.read(1 << 16)
    writer.close()
    await writer.wait_closed()
    return json.loads(raw.decode())


def _run_ctl(socket_path: str, payload: dict[str, Any]) -> int:
    try:
        result = asyncio.run(_send_ctl(socket_path, payload))
        return emit(result)
    except FileNotFoundError:
        return fail("Control socket not found — is bridge serving?", socket_path + ".ctl")
    except ConnectionRefusedError:
        return fail("Connection refused — is bridge serving?", socket_path + ".ctl")
    except Exception as exc:
        return fail(str(exc))


# ---------------------------------------------------------------------------
# install-hook subcommand
# ---------------------------------------------------------------------------

def _install_hook(socket_path: str, plugin_dir: str) -> int:
    plugin_path = Path(plugin_dir)
    hook_src = plugin_path / "claude-hook.py"
    if not hook_src.exists():
        return fail("claude-hook.py not found in plugin-dir", str(hook_src))

    hooks_dir = Path.home() / ".claude" / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)

    hook_dst = hooks_dir / "ai-monitor-hook.py"
    shutil.copy2(hook_src, hook_dst)

    settings_path = Path.home() / ".claude" / "settings.json"
    if settings_path.exists():
        try:
            settings: dict[str, Any] = json.loads(settings_path.read_text())
        except Exception as exc:
            return fail(f"Failed to parse settings.json: {exc}")
    else:
        settings = {}

    hooks: dict[str, list[dict[str, Any]]] = settings.setdefault("hooks", {})

    for event in HOOK_EVENTS:
        timeout = HOOK_TIMEOUTS.get(event, DEFAULT_HOOK_TIMEOUT)
        new_entry: dict[str, Any] = {
            "hooks": [
                {
                    "type": "command",
                    "command": HOOK_COMMAND,
                    "timeout": timeout,
                }
            ],
        }
        event_hooks: list[dict[str, Any]] = hooks.setdefault(event, [])
        # Only add if not already present (identified by command string in hooks array)
        already = any(
            any(
                h2.get("command") == HOOK_COMMAND
                for h2 in (h.get("hooks") or [])
                if isinstance(h2, dict)
            )
            for h in event_hooks
            if isinstance(h, dict)
        )
        if not already:
            event_hooks.append(new_entry)

    # Atomic write: write to temp file, then rename (atomic on same filesystem)
    tmp_path = settings_path.with_suffix(".tmp")
    tmp_path.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")
    tmp_path.rename(settings_path)

    return emit(
        {
            "ok": True,
            "hook_installed": str(hook_dst),
            "settings_updated": str(settings_path),
        }
    )


# ---------------------------------------------------------------------------
# focus-terminal subcommand
# ---------------------------------------------------------------------------

def _find_ancestor_pids(pid: int) -> list[int]:
    """Walk up the process tree from pid, returning [pid, ppid, ppid_of_ppid, ...]."""
    chain: list[int] = []
    current = pid
    while current > 1:
        chain.append(current)
        try:
            status = Path(f"/proc/{current}/status").read_text()
        except OSError:
            break
        for line in status.splitlines():
            if line.startswith("PPid:"):
                current = int(line.split()[1])
                break
        else:
            break
    return chain


def _tty_title_stamp(
    tty: str, candidates: list[dict[str, Any]]
) -> dict[str, Any] | None:
    """Identify the correct window by temporarily stamping a unique title via PTY.

    Writes an OSC escape sequence to the session's TTY to set a unique marker
    as the terminal window title, queries niri to find which window received
    that title, then restores the original title.
    """

    marker = f"_AI_MONITOR_{uuid.uuid4().hex[:12]}"

    # Save the original title so we can restore it later
    original_title: str | None = None

    # Write the marker title to the PTY
    try:
        with open(tty, "w") as f:
            f.write(f"\033]0;{marker}\007")
            f.flush()
    except OSError:
        return None

    # Wait for the compositor to pick up the title change.
    # 150ms is empirically sufficient for kitty+niri; increase if unreliable
    # on slower systems.
    time.sleep(0.15)

    # Query niri for the window with the marker title
    matched: dict[str, Any] | None = None
    try:
        result = subprocess.run(
            ["niri", "msg", "-j", "windows"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            windows = json.loads(result.stdout)
            for w in windows:
                if marker in (w.get("title") or ""):
                    matched = w
                    break
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"[bridge] tty_title_stamp niri query failed: {exc}", file=sys.stderr, flush=True)

    # Restore the original title.
    # Find what it was from the candidates list (before we changed it).
    if matched:
        for c in candidates:
            if c["id"] == matched["id"]:
                original_title = c.get("title", "")
                break
    if original_title is None:
        original_title = candidates[0].get("title", "")

    try:
        with open(tty, "w") as f:
            f.write(f"\033]0;{original_title}\007")
            f.flush()
    except OSError:
        pass

    # Return the matching candidate (not the refreshed window dict)
    if matched:
        for c in candidates:
            if c["id"] == matched["id"]:
                return c

    return None


def _score_candidate(w: dict[str, Any], cwd: str) -> int:
    """Score how well a niri window matches the target session."""
    title = (w.get("title") or "").lower()
    score = 0

    if cwd:
        cwd_lower = cwd.rstrip("/").lower()
        if cwd_lower in title:
            score += 100
        else:
            basename = cwd_lower.rsplit("/", 1)[-1]
            if basename and len(basename) > 2 and basename in title:
                score += 50

    if "claude" in title:
        score += 10

    return score


def _focus_terminal(pid: int, tty: str, cwd: str) -> int:
    """Focus the niri terminal window that owns the given Claude PID."""
    if platform.system() != "Linux":
        return fail("focus-terminal is only supported on Linux with niri compositor")

    # Get all niri windows as JSON
    try:
        result = subprocess.run(
            ["niri", "msg", "-j", "windows"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return fail("Failed to list niri windows", result.stderr.strip())
        windows = json.loads(result.stdout)
    except Exception as exc:
        return fail("Failed to query niri windows", str(exc))

    # Walk up from Claude PID to find ancestor PIDs
    ancestor_pids = set(_find_ancestor_pids(pid))

    # Collect candidate windows whose PID is in the ancestor chain
    candidates: list[dict[str, Any]] = []
    for w in windows:
        w_pid = w.get("pid", 0)
        if w_pid in ancestor_pids:
            candidates.append(w)

    if not candidates:
        return fail("No terminal window found for PID", str(pid))

    if len(candidates) == 1:
        best_window = candidates[0]
    else:
        # Multiple windows share the same terminal emulator PID (e.g. kitty).
        best_window = None

        # Strategy 1: PTY title-stamping (definitive when TTY is available).
        # Write a unique marker to the session's PTY as the window title,
        # then query the compositor to find which window received it.
        if tty:
            best_window = _tty_title_stamp(tty, candidates)

        # Strategy 2: Score each candidate by window title vs session CWD.
        if best_window is None:
            best_score = -1
            for w in candidates:
                s = _score_candidate(w, cwd)
                if s > best_score:
                    best_score = s
                    best_window = w

        if best_window is None:
            best_window = candidates[0]

    window_id = best_window["id"]
    try:
        subprocess.run(
            ["niri", "msg", "action", "focus-window", "--id", str(window_id)],
            capture_output=True, timeout=5,
        )
    except Exception as exc:
        return fail("Failed to focus window", str(exc))

    return emit({"ok": True, "focused_window_id": window_id, "app_id": best_window.get("app_id", "")})


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bridge.py",
        description="AI Monitor bridge — asyncio Unix socket server for the noctalia plugin",
    )
    sub = parser.add_subparsers(dest="subcommand", required=True)

    # serve
    p_serve = sub.add_parser("serve", help="Start the bridge server")
    p_serve.add_argument("--socket", required=True, help="Path to the main Unix socket")

    # approve
    p_approve = sub.add_parser("approve", help="Approve a pending tool-use request")
    p_approve.add_argument("--socket", required=True)
    p_approve.add_argument("--session", required=True, dest="session_id")
    p_approve.add_argument("--tool-use-id", required=True)

    # deny
    p_deny = sub.add_parser("deny", help="Deny a pending tool-use request")
    p_deny.add_argument("--socket", required=True)
    p_deny.add_argument("--session", required=True, dest="session_id")
    p_deny.add_argument("--tool-use-id", required=True)
    p_deny.add_argument("--reason", default="Denied by user")

    # status
    p_status = sub.add_parser("status", help="Query current bridge state")
    p_status.add_argument("--socket", required=True)

    # install-hook
    p_install = sub.add_parser("install-hook", help="Install claude hook into ~/.claude/")
    p_install.add_argument("--socket", required=False, default="", help="Unused; kept for API symmetry")
    p_install.add_argument("--plugin-dir", required=True, help="Directory containing claude-hook.py")

    # focus-terminal
    p_focus = sub.add_parser("focus-terminal", help="Focus the terminal window for a Claude PID")
    p_focus.add_argument("--pid", required=True, type=int, help="PID of the Claude process")
    p_focus.add_argument("--tty", default="", help="TTY device path (e.g. /dev/pts/5)")
    p_focus.add_argument("--cwd", default="", help="Working directory for title matching")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.subcommand == "serve":
        BridgeServer(args.socket).run()
        return 0

    if args.subcommand == "approve":
        return _run_ctl(
            args.socket,
            {
                "action": "approve",
                "session_id": args.session_id,
                "tool_use_id": args.tool_use_id,
            },
        )

    if args.subcommand == "deny":
        return _run_ctl(
            args.socket,
            {
                "action": "deny",
                "session_id": args.session_id,
                "tool_use_id": args.tool_use_id,
                "reason": args.reason,
            },
        )

    if args.subcommand == "status":
        return _run_ctl(args.socket, {"action": "status"})

    if args.subcommand == "install-hook":
        return _install_hook(args.socket, args.plugin_dir)

    if args.subcommand == "focus-terminal":
        return _focus_terminal(args.pid, args.tty, args.cwd)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
