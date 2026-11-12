#!/usr/bin/env python3
"""Drive ftk-mcp.py over stdio JSON-RPC and print 'ok <name>' / 'bad <name> <detail>' lines."""
import json, os, subprocess, sys, tempfile
srv = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, encoding="utf-8")
nid = [0]
def rpc(method, params=None, notify=False):
    m = {"jsonrpc": "2.0", "method": method}
    if params is not None: m["params"] = params
    if not notify:
        nid[0] += 1; m["id"] = nid[0]
    srv.stdin.write(json.dumps(m) + "\n"); srv.stdin.flush()
    return None if notify else json.loads(srv.stdout.readline())
def call(name, **a):
    r = rpc("tools/call", {"name": name, "arguments": a})["result"]
    return r["content"][0]["text"], r["isError"]
def check(name, cond, detail=""):
    print(("ok " if cond else "bad ") + name + ("" if cond else " :: " + str(detail)[:300]), flush=True)

r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
check("mcp initialize -> serverInfo ftk-bridge + tools capability",
      r["result"]["serverInfo"]["name"] == "ftk-bridge" and "tools" in r["result"]["capabilities"], r)
rpc("notifications/initialized", notify=True)
check("mcp notification gets no reply (next reply is ping)", rpc("ping")["result"] == {})
tl = rpc("tools/list")["result"]["tools"]
names = {t["name"] for t in tl}
check("mcp tools/list: 20 tools with schemas", len(tl) == 20 and all("inputSchema" in t for t in tl), sorted(names))
t, e = call("ftk_status"); check("mcp ftk_status", "session: running" in t and not e, t)
t, e = call("ftk_say", lane="a1", text="mcp привет\nвторая"); check("mcp ftk_say (lane a1)", "sent" in t and not e, t)
import time; time.sleep(1.5)
t, e = call("ftk_peek", lane="a1", lines=80); check("mcp ftk_peek shows the message", "AGENT GOT: mcp привет" in t, t)
t, e = call("ftk_wait", lane="a1", timeout_s=1); check("mcp ftk_wait timeout is not an error", t.startswith("timeout") and not e, (t, e))
t, e = call("ftk_run", lane="a1", command="git rev-parse --abbrev-ref HEAD; exit 4")
check("mcp ftk_run: output + [exit 4]", "migrate/s2-a1" in t and "[exit 4]" in t and not e, t)
t, e = call("ftk_key", key="a;b"); check("mcp ftk_key bad key -> isError", e, t)
t, e = call("ftk_lanes"); check("mcp ftk_lanes", "ftk-a1" in t and not e, t)
t, e = call("ftk_git", lane="a1"); check("mcp ftk_git", "migrate/s2-a1" in t, t)
t, e = call("ftk_log", n=3); check("mcp ftk_log text", "All green." in t, t)
d = tempfile.mkdtemp(); src = os.path.join(d, "a.bin"); open(src, "wb").write(os.urandom(50000))
t, e = call("ftk_put", local_path=src, remote_path="mcp/a.bin"); check("mcp ftk_put", "saved" in t and not e, t)
dst = os.path.join(d, "b.bin")
t, e = call("ftk_get", remote_path="mcp/a.bin", local_path=dst)
check("mcp ftk_get round-trip identical", not e and open(src, "rb").read() == open(dst, "rb").read(), t)
t, e = call("ftk_xfer"); check("mcp ftk_xfer", "mcp/a.bin" in t, t)
r = rpc("tools/call", {"name": "nope", "arguments": {}}); check("mcp unknown tool -> JSON-RPC error", "error" in r, r)
r = rpc("bogus/method"); check("mcp unknown method -> -32601", r.get("error", {}).get("code") == -32601, r)
srv.stdin.close(); srv.wait(timeout=10)
