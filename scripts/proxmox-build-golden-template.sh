#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/proxmox-api.sh
. "${SCRIPT_DIR}/proxmox-api.sh"

SOURCE_TEMPLATE_VMID="${SOURCE_TEMPLATE_VMID:-100}"
GOLDEN_TEMPLATE_NAME="${GOLDEN_TEMPLATE_NAME:-debian-golden-codex}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-local}"
ISO_STORAGE="${ISO_STORAGE:-local}"
SNIPPET_FILE="${SNIPPET_FILE:-${REPO_DIR}/cloud-init/debian-golden.yml}"
SNIPPET_NAME="$(basename "$SNIPPET_FILE")"
SEED_ISO_NAME="${GOLDEN_TEMPLATE_NAME}-seed.iso"

make_seed_iso() {
  local iso_path="$1"
  local seed_dir
  seed_dir="$(mktemp -d)"

  cp "$SNIPPET_FILE" "${seed_dir}/user-data"
  cat >"${seed_dir}/meta-data" <<META
instance-id: ${GOLDEN_TEMPLATE_NAME}
local-hostname: ${GOLDEN_TEMPLATE_NAME}
META

  rm -f "$iso_path"
  hdiutil makehybrid \
    -iso \
    -joliet \
    -default-volume-name cidata \
    -o "$iso_path" \
    "$seed_dir" >/dev/null
}

storage_json="$(api GET "/nodes/${NODE}/storage/${SNIPPET_STORAGE}/status")"
storage_content="$(json_get 'data["data"].get("content", "")' <<<"$storage_json")"
use_snippet=0

if [[ ",${storage_content}," == *",snippets,"* ]]; then
  use_snippet=1
fi

build_vmid="$(api GET "/cluster/nextid" | json_get_data)"
build_name="${GOLDEN_TEMPLATE_NAME}-build-${build_vmid}"

if [[ "$use_snippet" == "1" ]]; then
  echo "Uploading cloud-init snippet ${SNIPPET_NAME} to ${SNIPPET_STORAGE}"
  api POST "/nodes/${NODE}/storage/${SNIPPET_STORAGE}/upload" \
    -F "content=snippets" \
    -F "filename=@${SNIPPET_FILE}" >/dev/null
else
  iso_storage_json="$(api GET "/nodes/${NODE}/storage/${ISO_STORAGE}/status")"
  iso_storage_content="$(json_get 'data["data"].get("content", "")' <<<"$iso_storage_json")"
  if [[ ",${iso_storage_content}," != *",iso,"* ]]; then
    echo "Storage '${ISO_STORAGE}' does not allow ISO content: ${iso_storage_content}" >&2
    exit 1
  fi

  seed_iso_path="${REPO_DIR}/${SEED_ISO_NAME}"
  echo "Storage ${SNIPPET_STORAGE} does not allow snippets; uploading seed ISO ${SEED_ISO_NAME} to ${ISO_STORAGE}"
  make_seed_iso "$seed_iso_path"
  api POST "/nodes/${NODE}/storage/${ISO_STORAGE}/upload" \
    -H "Expect:" \
    -F "content=iso" \
    -F "filename=@${seed_iso_path}" >/dev/null
fi

echo "Cloning source template ${SOURCE_TEMPLATE_VMID} to build VM ${build_vmid} (${build_name})"
clone_upid="$(
  api POST "/nodes/${NODE}/qemu/${SOURCE_TEMPLATE_VMID}/clone" \
    --data-urlencode "newid=${build_vmid}" \
    --data-urlencode "name=${build_name}" \
    --data-urlencode "full=1" |
    json_get_data
)"
wait_for_task "$clone_upid"

echo "Configuring build VM cloud-init and guest agent"
if [[ "$use_snippet" == "1" ]]; then
  api PUT "/nodes/${NODE}/qemu/${build_vmid}/config" \
    --data-urlencode "agent=1" \
    --data-urlencode "ipconfig0=ip=dhcp" \
    --data-urlencode "cicustom=user=${SNIPPET_STORAGE}:snippets/${SNIPPET_NAME}" >/dev/null
else
  api PUT "/nodes/${NODE}/qemu/${build_vmid}/config" \
    --data-urlencode "agent=1" \
    --data-urlencode "delete=ide0" \
    --data-urlencode "ide2=${ISO_STORAGE}:iso/${SEED_ISO_NAME},media=cdrom" \
    --data-urlencode "boot=order=scsi0;ide2;net0" >/dev/null
fi

echo "Starting build VM ${build_vmid}; cloud-init will power it off when done"
start_upid="$(api POST "/nodes/${NODE}/qemu/${build_vmid}/status/start" | json_get_data)"
wait_for_task "$start_upid"

while true; do
  vm_status="$(api GET "/nodes/${NODE}/qemu/${build_vmid}/status/current" | json_get 'data["data"].get("status", "")')"
  if [[ "$vm_status" == "stopped" ]]; then
    break
  fi
  sleep 10
done

echo "Converting build VM ${build_vmid} to template ${GOLDEN_TEMPLATE_NAME}"
api PUT "/nodes/${NODE}/qemu/${build_vmid}/config" \
  --data-urlencode "name=${GOLDEN_TEMPLATE_NAME}" >/dev/null
template_upid="$(api POST "/nodes/${NODE}/qemu/${build_vmid}/template" | json_get_data)"
wait_for_task "$template_upid"

echo "Golden template ready: VMID ${build_vmid} (${GOLDEN_TEMPLATE_NAME})"
