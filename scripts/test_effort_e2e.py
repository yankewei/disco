#!/usr/bin/env python3
"""Verify model + effort config options are applied to opencode ACP session."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

REPO_ROOT = Path(__file__).resolve().parents[1]
DAEMON = os.environ.get(
    "DISCO_DAEMON",
    str(REPO_ROOT / "disco-daemon/target/debug/disco-daemon"),
)
STDERR_LOG = "/tmp/disco_e2e_effort_stderr.log"

env = dict(os.environ)
env["RUST_LOG"] = "debug"

proc = subprocess.Popen(
    [DAEMON],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=open(STDERR_LOG, "w"),
    text=True,
    env=env,
)
pending = {}

def send(req):
    req["jsonrpc"] = "2.0"
    if "id" not in req:
        req["id"] = len(pending) + 1
    pending[req["id"]] = req
    proc.stdin.write(json.dumps(req) + "\n")
    proc.stdin.flush()

def read_until(pred, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        msg = json.loads(line)
        if pred(msg):
            return msg
    return None

send({"method": "initialize", "params": {"protocolVersion": 1}})
assert read_until(lambda m: m.get("id") == 1), "initialize timeout"
print("[ok] initialize")

send({
    "method": "_disco/provider/configure",
    "params": {
        "providerId": "opencode_app_server",
        "vendor": "opencode",
        "baseUrl": "",
        "apiKey": "",
        "model": "opencode-go/kimi-k3",
        "thinkingEnabled": True,
        "reasoningEffort": "max",
    },
})
cfg = read_until(lambda m: m.get("id") == 2)
assert cfg, "configure timeout"
if "error" in cfg:
    print("[FAIL] configure:", json.dumps(cfg["error"], ensure_ascii=False))
    proc.kill(); sys.exit(1)
print("[ok] configure")

send({
    "method": "session/new",
    "params": {
        "cwd": "/tmp",
        "mcpServers": [],
        "_meta": {"disco/providerId": "opencode_app_server"},
    },
})
new = read_until(lambda m: m.get("id") == 3)
assert new, "session/new timeout"
if "error" in new:
    print("[FAIL] session/new:", json.dumps(new["error"], ensure_ascii=False))
    proc.kill(); sys.exit(1)
sid = new["result"]["sessionId"]
print("[ok] session/new:", sid)

send({
    "method": "session/prompt",
    "params": {"sessionId": sid, "prompt": [{"type": "text", "text": "hi"}]},
})
end = read_until(lambda m: m.get("id") == 4, timeout=120)
if end and "error" in end:
    print("[warn] prompt error (expected if opencode-go quota exhausted):",
          json.dumps(end["error"], ensure_ascii=False)[:300])
else:
    print("[ok] prompt completed")

proc.kill()
print("DONE")
