#!/usr/bin/env bash
# Cluster mode (-A): guests on all nodes are discovered; moves run locally for
# local guests and over SSH (to the node IP, with HostKeyAlias) for remote ones.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

mock_env_new
mock_add_node pve1 local
mock_add_node JSB-SRV-PROX02
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting dir
mock_set_node_ip JSB-SRV-PROX02 10.9.9.2

mock_add_vm pve1 100 stopped 'scsi0: Neohosting:vm-100-disk-0,size=10G'
mock_add_vm JSB-SRV-PROX02 101 stopped 'scsi0: Neohosting:vm-101-disk-0,size=10G'
mock_add_ct JSB-SRV-PROX02 201 'rootfs: Neohosting:subvol-201-disk-0,size=8G'

echo "[case] without -A -> only the local node's guest"
out="$(mock_run -y)"
assert_contains "$out" "Found 1 volume(s)" "local-only discovery"
assert_contains "$out" "this node (pve1)" "scope reported as local"
: > "$MOCK_CALLS"
# reset local guest back to source for the cluster run
mock_add_vm pve1 100 stopped 'scsi0: Neohosting:vm-100-disk-0,size=10G'

echo "[case] with -A -> both nodes, remote ops over SSH by IP + HostKeyAlias"
out="$(mock_run -A -y)"
assert_contains "$out" "Found 3 volume(s)" "cluster-wide discovery"
assert_contains "$out" "whole cluster" "scope reported as cluster"
assert_contains "$out" "vm 100@pve1: scsi0 OK" "local VM migrated"
assert_contains "$out" "vm 101@JSB-SRV-PROX02: scsi0 OK" "remote VM migrated"
assert_contains "$out" "ct 201@JSB-SRV-PROX02: rootfs OK" "remote CT migrated"
assert_calls "SSH-RAW: .*HostKeyAlias=JSB-SRV-PROX02 root@10.9.9.2 qm move-disk 101" "remote VM move over SSH to node IP + HostKeyAlias"
assert_calls "SSH->10.9.9.2: pct move-volume 201" "remote CT move over SSH"
assert_no_calls "SSH->pve1" "local node never uses SSH"
test_summary
