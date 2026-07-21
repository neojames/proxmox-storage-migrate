# shellcheck shell=bash
#
# Shared test harness for migrate-disks.sh.
#
# These helpers let the test suite run the real script against a *fake* Proxmox
# environment — no cluster, no root, no qm/pct/pvesm required. They:
#   * build a throwaway /etc/pve tree (nodes, guest configs, storage.cfg),
#   * stub qm / pct / pvesh / ssh as shell functions,
#   * path-redirect the script's hard-coded /etc/pve to the fake tree.
#
# A stubbed command is visible to `command -v`, so the script's sanity checks
# pass. Guest config files use the same syntax as real /etc/pve configs, so the
# script's real parsing/logic is exercised.

# Absolute path to the script under test (resolved from this file's location).
_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$_TESTS_DIR/../bin/migrate-disks.sh"

# Populated by mock_env_new; consumed by the stubs and by mock_run.
export MOCK_ROOT="" MOCK_PVE="" MOCK_STATE="" MOCK_CALLS=""

# Create a fresh fake environment. Sets MOCK_* globals. Call mock_env_cleanup
# when done (or rely on the EXIT trap the runner installs).
mock_env_new() {
  MOCK_ROOT="$(mktemp -d)"
  MOCK_PVE="$MOCK_ROOT/etc/pve"
  MOCK_STATE="$MOCK_ROOT/state"
  MOCK_CALLS="$MOCK_ROOT/calls"
  mkdir -p "$MOCK_PVE" "$MOCK_STATE"
  : > "$MOCK_CALLS"
  export MOCK_ROOT MOCK_PVE MOCK_STATE MOCK_CALLS
}

mock_env_cleanup() { if [ -n "${MOCK_ROOT:-}" ]; then rm -rf "$MOCK_ROOT"; fi; }

# mock_add_node <node> [local]  — create a node dir; mark it the local node.
mock_add_node() {
  local node="$1" is_local="${2:-}"
  mkdir -p "$MOCK_PVE/nodes/$node/qemu-server" "$MOCK_PVE/nodes/$node/lxc"
  if [ "$is_local" = local ]; then ln -sfn "$MOCK_PVE/nodes/$node" "$MOCK_PVE/local"; fi
}

# mock_add_storage <id> <type> [content]
mock_add_storage() {
  printf '%s: %s\n\tcontent %s\n' "$2" "$1" "${3:-images,rootdir}" >> "$MOCK_PVE/storage.cfg"
}

# mock_set_node_ip <node> <ip>  — populate /etc/pve/.members for SSH IP resolution.
mock_set_node_ip() {
  python3 - "$MOCK_PVE/.members" "$1" "$2" <<'PY'
import json, os, sys
path, node, ip = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path)) if os.path.exists(path) else {"nodelist": {}}
d.setdefault("nodelist", {})[node] = {"ip": ip}
json.dump(d, open(path, "w"))
PY
}

# mock_add_vm <node> <vmid> <running|stopped> <conf-body>
mock_add_vm() {
  printf '%s\n' "$4" > "$MOCK_PVE/nodes/$1/qemu-server/$2.conf"
  echo "$3" > "$MOCK_STATE/$2"
}

# mock_add_ct <node> <ctid> <conf-body>
mock_add_ct() {
  printf '%s\n' "$3" > "$MOCK_PVE/nodes/$1/lxc/$2.conf"
}

# Find a guest's config file by id across all nodes (ids are cluster-unique).
_mock_find_conf() {
  ls "$MOCK_PVE"/nodes/*/{qemu-server,lxc}/"$1".conf 2>/dev/null | head -1
}

# --- command stubs ---------------------------------------------------------
# Each records to $MOCK_CALLS and mutates the fake tree so the script's own
# verify step (which re-reads the config) sees a completed move.

qm() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list) echo "VMID NAME STATUS"; ls "$MOCK_PVE"/nodes/*/qemu-server/*.conf 2>/dev/null \
            | sed -E 's#.*/([0-9]+)\.conf#\1 guest running#' ;;
    status)  echo "status: $(cat "$MOCK_STATE/$1" 2>/dev/null || echo stopped)" ;;
    start)   echo "START $1" >> "$MOCK_CALLS"; echo running > "$MOCK_STATE/$1" ;;
    shutdown)
      local id="$1"; shift
      echo "SHUTDOWN $id [$*]" >> "$MOCK_CALLS"
      # --forceStop guarantees the VM ends up stopped (graceful or forced).
      echo stopped > "$MOCK_STATE/$id" ;;
    move-disk)
      local id="$1" key="$2"; shift 2
      echo "MOVE-DISK $id $key [$*] running=$(cat "$MOCK_STATE/$id" 2>/dev/null)" >> "$MOCK_CALLS"
      # If MOCK_REJECT_QCOW2=1, refuse any qcow2 attempt (simulates a storage
      # that reports as file-type but rejects qcow2). raw still succeeds.
      if [ "${MOCK_REJECT_QCOW2:-0}" = 1 ] && printf '%s' "$*" | grep -q 'qcow2'; then
        echo "storage does not support format 'qcow2'"; return 255
      fi
      sed -i -E "s#^($key: )Neohosting:#\1TN01SSD1600-NeoHosting:#" "$(_mock_find_conf "$id")"; return 0 ;;
    *) return 0 ;;
  esac
}

pct() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    list) echo "VMID Status Lock Name"; ls "$MOCK_PVE"/nodes/*/lxc/*.conf 2>/dev/null \
            | sed -E 's#.*/([0-9]+)\.conf#\1 running - guest#' ;;
    move-volume)
      local id="$1" key="$2"; shift 2
      echo "MOVE-VOL $id $key [$*]" >> "$MOCK_CALLS"
      sed -i -E "s#^($key: )Neohosting:#\1TN01SSD1600-NeoHosting:#" "$(_mock_find_conf "$id")"; return 0 ;;
    *) return 0 ;;
  esac
}

# ssh stub: strip -o options and user@host, record the target, run the rest
# locally (simulating remote execution against the same fake tree).
ssh() {
  echo "SSH-RAW: $*" >> "$MOCK_CALLS"          # full invocation incl. -o options
  local host=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) shift 2 ;;
      root@*) host="${1#root@}"; shift; break ;;
      *) shift ;;
    esac
  done
  echo "SSH->$host: $*" >> "$MOCK_CALLS"        # target + remote command
  "$@"
}

export -f qm pct ssh _mock_find_conf

# mock_run <args...>  — run the script against the fake tree, returning its
# stdout+stderr. Path-redirects /etc/pve to the fake tree.
mock_run() {
  local redir="$MOCK_ROOT/mig.sh"
  sed -e 's#/etc/pve#'"$MOCK_PVE"'#g' \
      -e 's#/var/log/migrate-disks-#'"$MOCK_ROOT"'/var/log/migrate-disks-#g' \
      "$SCRIPT_UNDER_TEST" > "$redir"
  bash "$redir" "$@" 2>&1
}

# --- tiny assertion helpers ------------------------------------------------
_T_PASS=0; _T_FAIL=0
assert_contains() { # <haystack-file-or-string-var> <needle> <message>
  if grep -q -- "$2" <<<"$1"; then echo "  PASS: $3"; _T_PASS=$((_T_PASS+1))
  else echo "  FAIL: $3"; _T_FAIL=$((_T_FAIL+1)); fi
}
assert_not_contains() {
  if grep -q -- "$2" <<<"$1"; then echo "  FAIL: $3"; _T_FAIL=$((_T_FAIL+1))
  else echo "  PASS: $3"; _T_PASS=$((_T_PASS+1)); fi
}
assert_calls() {    # <needle> <message>  (searches $MOCK_CALLS)
  if grep -q -- "$1" "$MOCK_CALLS"; then echo "  PASS: $2"; _T_PASS=$((_T_PASS+1))
  else echo "  FAIL: $2"; _T_FAIL=$((_T_FAIL+1)); fi
}
assert_no_calls() {
  if grep -q -- "$1" "$MOCK_CALLS"; then echo "  FAIL: $2"; _T_FAIL=$((_T_FAIL+1))
  else echo "  PASS: $2"; _T_PASS=$((_T_PASS+1)); fi
}
test_summary() { # returns nonzero if any assertion failed
  echo "  ---- $_T_PASS passed, $_T_FAIL failed ----"
  [ "$_T_FAIL" -eq 0 ]
}
