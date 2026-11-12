#!/usr/bin/env python3
"""Stand-in for `claude -p --output-format stream-json --verbose [--resume ID]`: reads the prompt on stdin."""
import json, sys, time, uuid
args = sys.argv[1:]
prompt = sys.stdin.read()
sid = args[args.index("--resume") + 1] if "--resume" in args else "sess-" + uuid.uuid4().hex[:8]
def out(o): print(json.dumps(o, ensure_ascii=False), flush=True)
out({"type": "system", "subtype": "init", "session_id": sid, "model": "fake"})
if "SLOW" in prompt:
    time.sleep(30)
out({"type": "assistant", "message": {"content": [{"type": "text", "text": "ECHO: " + prompt},
     {"type": "tool_use", "name": "Bash", "input": {"command": "python -m pytest -q"}}]}, "session_id": sid})
out({"type": "user", "message": {"content": [{"type": "tool_result", "content": "412 passed"}]}, "session_id": sid})
if "FAIL" in prompt:
    out({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "boom", "session_id": sid})
    sys.exit(1)
den = [{"tool_name": "Bash"}] if "DENY" in prompt else []
out({"type": "result", "subtype": "success", "is_error": False, "result": "done; resumed=" + str("--resume" in args),
     "session_id": sid, "permission_denials": den})
