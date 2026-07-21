#!/usr/bin/env bash
# Local-node discovery: VMs and containers on the source storage are found and
# moved; CD-ROMs and bind mounts are ignored; snapshot sections don't leak in.
set -euo pipefail
# shellcheck source=lib/mocks.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

mock_env_new
mock_add_node pve1 local
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting dir

mock_add_vm pve1 100 running \
'name: web
scsi0: Neohosting:vm-100-disk-0,size=10G
ide2: none,media=cdrom
[snap1]
scsi0: Neohosting:vm-100-disk-0,size=10G'
mock_add_ct pve1 200 \
'hostname: app
rootfs: Neohosting:subvol-200-disk-0,size=8G
mp0: Neohosting:subvol-200-disk-1,mp=/data,size=50G
mp1: /host/bind,mp=/bind'

out="$(mock_run -y)"
echo "$out" | grep -E "Found|OK —|Done" | sed 's/^/  /'

assert_contains "$out" "Found 3 volume(s): 1 VM(s), 1 container(s)" "cdrom + snapshot + bind mount excluded (3 real volumes)"
assert_contains "$out" "vm 100@pve1: scsi0 OK" "VM disk migrated"
assert_contains "$out" "ct 200@pve1: rootfs OK" "CT rootfs migrated"
assert_contains "$out" "ct 200@pve1: mp0 OK" "CT mountpoint migrated"
assert_no_calls "MOVE-VOL 200 mp1" "bind mount never moved"
assert_contains "$out" "Success: 3  Failed: 0" "all succeeded"
test_summary
