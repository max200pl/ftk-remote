#!/usr/bin/env python3
"""ftk-bridge: MCP server (stdio, no dependencies) that exposes the ftk client as tools.

Runs on the CLIENT machine (the one that drives the host). Every tool calls the
installed `ftk` command (ssh to the host alias `ftk`), so behaviour is identical
to the CLI. Register it once:

    claude mcp add ftk-bridge -s user -- python3 /path/to/ftk-mcp.py

Env: FTK_BIN = path to the ftk command (default: ~/.local/bin/ftk, then PATH).
"""
import json
import os
import shutil
import subprocess
import sys

SERVER = {"name": "ftk-bridge", "version": "1.0.0"}
DEFAULT_PROTOCOL = "2025-06-18"

LANE = {"type": "string", "description": "Lane name (a-z, 0-9, -). Omit for the main agent.",
        "pattern": "^[a-z0-9][a-z0-9-]{0,30}$"}


def tool(name, desc, props=None, required=None, read_only=False):
    schema = {"type": "object", "properties": props or {}, "additionalProperties": False}
    if required:
        schema["required"] = required
    return {"name": name, "description": desc, "inputSchema": schema,
            "annotations": {"readOnlyHint": read_only}}


TOOLS = [
    tool("ftk_status", "Session, claude process, state (busy/stop/waiting) and project folder of an agent on the host.",
         {"lane": LANE}, read_only=True),
    tool("ftk_peek", "Current screen of an agent (last N lines, blank runs collapsed). Use to see prompts it is waiting on.",
         {"lane": LANE, "lines": {"type": "integer", "minimum": 1, "maximum": 5000, "default": 200}}, read_only=True),
    tool("ftk_say", "Type a message into an agent and press Enter (multi-line is sent as one message). Sets state to busy.",
         {"lane": LANE, "text": {"type": "string", "minLength": 1}}, ["text"]),
    tool("ftk_wait", "Block until the agent finished its turn (stop) or needs input (waiting). Returns the state; "
         "'timeout' if it is still busy after timeout_s.",
         {"lane": LANE, "timeout_s": {"type": "integer", "minimum": 1, "maximum": 86400, "default": 600}}, read_only=True),
    tool("ftk_key", "Press one key in the agent: Enter, Escape, Up, Down, Tab, 1, 2, y, n, C-c (answers permission prompts).",
         {"lane": LANE, "key": {"type": "string", "pattern": "^[A-Za-z0-9-]+$"}}, ["key"]),
    tool("ftk_run", "Run a non-interactive shell command in the agent's project folder on the host (or ~/.ftk/xfer when "
         "no project is set). Returns output and the exit code.",
         {"lane": LANE, "command": {"type": "string", "minLength": 1},
          "timeout_s": {"type": "integer", "minimum": 1, "maximum": 7200, "default": 900}}, ["command"]),
    tool("ftk_log", "Last N transcript messages of the agent as plain text (assistant / tool_use / tool_result); raw=true gives jsonl.",
         {"lane": LANE, "n": {"type": "integer", "minimum": 1, "maximum": 1000, "default": 30},
          "raw": {"type": "boolean", "default": False}}, read_only=True),
    tool("ftk_setup_log", "Tail of the host's setup log (Windows host): follow the installation from the moment SSH is up.",
         {"lines": {"type": "integer", "minimum": 1, "maximum": 2000, "default": 60}}, read_only=True),
    tool("ftk_git", "Branch, changed files and last 10 commits of the agent's project.", {"lane": LANE}, read_only=True),
    tool("ftk_checkout", "Switch the agent's project to a branch (refused with uncommitted changes or for private branches).",
         {"lane": LANE, "branch": {"type": "string", "minLength": 1}}, ["branch"]),
    tool("ftk_lanes", "All agent sessions on the host with running/stopped, state and folder.", read_only=True),
    tool("ftk_new_lane", "Create a lane: its own git worktree on `branch` (cut from the base branch, or tracking it if it "
         "exists on origin) and its own agent session ftk-<name>.",
         {"name": LANE, "branch": {"type": "string", "minLength": 1}}, ["name", "branch"]),
    tool("ftk_start", "Start the agent session if it is not running.", {"lane": LANE}),
    tool("ftk_restart", "Kill and start the agent session again (a fresh Claude).", {"lane": LANE}),
    tool("ftk_setproject", "Point an agent at a folder on the host (~/ allowed). Restart the agent afterwards.",
         {"lane": LANE, "path": {"type": "string", "minLength": 1}}, ["path"]),
    tool("ftk_put", "Upload a local file to ~/.ftk/xfer/<remote_path> on the host. Returns size and sha256 on both sides.",
         {"local_path": {"type": "string", "minLength": 1},
          "remote_path": {"type": "string", "pattern": "^[A-Za-z0-9._/-]+$"}}, ["local_path", "remote_path"]),
    tool("ftk_get", "Download ~/.ftk/xfer/<remote_path> from the host to a local file. Returns size and sha256.",
         {"remote_path": {"type": "string", "pattern": "^[A-Za-z0-9._/-]+$"},
          "local_path": {"type": "string", "minLength": 1}}, ["remote_path", "local_path"]),
    tool("ftk_xfer", "List files in ~/.ftk/xfer on the host.", read_only=True),
    tool("ftk_events", "ntfy notifications from the host (host ready / turn finished / needs you).",
         {"since": {"type": "string", "pattern": "^([0-9]+[smhd]|all)$", "default": "1h"}}, read_only=True),
]
TOOL_NAMES = {t["name"] for t in TOOLS}


def ftk_bin():
    b = os.environ.get("FTK_BIN") or os.path.expanduser("~/.local/bin/ftk")
    if os.path.isfile(b) and os.access(b, os.X_OK):
        return [b]
    w = shutil.which("ftk")
    if w:
        return [w]
    raise RuntimeError("ftk command not found - run the client setup first (or set FTK_BIN)")


def lane(a):
    return ["-s", a["lane"]] if a.get("lane") else []


def build(name, a):
    """Tool call -> (ftk argv, timeout seconds)."""
    if name == "ftk_status":     return lane(a) + ["status"], 60
    if name == "ftk_peek":       return lane(a) + ["peek", str(int(a.get("lines", 200)))], 60
    if name == "ftk_say":        return lane(a) + ["say", a["text"]], 60
    if name == "ftk_wait":
        t = int(a.get("timeout_s", 600)); return lane(a) + ["wait", str(t)], t + 60
    if name == "ftk_key":        return lane(a) + ["key", a["key"]], 60
    if name == "ftk_run":        return lane(a) + ["run", a["command"]], int(a.get("timeout_s", 900))
    if name == "ftk_log":        return lane(a) + ["log", str(int(a.get("n", 30)))] + (["raw"] if a.get("raw") else []), 60
    if name == "ftk_setup_log":  return ["setup-log", str(int(a.get("lines", 60)))], 60
    if name == "ftk_git":        return lane(a) + ["git"], 60
    if name == "ftk_checkout":   return lane(a) + ["checkout", a["branch"]], 300
    if name == "ftk_lanes":      return ["lanes"], 60
    if name == "ftk_new_lane":   return ["new-lane", a["name"], a["branch"]], 300
    if name == "ftk_start":      return lane(a) + ["start"], 60
    if name == "ftk_restart":    return lane(a) + ["restart"], 60
    if name == "ftk_setproject": return lane(a) + ["setproject", a["path"]], 60
    if name == "ftk_put":        return ["put", os.path.expanduser(a["local_path"]), a["remote_path"]], 3600
    if name == "ftk_get":        return ["get", a["remote_path"], os.path.expanduser(a["local_path"])], 3600
    if name == "ftk_xfer":       return ["xfer"], 60
    if name == "ftk_events":     return ["events", a.get("since", "1h")], 60
    raise KeyError(name)


def call(name, a):
    argv, timeout = build(name, a or {})
    try:
        p = subprocess.run(ftk_bin() + argv, stdin=subprocess.DEVNULL, capture_output=True,
                           timeout=timeout, text=True, encoding="utf-8", errors="replace")
    except subprocess.TimeoutExpired:
        return f"ERROR: no answer from the host within {timeout}s (ftk {argv[0] if argv else ''})", True
    out = (p.stdout or "") + (("\n" + p.stderr) if p.stderr.strip() else "")
    out = out.strip() or "(no output)"
    if name == "ftk_wait" and p.returncode == 124:
        return out, False                        # a timeout is an answer, not an error
    if name == "ftk_run":
        return out, False                        # exit code is part of the output: "[exit N]"
    if p.returncode != 0:
        return f"{out}\n[ftk exit {p.returncode}]", True
    return out, False


def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, id_, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
    if id_ is None:                                # notification (e.g. notifications/initialized)
        return
    if method == "initialize":
        reply(id_, {"protocolVersion": params.get("protocolVersion") or DEFAULT_PROTOCOL,
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": SERVER,
                    "instructions": "Bridge to Claude Code agents on a remote host (ftk). Typical loop: ftk_say -> "
                                    "ftk_wait -> ftk_log / ftk_peek; ftk_key answers prompts; ftk_run runs tests."})
    elif method == "ping":
        reply(id_, {})
    elif method == "tools/list":
        reply(id_, {"tools": TOOLS})
    elif method == "tools/call":
        name, args = params.get("name"), params.get("arguments") or {}
        if name not in TOOL_NAMES:
            reply(id_, error={"code": -32602, "message": f"unknown tool: {name}"})
            return
        try:
            text, is_err = call(name, args)
        except (KeyError, ValueError, TypeError) as e:
            text, is_err = f"ERROR: bad arguments: {e}", True
        except RuntimeError as e:
            text, is_err = f"ERROR: {e}", True
        reply(id_, {"content": [{"type": "text", "text": text}], "isError": is_err})
    else:
        reply(id_, error={"code": -32601, "message": f"method not found: {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            reply(None, error={"code": -32700, "message": "parse error"})
            continue
        for m in (msg if isinstance(msg, list) else [msg]):
            handle(m)


if __name__ == "__main__":
    main()
