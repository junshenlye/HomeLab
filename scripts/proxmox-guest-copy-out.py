#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import json
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def api(env: dict[str, str], method: str, path: str, data: dict[str, str] | None = None) -> dict:
    url = f"https://{env['PROXMOX_HOST']}:{env['PROXMOX_PORT']}/api2/json{path}"
    encoded = None if data is None else urllib.parse.urlencode(data).encode()
    request = urllib.request.Request(url, data=encoded, method=method)
    token = f"{env['PROXMOX_API_TOKEN_ID']}={env['PROXMOX_API_TOKEN_SECRET']}"
    request.add_header("Authorization", f"PVEAPIToken={token}")
    context = ssl._create_unverified_context()
    with urllib.request.urlopen(request, context=context, timeout=30) as response:
        return json.loads(response.read())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", default=".env.homelab.private")
    parser.add_argument("--node", default="pve01")
    parser.add_argument("--vmid", required=True)
    parser.add_argument("--remote", required=True)
    parser.add_argument("--local", required=True)
    args = parser.parse_args()

    env = load_env(Path(args.env_file))
    command = f"base64 -w0 {urllib.parse.quote(args.remote, safe='/._-')}"
    exec_response = api(
        env,
        "POST",
        f"/nodes/{args.node}/qemu/{args.vmid}/agent/exec",
        {"command": "/bin/bash", "input-data": f"set -euo pipefail\n{command}\n"},
    )
    pid = exec_response["data"]["pid"]

    for _ in range(120):
        status = api(env, "GET", f"/nodes/{args.node}/qemu/{args.vmid}/agent/exec-status?pid={pid}")
        data = status["data"]
        if data.get("exited") == 1:
            if data.get("exitcode") != 0:
                raise SystemExit(data.get("err-data", f"guest command failed: {data.get('exitcode')}"))
            output = data.get("out-data", "")
            if data.get("out-truncated"):
                raise SystemExit("guest-agent output was truncated")
            local = Path(args.local)
            local.parent.mkdir(parents=True, exist_ok=True)
            local.write_bytes(base64.b64decode(output))
            print(f"copied {args.remote} -> {local}")
            return
        time.sleep(1)

    raise SystemExit("timed out waiting for guest command")


if __name__ == "__main__":
    main()
