#!/usr/bin/env bash
# A VM's cloud-init drive (media=cdrom, like a real CD-ROM, but a real
# migratable volume named *-cloudinit) is discovered and moved; a genuine
# ISO-backed CD-ROM on the same storage is still excluded.
set -euo pipefail
# shellcheck source=lib/mocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

mock_env_new
mock_add_node pve1 local
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting dir

mock_add_vm pve1 100 stopped \
'name: web
scsi0: Neohosting:vm-100-disk-0,size=10G
ide2: Neohosting:vm-100-cloudinit,media=cdrom
ide3: Neohosting:iso/debian.iso,media=cdrom'

out="$(mock_run -y)"
echo "$out" | grep -E "Found|OK —|Done" | sed 's/^/  /'

assert_contains "$out" "Found 2 volume(s): 1 VM(s), 0 container(s)" "cloudinit counted, real ISO excluded"
assert_contains "$out" "vm 100@pve1: scsi0 OK" "regular disk migrated"
assert_contains "$out" "vm 100@pve1: ide2 OK" "cloudinit drive migrated"
assert_calls "MOVE-DISK 100 ide2" "cloudinit drive actually moved"
assert_no_calls "MOVE-DISK 100 ide3" "real ISO-backed cdrom never moved"
assert_contains "$out" "Success: 2  Failed: 0" "both real volumes succeeded"
test_summary
