#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${ENV_FILE:-.env.homelab.private}"
NODE="${PROXMOX_NODE:-pve01}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${PROXMOX_HOST:?PROXMOX_HOST is required}"
: "${PROXMOX_PORT:?PROXMOX_PORT is required}"
: "${PROXMOX_API_TOKEN_ID:?PROXMOX_API_TOKEN_ID is required}"
: "${PROXMOX_API_TOKEN_SECRET:?PROXMOX_API_TOKEN_SECRET is required}"

API_BASE="https://${PROXMOX_HOST}:${PROXMOX_PORT}/api2/json"
AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_API_TOKEN_ID}=${PROXMOX_API_TOKEN_SECRET}"

api() {
  local method="$1"
  local path="$2"
  shift 2

  curl -fsSk \
    -X "$method" \
    -H "$AUTH_HEADER" \
    "$@" \
    "${API_BASE}${path}"
}

json_get_data() {
  python3 -c 'import json,sys; print(json.load(sys.stdin)["data"])'
}

json_get() {
  local expr="$1"
  python3 -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

wait_for_task() {
  local upid="$1"
  local encoded_upid
  encoded_upid="$(urlencode "$upid")"

  while true; do
    local task_json task_state task_exit
    task_json="$(api GET "/nodes/${NODE}/tasks/${encoded_upid}/status")"
    task_state="$(json_get 'data["data"].get("status", "")' <<<"$task_json")"
    task_exit="$(json_get 'data["data"].get("exitstatus", "")' <<<"$task_json")"

    if [[ "$task_state" == "stopped" ]]; then
      if [[ "$task_exit" == "OK" ]]; then
        return 0
      fi

      echo "Task failed: ${task_exit}" >&2
      return 1
    fi

    sleep 2
  done
}

