#!/usr/bin/env python3
"""End-to-end: configure opencode ACP provider via disco daemon ACP stdio."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import uuid

REPO_ROOT = Path(__file__).resolve().parents[1]
DAEMON = os.environ.get(
    "DISCO_DAEMON",
    str(REPO_ROOT / "disco-daemon/target/debug/disco-daemon"),
)
OPENCODE_MODEL = os.environ.get("OPENCODE_MODEL", "opencode-go/kimi-k3")
SESSION_ID = str(uuid.uuid4())


def main():
    proc = subprocess.Popen(
        [DAEMON, "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    pending = {}

    def send(req):
        req["jsonrpc"] = "2.0"
        if "id" not in req:
            req["id"] = len(pending) + 1
        pending[req["id"]] = req
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        return req["id"]

    def read_until(pred, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline:
            remaining = deadline - time.time()
            ready, _, _ = select.select([proc.stdout], [], [], remaining)
            if not ready:
                break
            line = proc.stdout.readline()
            if not line:
                break
            msg = json.loads(line)
            if pred(msg):
                return msg
        return None

    # 1. initialize
    send({
        "method": "initialize",
        "params": {"protocolVersion": 1},
    })
    init = read_until(lambda m: m.get("id") == 1)
    assert init, "initialize 超时"
    print("[ok] initialize:", json.dumps(init.get("result", {}).get("agentCapabilities", {}), ensure_ascii=False))

    # 2. configure opencode provider
    send({
        "method": "_disco/provider/configure",
        "params": {
            "providerId": "opencode_app_server",
            "vendor": "opencode",
            "baseUrl": "",
            "apiKey": "",
            "model": OPENCODE_MODEL,
            "thinkingEnabled": False,
        },
    })
    cfg = read_until(lambda m: m.get("id") == 2)
    assert cfg, "configure 超时"
    if "error" in cfg:
        print("[FAIL] configure error:", json.dumps(cfg["error"], ensure_ascii=False))
        proc.kill()
        sys.exit(1)
    print("[ok] configure:", json.dumps(cfg.get("result"), ensure_ascii=False))

    # 3. list providers
    send({"method": "_disco/provider/list", "params": {}})
    lst = read_until(lambda m: m.get("id") == 3)
    assert lst, "list 超时"
    providers = lst.get("result", {}).get("providers", [])
    print("[ok] providers:", json.dumps(providers, ensure_ascii=False))

    # 4. session/new
    send({
        "method": "session/new",
        "params": {
            "cwd": str(REPO_ROOT),
            "mcpServers": [],
            "_meta": {
                "disco/providerId": "opencode_app_server",
                "disco/sessionId": SESSION_ID,
            },
        },
    })
    new = read_until(lambda m: m.get("id") == 4)
    assert new, "session/new 超时"
    if "error" in new:
        print("[FAIL] session/new error:", json.dumps(new["error"], ensure_ascii=False))
        proc.kill()
        sys.exit(1)
    print("[ok] session/new:", json.dumps(new.get("result"), ensure_ascii=False))

    # 5. session/prompt (runs opencode for real; keep it tiny)
    prompt_id = send({
        "method": "session/prompt",
        "params": {
            "sessionId": SESSION_ID,
            "prompt": [{"type": "text", "text": "Reply with exactly: pong"}],
        },
    })
    # 读取流式通知，直到该 prompt 的 JSON-RPC 响应返回。不能等待自定义的
    # end_turn 字段：ACP v1 的终止信息位于 prompt response 的 stopReason。
    while True:
        msg = read_until(
            lambda m: m.get("id") == prompt_id or m.get("method") == "session/update",
            timeout=120,
        )
        if msg is None:
            print("[FAIL] prompt 超时")
            proc.kill()
            sys.exit(1)
        if msg.get("method") == "session/update":
            raw_updates = msg.get("params", {}).get("updates")
            if raw_updates is None:
                raw_updates = msg.get("params", {}).get("update")
            updates = raw_updates if isinstance(raw_updates, list) else [raw_updates]
            for u in updates:
                if not isinstance(u, dict):
                    continue
                t = u.get("type", "")
                if t == "agent_message_chunk":
                    print("[stream]", u.get("delta", "")[:120], end="")
                elif t == "tool_call":
                    print(f"\n[tool] {u.get('toolName', '')} {json.dumps(u.get('input', {}), ensure_ascii=False)[:100]}")
        if msg.get("id") == prompt_id:
            if "error" in msg:
                print("\n[FAIL] prompt error:", json.dumps(msg["error"], ensure_ascii=False))
                proc.kill()
                sys.exit(1)
            print("\n[ok] prompt response:", json.dumps(msg.get("result"), ensure_ascii=False))
            break

    proc.kill()
    print("ALL PASS")


if __name__ == "__main__":
    main()
