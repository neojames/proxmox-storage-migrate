#!/usr/bin/env bash
# Format handling: block-type target downgrades to raw up front; a file-type
# target that rejects qcow2 at runtime falls back to raw per-disk.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

echo "[case] block-storage target (zfspool) -> raw chosen up front, no qcow2 attempt"
mock_env_new
mock_add_node pve1 local
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting zfspool
mock_add_vm pve1 100 running 'scsi0: Neohosting:vm-100-disk-0,size=10G'
out="$(mock_run -V -y)"
assert_contains "$out" "raw instead of" "block-storage downgrade announced"
assert_calls "MOVE-DISK 100 scsi0 \[.*--format raw" "moved as raw"
assert_no_calls "MOVE-DISK 100 scsi0 \[.*qcow2" "qcow2 never attempted on block storage"
mock_env_cleanup

echo "[case] file target that rejects qcow2 at runtime -> per-disk raw fallback"
mock_env_new
mock_add_node pve1 local
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting dir     # file type: preflight keeps qcow2
mock_add_vm pve1 100 running 'scsi0: Neohosting:vm-100-disk-0,size=10G'
export MOCK_REJECT_QCOW2=1
out="$(mock_run -V -y)"
unset MOCK_REJECT_QCOW2
assert_calls "MOVE-DISK 100 scsi0 \[.*qcow2" "qcow2 attempted first"
assert_contains "$out" "retrying as raw" "fallback triggered"
assert_calls "MOVE-DISK 100 scsi0 \[.*--format raw" "retried as raw"
assert_contains "$out" "Raw fallbacks: 1" "counted as a raw fallback"
assert_contains "$out" "Success: 1  Failed: 0" "ultimately succeeded"
test_summary
