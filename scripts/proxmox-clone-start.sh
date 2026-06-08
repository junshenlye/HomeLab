#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/proxmox-api.sh
. "${SCRIPT_DIR}/proxmox-api.sh"

TEMPLATE_VMID="${TEMPLATE_VMID:-100}"
VM_NAME="${VM_NAME:-codex-deb-cli-test}"

next_vmid="$(api GET "/cluster/nextid" | json_get_data)"
echo "Cloning template ${TEMPLATE_VMID} on ${NODE} to VM ${next_vmid} (${VM_NAME})"

clone_upid="$(
  api POST "/nodes/${NODE}/qemu/${TEMPLATE_VMID}/clone" \
    --data-urlencode "newid=${next_vmid}" \
    --data-urlencode "name=${VM_NAME}" \
    --data-urlencode "full=1" |
    json_get_data
)"

wait_for_task "$clone_upid"
echo "Clone complete. Starting VM ${next_vmid}"

start_upid="$(api POST "/nodes/${NODE}/qemu/${next_vmid}/status/start" | json_get_data)"
wait_for_task "$start_upid"

echo "VM ${next_vmid} (${VM_NAME}) is started."
