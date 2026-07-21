#!/usr/bin/env bash
# /etc/default/proxmox-storage-migrate: optional, sourced before arg parsing.
# Sets new effective defaults when present; command-line flags still win.
set -euo pipefail
# shellcheck source=lib/mocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

setup() {
  mock_env_new
  mock_add_node pve1 local
  mock_add_storage Neohosting dir
  mock_add_storage TN01SSD1600-NeoHosting dir
  mock_add_vm pve1 100 stopped 'scsi0: Neohosting:vm-100-disk-0,size=10G'
}

echo "[case] no config file -> behaves exactly as without one"
setup
out="$(mock_run -y)"
assert_contains "$out" "VM disk format: qcow2" "built-in FORMAT default used"
assert_contains "$out" "Delete source after move: yes" "built-in DELETE_SRC default used"
mock_env_cleanup

echo "[case] config file sets FORMAT and DELETE_SRC -> used without matching flags"
setup
mock_set_config 'FORMAT="raw"
DELETE_SRC=""'
out="$(mock_run -y)"
assert_contains "$out" "VM disk format: raw" "FORMAT from config file took effect"
assert_contains "$out" "Delete source after move: no" "DELETE_SRC from config file took effect"
assert_calls "MOVE-DISK 100 scsi0 \[TN01SSD1600-NeoHosting --format raw\] " "no --delete passed through to the move"
mock_env_cleanup

echo "[case] command-line flag overrides the config file"
setup
mock_set_config 'FORMAT="raw"'
out="$(mock_run -f qcow2 -y)"
assert_contains "$out" "VM disk format: qcow2" "-f on the command line beats the config file"
mock_env_cleanup

echo "[case] config file supplies -s/-t so the command line can omit them entirely"
setup
mock_set_config 'SRC_STORAGE="Neohosting"
DST_STORAGE="TN01SSD1600-NeoHosting"'
rc=0; out="$(mock_run_no_defaults -y)" || rc=$?
assert_contains "$out" "Source : Neohosting" "SRC_STORAGE from config file took effect"
assert_contains "$out" "Target : TN01SSD1600-NeoHosting" "DST_STORAGE from config file took effect"
[ "$rc" -eq 0 ] && echo "  PASS: no required-args error (config file satisfied it)" || { echo "  FAIL: no required-args error (got rc=$rc)"; false; }
mock_env_cleanup

echo "[case] no config file and nothing on the command line -> required-args error"
setup
rc=0; out="$(mock_run_no_defaults -y)" || rc=$?
assert_contains "$out" "ERROR: -s <source storage> and -t <target storage> are required" "still required when neither config nor CLI supplies them"
[ "$rc" -eq 1 ] && echo "  PASS: exit code 1" || { echo "  FAIL: exit code 1 (got $rc)"; false; }

test_summary
