#!/usr/bin/env python3
"""直连 `opencode acp`，逐条打印 JSON-RPC request / response。

用法：python3 scripts/dump_opencode_acp.py [模型ID]
流程：initialize -> session/new -> set_config_option(model) -> set_config_option(effort=max)
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time

def find_opencode() -> str:
    configured = os.environ.get("OPENCODE_BIN")
    if configured:
        return configured
    discovered = shutil.which("opencode")
    if discovered:
        return discovered
    candidates = [
        Path.home() / ".opencode/bin/opencode",
        Path.home() / ".local/bin/opencode",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    raise FileNotFoundError(
        "找不到 opencode，请将其加入 PATH，或设置 OPENCODE_BIN"
    )

print_lock = threading.Lock()
responses = {}
responses_lock = threading.Lock()
response_event = threading.Condition(responses_lock)


def pretty(tag, msg):
    with print_lock:
        print(f"\n===== {tag} =====")
        print(json.dumps(msg, indent=2, ensure_ascii=False))
        sys.stdout.flush()


def reader(proc):
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            print("RAW:", line)
            continue
        if "id" in msg and ("result" in msg or "error" in msg):
            with response_event:
                responses[msg["id"]] = msg
                response_event.notify_all()
            pretty("RESPONSE", msg)
        elif "method" in msg and "id" not in msg:
            pretty("NOTIFICATION", msg)


def main():
    model = sys.argv[1] if len(sys.argv) > 1 else "opencode-go/kimi-k3"
    opencode = find_opencode()
    proc = subprocess.Popen(
        [opencode, "acp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
    )
    threading.Thread(target=reader, args=(proc,), daemon=True).start()
    next_id = 0

    def send(method, params):
        nonlocal next_id
        next_id += 1
        req = {"jsonrpc": "2.0", "id": next_id, "method": method, "params": params}
        pretty("REQUEST", req)
        proc.stdin.write(json.dumps(req) + "\n")
        proc.stdin.flush()
        return next_id

    def wait_response(rid, timeout=15):
        deadline = time.time() + timeout
        with response_event:
            while rid not in responses:
                remaining = deadline - time.time()
                if remaining <= 0:
                    return None
                response_event.wait(remaining)
            return responses[rid]

    send("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
    wait_response(1)

    send("session/new", {"cwd": "/tmp", "mcpServers": []})
    new = wait_response(2)
    session_id = new["result"]["sessionId"] if new and "result" in new else ""

    send(
        "session/set_config_option",
        {"sessionId": session_id, "configId": "model", "value": model},
    )
    wait_response(3)

    send(
        "session/set_config_option",
        {"sessionId": session_id, "configId": "effort", "value": "max"},
    )
    wait_response(4)

    time.sleep(1)
    proc.kill()


if __name__ == "__main__":
    main()
