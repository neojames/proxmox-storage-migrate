#!/usr/bin/env bash
# TPM state: forced raw (never qcow2); skipped on a running VM without -S;
# deferred to phase 2 with graceful-then-force shutdown when -S is given.
set -euo pipefail
# shellcheck source=lib/mocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

setup() {
  mock_env_new
  mock_add_node pve1 local
  mock_add_storage Neohosting dir
  mock_add_storage TN01SSD1600-NeoHosting dir
  mock_add_vm pve1 100 running \
'scsi0: Neohosting:vm-100-disk-0,size=10G
tpmstate0: Neohosting:vm-100-disk-9,size=4M'
}

echo "[case] running VM, no -S -> tpmstate skipped, disk still migrated"
setup
out="$(mock_run -V -p 2 -y)"
assert_contains "$out" "vm 100@pve1: scsi0 OK" "regular disk migrated"
assert_contains "$out" "tpmstate0 SKIPPED" "tpmstate skipped while running without -S"
assert_no_calls "MOVE-DISK 100 tpmstate0" "no tpmstate move attempted"
assert_contains "$out" "Skipped: 1" "reported as skipped"
mock_env_cleanup

echo "[case] running VM, with -S -> deferred, force-shutdown, raw move, restart"
setup
out="$(mock_run -V -S -p 2 -y)"
assert_contains "$out" "tpmstate0 deferred" "tpmstate deferred to phase 2"
assert_contains "$out" "Phase 2:" "phase 2 ran"
assert_calls "SHUTDOWN 100 \[--timeout 300 --forceStop 1" "shutdown used graceful-then-force"
assert_calls "MOVE-DISK 100 tpmstate0 \[.*--format raw.*running=stopped" "tpmstate moved as raw while stopped"
assert_calls "START 100" "VM restarted afterwards"
assert_contains "$out" "Success: 2  Failed: 0" "disk + tpmstate both succeeded"
# ensure the disk moved BEFORE the shutdown (minimal downtime ordering)
awk '/MOVE-DISK 100 scsi0/{m=NR} /SHUTDOWN 100/{s=NR} END{exit !(m<s)}' "$MOCK_CALLS" \
  && echo "  PASS: regular disk migrated before shutdown" || { echo "  FAIL"; false; }
mock_env_cleanup

echo "[case] stopped VM -> tpmstate moved inline as raw (no shutdown)"
setup; echo stopped > "$MOCK_STATE/100"
out="$(mock_run -V -p 2 -y)"
assert_calls "MOVE-DISK 100 tpmstate0 \[.*--format raw" "tpmstate moved as raw"
assert_no_calls "SHUTDOWN 100" "no shutdown for an already-stopped VM"
assert_contains "$out" "Success: 2" "both volumes migrated"
test_summary
