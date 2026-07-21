#!/usr/bin/env bash
# Container volumes can only move while the container is stopped. A running
# container is always deferred: stop (graceful, then force), move every
# volume, restart — regardless of -S, which only governs VM tpmstate.
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
  mock_add_ct pve1 200 running \
'hostname: app
rootfs: Neohosting:subvol-200-disk-0,size=8G
mp0: Neohosting:subvol-200-disk-1,mp=/data,size=50G'
}

echo "[case] running container -> deferred, force-shutdown, volumes moved, restarted"
setup
out="$(mock_run -C -p 2 -y)"
assert_contains "$out" "ct 200@pve1: running" "container deferred to shutdown phase"
assert_contains "$out" "Phase 3:" "phase 3 ran"
assert_calls "SHUTDOWN 200 \[--timeout 300 --forceStop 1" "shutdown used graceful-then-force"
assert_calls "MOVE-VOL 200 rootfs \[.*running=stopped" "rootfs moved while stopped"
assert_calls "MOVE-VOL 200 mp0 \[.*running=stopped" "mp0 moved while stopped"
assert_calls "START 200" "container restarted afterwards"
assert_contains "$out" "Success: 2  Failed: 0" "both volumes migrated"
# ensure the container was stopped BEFORE either volume moved
awk '/SHUTDOWN 200/{s=NR} /MOVE-VOL 200/{if(!m)m=NR} END{exit !(s<m)}' "$MOCK_CALLS" \
  && echo "  PASS: shutdown happened before any volume move" || { echo "  FAIL: shutdown happened before any volume move"; false; }
mock_env_cleanup

echo "[case] stopped container -> migrated inline, no shutdown/restart"
setup; echo stopped > "$MOCK_STATE/200"
out="$(mock_run -C -p 2 -y)"
assert_contains "$out" "ct 200@pve1: rootfs OK" "rootfs migrated inline"
assert_contains "$out" "ct 200@pve1: mp0 OK" "mp0 migrated inline"
assert_no_calls "SHUTDOWN 200" "no shutdown for an already-stopped container"
assert_no_calls "START 200" "no restart for an already-stopped container"
assert_contains "$out" "Success: 2  Failed: 0" "both volumes migrated"
mock_env_cleanup

echo "[case] dry run on a running container -> reports deferral, no calls made"
setup
out="$(mock_run -C -n -y)"
assert_contains "$out" "DRY RUN" "dry run reported"
assert_contains "$out" "ct 200@pve1: DRY RUN" "container dry-run deferral logged"
assert_no_calls "SHUTDOWN 200" "no shutdown attempted in dry run"
assert_no_calls "MOVE-VOL 200" "no move attempted in dry run"
assert_no_calls "START 200" "no restart attempted in dry run"
test_summary
