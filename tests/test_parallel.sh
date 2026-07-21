#!/usr/bin/env bash
# Concurrency: never more than -p moves at once, and a single guest's volumes
# never overlap each other.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/mocks.sh"
trap mock_env_cleanup EXIT

mock_env_new
mock_add_node pve1 local
mock_add_storage Neohosting dir
mock_add_storage TN01SSD1600-NeoHosting dir

# 5 VMs; VM100 has 3 disks so we can check intra-guest serialization.
mock_add_vm pve1 100 running \
'scsi0: Neohosting:vm-100-disk-0,size=1G
scsi1: Neohosting:vm-100-disk-1,size=1G
virtio0: Neohosting:vm-100-disk-2,size=1G'
for id in 101 102 103 104; do
  mock_add_vm pve1 "$id" running "scsi0: Neohosting:vm-$id-disk-0,size=1G"
done

# Override move-disk to record a START/END timestamp per move. Peak concurrency
# is computed deterministically afterwards from those events (no racy counter).
qm() {
  case "$1" in
    move-disk)
      local id="$2" key="$3"
      echo "START $id $(date +%s.%N)" >> "$MOCK_CALLS"
      sleep 0.3
      echo "END $id $(date +%s.%N)" >> "$MOCK_CALLS"
      sed -i -E "s#^($key: )Neohosting:#\1TN01SSD1600-NeoHosting:#" "$(_mock_find_conf "$id")"; return 0 ;;
    status) echo "status: running" ;;
    *) return 0 ;;
  esac
}
export -f qm

mock_run -V -p 2 -y >/dev/null

# Peak concurrency = max running sum when START/END events are replayed in time order.
peak="$(awk '/^START /{print $3" 1"} /^END /{print $3" -1"}' "$MOCK_CALLS" \
        | sort -n | awk '{c+=$2; if(c>m)m=c} END{print m+0}')"
echo "  peak concurrent moves: $peak (limit 2)"
[ "$peak" -le 2 ] && echo "  PASS: concurrency never exceeded -p" || { echo "  FAIL: exceeded -p"; false; }
[ "$peak" -ge 2 ] && echo "  PASS: parallelism was actually exercised (reached the cap)" || { echo "  FAIL: never ran in parallel"; false; }

# Per-guest serialization: a guest's own moves must never overlap.
overlap="$(awk '/^START /{a[$2]++; if(a[$2]>1) print "overlap-"$2} /^END /{a[$2]--}' "$MOCK_CALLS")"
[ -z "$overlap" ] && echo "  PASS: no intra-guest overlap" || { echo "  FAIL: $overlap"; false; }
