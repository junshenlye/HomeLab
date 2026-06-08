#!/usr/bin/env python3
from __future__ import annotations

import argparse
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
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("command", nargs="+")
    args = parser.parse_args()

    env = load_env(Path(args.env_file))
    script = " ".join(args.command)
    response = api(
        env,
        "POST",
        f"/nodes/{args.node}/qemu/{args.vmid}/agent/exec",
        {"command": "/bin/bash", "input-data": f"set -euo pipefail\n{script}\n"},
    )
    pid = response["data"]["pid"]

    deadline = time.time() + args.timeout
    while time.time() < deadline:
        status = api(env, "GET", f"/nodes/{args.node}/qemu/{args.vmid}/agent/exec-status?pid={pid}")
        data = status["data"]
        if data.get("exited") == 1:
            out = data.get("out-data", "")
            err = data.get("err-data", "")
            if out:
                print(out, end="")
            if err:
                print(err, end="")
            raise SystemExit(int(data.get("exitcode") or 0))
        time.sleep(1)

    raise SystemExit("timed out waiting for guest command")


if __name__ == "__main__":
    main()
