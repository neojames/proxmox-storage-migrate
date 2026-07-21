#!/usr/bin/env bash
# -s/-t are required: an empty or missing source/target storage must fail
# fast with a clear message and usage, not fall through to the (confusing)
# "storage '' not defined in storage.cfg" error.
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

echo "[case] both -s and -t missing (empty)"
setup
rc=0; out="$(mock_run -s '' -t '' -y)" || rc=$?
assert_contains "$out" "ERROR: -s <source storage> and -t <target storage> are required" "clear required-args error"
assert_contains "$out" "Usage: migrate-disks" "usage printed on error"
[ "$rc" -eq 1 ] && echo "  PASS: exit code 1" || { echo "  FAIL: exit code 1 (got $rc)"; false; }
mock_env_cleanup

echo "[case] only -t missing (empty)"
setup
rc=0; out="$(mock_run -s Neohosting -t '' -y)" || rc=$?
assert_contains "$out" "ERROR: -s <source storage> and -t <target storage> are required" "required-args error with only -t missing"
[ "$rc" -eq 1 ] && echo "  PASS: exit code 1" || { echo "  FAIL: exit code 1 (got $rc)"; false; }
mock_env_cleanup

echo "[case] only -s missing (empty)"
setup
rc=0; out="$(mock_run -s '' -t TN01SSD1600-NeoHosting -y)" || rc=$?
assert_contains "$out" "ERROR: -s <source storage> and -t <target storage> are required" "required-args error with only -s missing"
[ "$rc" -eq 1 ] && echo "  PASS: exit code 1" || { echo "  FAIL: exit code 1 (got $rc)"; false; }
mock_env_cleanup

echo "[case] both given -> proceeds past the required-args check"
setup
out="$(mock_run -s Neohosting -t TN01SSD1600-NeoHosting -y)"
assert_contains "$out" "vm 100@pve1: scsi0 OK" "migration proceeds normally when both are given"
test_summary
