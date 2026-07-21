#!/usr/bin/env bash
#
# migrate-disks.sh
#
# Mass-migrate every VM disk AND container volume on a source Proxmox storage
# to a target storage.
#   * VM disks convert to QCOW2 (auto-falling back to raw on block storage).
#   * tpmstate volumes are forced raw (never qcow2) and, since they can only
#     move while stopped, are skipped on running VMs unless -S is given.
#   * Container volumes move as-is (pct has no format option).
#
# Scope:
#   * Default: this node only.
#   * -A: the whole cluster. Guests are discovered from /etc/pve/nodes/*/ and
#     each move is executed on the node that owns the guest (locally, or over
#     SSH as root for remote nodes — the trust PVE sets up between cluster
#     members). Discovery and verification read the replicated /etc/pve config,
#     so they need no SSH.
#
# Migrations run in PARALLEL across guests (default 5). Volumes WITHIN a guest
# move one at a time (Proxmox locks the guest during each move).
#
# Run this ON a Proxmox host as root.
#
# Usage: ./migrate-disks.sh [options]
#   -s <storage>  Source storage        (default: Neohosting)
#   -t <storage>  Target storage         (default: TN01SSD1600-NeoHosting)
#   -f <format>   Preferred VM format     (default: qcow2; auto-falls back to raw)
#   -p <N>        Max guests in parallel  (default: 5)
#   -A            All nodes (whole cluster). Default is this node only.
#   -V            VMs only (skip containers)
#   -C            Containers only (skip VMs)
#   -S            Stop/move/start VMs to migrate offline-only volumes (tpmstate)
#   -k            Keep source volumes (omit --delete)
#   -n            Dry run
#   -y            Skip confirmation
#   -h            Help

set -euo pipefail

# ---- defaults -------------------------------------------------------------
SRC_STORAGE="Neohosting"
DST_STORAGE="TN01SSD1600-NeoHosting"
FORMAT="qcow2"
DELETE_SRC="--delete"
MAX_PARALLEL=5
CLUSTER=0
INCLUDE_VMS=1
INCLUDE_CTS=1
STOP_FOR_OFFLINE=0
GRACEFUL_TIMEOUT=300      # wait this long for a graceful shutdown, then force-stop
DRY_RUN=0
ASSUME_YES=0

# ---- help -----------------------------------------------------------------
usage() {
  cat <<'USAGE'
Usage: ./migrate-disks.sh [options]
  -s <storage>  Source storage        (default: Neohosting)
  -t <storage>  Target storage         (default: TN01SSD1600-NeoHosting)
  -f <format>   Preferred VM format     (default: qcow2; auto-falls back to raw)
  -p <N>        Max guests in parallel  (default: 5)
  -A            All nodes (whole cluster). Default is this node only.
  -V            VMs only (skip containers)
  -C            Containers only (skip VMs)
  -S            Stop/move/start VMs to migrate offline-only volumes (tpmstate)
  -k            Keep source volumes (omit --delete)
  -n            Dry run
  -y            Skip confirmation
  -h            Help
USAGE
  exit "${1:-0}"
}

# ---- arg parsing ----------------------------------------------------------
while getopts ":s:t:f:p:AVCSknyh" opt; do
  case "$opt" in
    s) SRC_STORAGE="$OPTARG" ;;
    t) DST_STORAGE="$OPTARG" ;;
    f) FORMAT="$OPTARG" ;;
    p) MAX_PARALLEL="$OPTARG" ;;
    A) CLUSTER=1 ;;
    V) INCLUDE_CTS=0 ;;
    C) INCLUDE_VMS=0 ;;
    S) STOP_FOR_OFFLINE=1 ;;
    k) DELETE_SRC="" ;;
    n) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage 0 ;;
    :) echo "Option -$OPTARG needs an argument." >&2; usage 1 ;;
    \?) echo "Unknown option -$OPTARG." >&2; usage 1 ;;
  esac
done

# ---- sanity checks --------------------------------------------------------
[[ "$MAX_PARALLEL" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: -p must be a positive integer." >&2; exit 1; }
if [ "$INCLUDE_VMS" -eq 0 ] && [ "$INCLUDE_CTS" -eq 0 ]; then
  echo "ERROR: -V and -C are mutually exclusive." >&2; exit 1
fi
[ -d /etc/pve/nodes ] || { echo "ERROR: /etc/pve/nodes not found — is this a Proxmox host?" >&2; exit 1; }
if [ "$INCLUDE_VMS" -eq 1 ]; then command -v qm  >/dev/null 2>&1 || { echo "ERROR: 'qm' not found."  >&2; exit 1; }; fi
if [ "$INCLUDE_CTS" -eq 1 ]; then command -v pct >/dev/null 2>&1 || { echo "ERROR: 'pct' not found." >&2; exit 1; }; fi

# Authoritative local node name (symlink to this node's dir under /etc/pve).
LOCAL_NODE="$(basename "$(readlink -f /etc/pve/local 2>/dev/null)" 2>/dev/null || hostname)"

# Storage type comes straight from the cluster-wide storage.cfg ("type: id"),
# so it works even when the target isn't mounted on the orchestrator node.
get_storage_type() {
  awk -v s="$1" '/^[[:alpha:]]+:[[:space:]]/{t=$1; sub(/:$/,"",t); if($2==s){print t; exit}}' /etc/pve/storage.cfg 2>/dev/null
}
SRC_TYPE="$(get_storage_type "$SRC_STORAGE")"
DST_TYPE="$(get_storage_type "$DST_STORAGE")"
[ -n "$SRC_TYPE" ] || { echo "ERROR: source storage '$SRC_STORAGE' not defined in /etc/pve/storage.cfg" >&2; exit 1; }
[ -n "$DST_TYPE" ] || { echo "ERROR: target storage '$DST_STORAGE' not defined in /etc/pve/storage.cfg" >&2; exit 1; }

# ---- logging setup --------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="/var/log/migrate-disks-$TS-$$"
mkdir -p "$LOGDIR/results" "$LOGDIR/results-deferred"
DEFERRED_LIST="$LOGDIR/deferred.list"; : > "$DEFERRED_LIST"
MAIN_LOG="$LOGDIR/main.log"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$MAIN_LOG"; }

[ "$DRY_RUN" -eq 1 ] && MAX_PARALLEL=1

# ---- pre-flight: pick a VM format the target can actually store -----------
DOWNGRADED=0
case " qcow2 vmdk " in
  *" $FORMAT "*)
    case "$DST_TYPE" in
      lvm|lvmthin|zfspool|rbd|iscsi|iscsidirect|drbd) FORMAT="raw"; DOWNGRADED=1 ;;
    esac ;;
esac

# ---- node runner: local direct, remote over SSH ---------------------------
# Resolve a node's cluster IP from /etc/pve/.members (best effort) so we can
# connect even when the node name doesn't resolve, using -o HostKeyAlias so the
# host key PVE stores under the node name is still matched (mirrors how PVE
# itself SSHes between nodes).
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

node_ip() {
  python3 - "$1" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open('/etc/pve/.members'))
    print(d.get('nodelist', {}).get(sys.argv[1], {}).get('ip', ''))
except Exception:
    pass
PY
}

ssh_node() {  # $1=node; rest=command
  local node="$1"; shift
  local ip; ip="$(node_ip "$node")"
  if [ -n "$ip" ]; then
    ssh "${SSH_OPTS[@]}" -o HostKeyAlias="$node" "root@$ip" "$@"
  else
    ssh "${SSH_OPTS[@]}" "root@$node" "$@"
  fi
}

run_on() {  # $1=node; rest=command + args
  local node="$1"; shift
  if [ "$node" = "$LOCAL_NODE" ]; then
    "$@"
  else
    ssh_node "$node" "$@"
  fi
}

echo "Logging to $LOGDIR"
echo "Scope  : $([ "$CLUSTER" -eq 1 ] && echo 'whole cluster' || echo "this node ($LOCAL_NODE)")"
echo "Source : $SRC_STORAGE (type: $SRC_TYPE)"
echo "Target : $DST_STORAGE (type: $DST_TYPE)"
echo "Guests : $([ "$INCLUDE_VMS" -eq 1 ] && echo -n 'VMs '; [ "$INCLUDE_CTS" -eq 1 ] && echo -n 'containers')"
echo "VM disk format: $FORMAT   (containers: storage-native)"
echo "Parallel guests: $MAX_PARALLEL"
echo "TPM state on running VMs: $([ "$STOP_FOR_OFFLINE" -eq 1 ] && echo "deferred phase — graceful ${GRACEFUL_TIMEOUT}s then force-stop, move, restart" || echo "skip + report")"
echo "Delete source after move: $([ -n "$DELETE_SRC" ] && echo yes || echo no)"
echo "Dry run: $([ "$DRY_RUN" -eq 1 ] && echo yes || echo no)"
echo
[ "$DOWNGRADED" -eq 1 ] && log "Target is block type '$DST_TYPE' — VM disks will use raw instead of the requested file-only format."

# ---- build the work list, grouped by guest --------------------------------
# Unit key: "vm:<node>:<id>" or "ct:<node>:<id>". Volumes read directly from
# the replicated /etc/pve config (top section only; snapshots start with '[').
VM_DISK_RE='^(ide[0-9]+|sata[0-9]+|scsi[0-9]+|virtio[0-9]+|efidisk[0-9]+|tpmstate[0-9]+|unused[0-9]+):'
CT_VOL_RE='^(rootfs|mp[0-9]+|unused[0-9]+):'
declare -A UNIT_VOLS=()
declare -a UNIT_ORDER=()
total_vols=0; vm_count=0; ct_count=0

add_vol() {  # $1=unit  $2="key vol"  $3=vm|ct
  local u="$1" entry="$2"
  if [[ -z "${UNIT_VOLS[$u]:-}" ]]; then
    UNIT_ORDER+=("$u"); UNIT_VOLS[$u]="$entry"
    case "$3" in vm) vm_count=$((vm_count+1)) ;; ct) ct_count=$((ct_count+1)) ;; esac
  else
    UNIT_VOLS[$u]+=$'\n'"$entry"
  fi
  total_vols=$((total_vols+1))
}

scan_conf() {  # $1=conf file  $2=vm|ct  $3=unit-prefix (type:node)
  local conf="$1" kind="$2" prefix="$3" id re line key val vol
  id="$(basename "$conf" .conf)"
  [ "$kind" = vm ] && re="$VM_DISK_RE" || re="$CT_VOL_RE"
  while IFS= read -r line; do
    [[ "$line" =~ ^\[ ]] && break                 # stop at first snapshot section
    [[ "$line" =~ $re ]] || continue
    key="${line%%:*}"; val="${line#*: }"; vol="${val%%,*}"
    [[ "$val" == *"media=cdrom"* ]] && continue
    [[ "$vol" == "none" ]] && continue
    [[ "$vol" == "${SRC_STORAGE}:"* ]] || continue   # bind mounts / other storages skipped
    add_vol "$prefix:$id" "$key $vol" "$kind"
  done < "$conf"
}

if [ "$CLUSTER" -eq 1 ]; then
  mapfile -t NODES < <(ls /etc/pve/nodes/ 2>/dev/null)
else
  NODES=("$LOCAL_NODE")
fi

for node in "${NODES[@]}"; do
  if [ "$INCLUDE_VMS" -eq 1 ]; then
    for conf in /etc/pve/nodes/"$node"/qemu-server/*.conf; do
      [ -e "$conf" ] || continue; scan_conf "$conf" vm "vm:$node"
    done
  fi
  if [ "$INCLUDE_CTS" -eq 1 ]; then
    for conf in /etc/pve/nodes/"$node"/lxc/*.conf; do
      [ -e "$conf" ] || continue; scan_conf "$conf" ct "ct:$node"
    done
  fi
done

if [ "$total_vols" -eq 0 ]; then
  log "Nothing to do: no volumes found on storage '$SRC_STORAGE'."
  exit 0
fi

echo "Found $total_vols volume(s): $vm_count VM(s), $ct_count container(s)"
for u in "${UNIT_ORDER[@]}"; do
  IFS=: read -r utype unode uid <<<"$u"
  echo "  $utype $uid on $unode:"
  while IFS= read -r d; do [ -n "$d" ] && printf '    %s\n' "$d"; done <<< "${UNIT_VOLS[$u]}"
done
echo

# ---- SSH reachability check for remote nodes that hold work ---------------
if [ "$CLUSTER" -eq 1 ]; then
  declare -A need_node=()
  for u in "${UNIT_ORDER[@]}"; do IFS=: read -r _ n _ <<<"$u"; need_node[$n]=1; done
  unreachable=()
  for n in "${!need_node[@]}"; do
    [ "$n" = "$LOCAL_NODE" ] && continue
    err="$(ssh_node "$n" true 2>&1)" || unreachable+=("$n | ${err:-connection failed}")
  done
  if [ "${#unreachable[@]}" -gt 0 ]; then
    echo "ERROR: cannot reach node(s) over SSH (cluster mode runs each move on the owning node):" >&2
    for e in "${unreachable[@]}"; do echo "  - $e" >&2; done
    echo >&2
    echo "To fix, from this node ($LOCAL_NODE) get root SSH working to each node above, e.g.:" >&2
    echo "  ssh root@<node> true          # accept the host key / confirm login works" >&2
    echo "  ping <node>                   # if it can't resolve, check /etc/hosts or DNS" >&2
    echo "Or skip SSH entirely: run this script WITHOUT -A on each node in turn — each" >&2
    echo "node then migrates only its own guests locally (no inter-node SSH needed)." >&2
    exit 1
  fi
fi

# ---- confirmation ---------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Proceed migrating ${#UNIT_ORDER[@]} guest(s)$([ "$CLUSTER" -eq 1 ] && echo ' across the cluster'), up to $MAX_PARALLEL in parallel? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ---- helpers (inherited by the parallel workers) --------------------------
verify_moved() {  # $1=vm|ct  $2=node  $3=id  $4=key   (reads replicated config)
  local kind="$1" node="$2" id="$3" key="$4" conf cfgline
  if [ "$kind" = vm ]; then conf="/etc/pve/nodes/$node/qemu-server/$id.conf"
  else conf="/etc/pve/nodes/$node/lxc/$id.conf"; fi
  cfgline="$(awk -v k="^${key}:" 'BEGIN{f=0} /^\[/{exit} $0 ~ k{print; f=1; exit} END{}' "$conf" 2>/dev/null || true)"
  [ -z "$cfgline" ] && return 0
  [[ "$cfgline" == *"${DST_STORAGE}:"* ]] && return 0
  return 1
}

MOVE_OUT=""
attempt_move_vm() {  # $1=node $2=id $3=key $4=format ("" omits --format)
  local node="$1" id="$2" key="$3" fmt="$4" tmp rc=0
  tmp="$(mktemp)"
  local cmd=(qm move-disk "$id" "$key" "$DST_STORAGE")
  [ -n "$fmt" ] && cmd+=(--format "$fmt")
  [ -n "$DELETE_SRC" ] && cmd+=("$DELETE_SRC")
  run_on "$node" "${cmd[@]}" >"$tmp" 2>&1 || rc=$?
  cat "$tmp" >> "${WORKER_LOG:-$MAIN_LOG}"; MOVE_OUT="$(cat "$tmp")"; rm -f "$tmp"
  return "$rc"
}

attempt_move_ct() {  # $1=node $2=id $3=key   (pct has no --format)
  local node="$1" id="$2" key="$3" tmp rc=0
  tmp="$(mktemp)"
  run_on "$node" pct move-volume "$id" "$key" "$DST_STORAGE" ${DELETE_SRC:+"$DELETE_SRC"} >"$tmp" 2>&1 || rc=$?
  cat "$tmp" >> "${WORKER_LOG:-$MAIN_LOG}"; MOVE_OUT="$(cat "$tmp")"; rm -f "$tmp"
  return "$rc"
}

is_format_error() {
  printf '%s' "$MOVE_OUT" | grep -qiE \
    "does not support|not supported|unsupported|only supports|invalid format|format .*(qcow2|vmdk)"
}

vm_is_running() {  # $1=node $2=id
  run_on "$1" qm status "$2" 2>/dev/null | grep -q 'status: running'
}

# ---- per-guest worker -----------------------------------------------------
process_unit() {
  local unit="$1"
  local utype unode uid; IFS=: read -r utype unode uid <<<"$unit"
  local WORKER_LOG="$LOGDIR/${utype}-${unode}-${uid}.log"
  local ok=0 fail=0 raw=0 skipped=0 used_fmt move_ok key vol d dry_fmt
  trap 'echo "$ok $fail $raw $skipped" > "$LOGDIR/results/${utype}-${unode}-${uid}"' EXIT

  while IFS= read -r d; do
    [ -z "$d" ] && continue
    key="${d%% *}"; vol="${d#* }"

    if [ "$DRY_RUN" -eq 1 ]; then
      if [ "$utype" = vm ]; then
        if [[ "$key" =~ ^tpmstate[0-9]+$ ]] && vm_is_running "$unode" "$uid"; then
          [ "$STOP_FOR_OFFLINE" -eq 1 ] \
            && log "vm $uid@$unode: DRY RUN would DEFER $key — phase 2: graceful ${GRACEFUL_TIMEOUT}s then force-stop, move raw, restart" \
            || log "vm $uid@$unode: DRY RUN would SKIP $key (VM running; needs -S)"
        else
          dry_fmt="$FORMAT"; [[ "$key" =~ ^tpmstate[0-9]+$ ]] && dry_fmt="raw"
          log "vm $uid@$unode: DRY RUN qm move-disk $uid $key $DST_STORAGE --format $dry_fmt ${DELETE_SRC}"
        fi
      else
        log "ct $uid@$unode: DRY RUN pct move-volume $uid $key $DST_STORAGE ${DELETE_SRC}"
      fi
      continue
    fi

    move_ok=0; used_fmt="native"
    if [ "$utype" = vm ]; then
      if [[ "$key" =~ ^tpmstate[0-9]+$ ]]; then
        used_fmt="raw"
        if vm_is_running "$unode" "$uid"; then
          if [ "$STOP_FOR_OFFLINE" -eq 0 ]; then
            log "vm $uid@$unode: $key SKIPPED — TPM state can't move while VM runs. Stop it and re-run, or use -S."
            skipped=$((skipped+1)); continue
          fi
          # Don't block this slot waiting for a shutdown — hand the VM off to
          # the deferred phase, which runs after the main pass completes.
          printf '%s %s %s\n' "$unode" "$uid" "$key" >> "$DEFERRED_LIST"
          log "vm $uid@$unode: $key deferred — will stop/move/restart in the shutdown phase"
          continue
        else
          log "vm $uid@$unode: moving $key ($vol) -> $DST_STORAGE [raw — tpmstate must stay raw]"
          if attempt_move_vm "$unode" "$uid" "$key" "raw"; then move_ok=1
          elif is_format_error && attempt_move_vm "$unode" "$uid" "$key" ""; then move_ok=1; fi
        fi
      else
        used_fmt="$FORMAT"
        log "vm $uid@$unode: moving $key ($vol) -> $DST_STORAGE [$FORMAT]"
        if attempt_move_vm "$unode" "$uid" "$key" "$FORMAT"; then move_ok=1
        elif [ "$FORMAT" != "raw" ] && is_format_error; then
          log "vm $uid@$unode: $key — '$FORMAT' rejected, retrying as raw"
          if attempt_move_vm "$unode" "$uid" "$key" "raw"; then move_ok=1; used_fmt="raw"; raw=$((raw+1)); fi
        fi
      fi
    else
      log "ct $uid@$unode: moving $key ($vol) -> $DST_STORAGE"
      if attempt_move_ct "$unode" "$uid" "$key"; then move_ok=1; fi
    fi

    if [ "$move_ok" -eq 1 ] && verify_moved "$utype" "$unode" "$uid" "$key"; then
      log "$utype $uid@$unode: $key OK — verified on $DST_STORAGE (format: $used_fmt)"; ok=$((ok+1))
    elif [ "$move_ok" -eq 1 ]; then
      log "$utype $uid@$unode: $key move reported success but still references $SRC_STORAGE — CHECK MANUALLY"; fail=$((fail+1))
    else
      log "$utype $uid@$unode: $key FAILED (see $WORKER_LOG) — continuing"; fail=$((fail+1))
    fi
  done <<< "${UNIT_VOLS[$unit]}"
}

# ---- deferred worker: shut down (force after grace), move tpmstate, restart -
process_deferred_tpm() {  # $1=node $2=id $3=key
  local node="$1" id="$2" key="$3"
  local WORKER_LOG="$LOGDIR/vm-${node}-${id}.log"
  local ok=0 fail=0 moved=0
  trap 'echo "$ok $fail 0 0" > "$LOGDIR/results-deferred/vm-${node}-${id}-${key}"' EXIT

  log "vm $id@$node: [phase 2] shutting down (graceful ${GRACEFUL_TIMEOUT}s, then force) to move $key"
  if ! run_on "$node" qm shutdown "$id" --timeout "$GRACEFUL_TIMEOUT" --forceStop 1 >>"$WORKER_LOG" 2>&1; then
    log "vm $id@$node: [phase 2] $key FAILED — VM would not stop even with force (see $WORKER_LOG)"
    fail=1; return
  fi
  log "vm $id@$node: [phase 2] stopped; moving $key as raw"
  if attempt_move_vm "$node" "$id" "$key" "raw"; then moved=1
  elif is_format_error && attempt_move_vm "$node" "$id" "$key" ""; then moved=1; fi
  log "vm $id@$node: [phase 2] restarting VM"
  run_on "$node" qm start "$id" >>"$WORKER_LOG" 2>&1 || log "vm $id@$node: [phase 2] WARNING — failed to restart, START MANUALLY"
  if [ "$moved" -eq 1 ] && verify_moved vm "$node" "$id" "$key"; then
    log "vm $id@$node: $key OK — verified on $DST_STORAGE (format: raw)"; ok=1
  else
    log "vm $id@$node: $key FAILED after shutdown — CHECK MANUALLY"; fail=1
  fi
}

# ---- dispatch -------------------------------------------------------------
log "Starting: $total_vols volume(s) across ${#UNIT_ORDER[@]} guest(s), up to $MAX_PARALLEL parallel."
for u in "${UNIT_ORDER[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do
    wait -n 2>/dev/null || sleep 1
  done
  process_unit "$u" &
done
wait

# ---- phase 2: deferred tpmstate VMs (shut down, move, restart) ------------
# These were skipped in the main pass so no slot ever idled on a shutdown.
# Shutdowns run concurrently (graceful, then force after GRACEFUL_TIMEOUT), so
# while one VM is powering off the others are too.
if [ -s "$DEFERRED_LIST" ]; then
  ndef="$(wc -l < "$DEFERRED_LIST")"
  log "Phase 2: $ndef VM(s) with tpmstate to shut down, move, and restart (up to $MAX_PARALLEL at once)."
  while read -r dn di dk; do
    [ -n "$dn" ] || continue
    while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do
      wait -n 2>/dev/null || sleep 1
    done
    process_deferred_tpm "$dn" "$di" "$dk" &
  done < "$DEFERRED_LIST"
  wait
fi

# ---- aggregate ------------------------------------------------------------
tot_ok=0; tot_fail=0; tot_raw=0; tot_skip=0
for u in "${UNIT_ORDER[@]}"; do
  IFS=: read -r utype unode uid <<<"$u"
  rf="$LOGDIR/results/${utype}-${unode}-${uid}"
  if [ -f "$rf" ]; then
    read -r o f r s < "$rf"
    tot_ok=$((tot_ok+o)); tot_fail=$((tot_fail+f)); tot_raw=$((tot_raw+r)); tot_skip=$((tot_skip+${s:-0}))
  else
    log "WARNING: no result for $u (worker may have crashed) — see $LOGDIR/${utype}-${unode}-${uid}.log"
    tot_fail=$((tot_fail+1))
  fi
done
# add deferred-phase (tpmstate) results
for rf in "$LOGDIR"/results-deferred/*; do
  [ -e "$rf" ] || continue
  read -r o f r s < "$rf"
  tot_ok=$((tot_ok+o)); tot_fail=$((tot_fail+f)); tot_raw=$((tot_raw+${r:-0})); tot_skip=$((tot_skip+${s:-0}))
done

echo
log "Done. Success: $tot_ok  Failed: $tot_fail  Skipped: $tot_skip  Raw fallbacks: $tot_raw  (dry run: $DRY_RUN)"
[ "$tot_skip" -gt 0 ] && log "NOTE: $tot_skip volume(s) skipped (tpmstate on running VMs). Re-run with -S, or stop those VMs and re-run."
log "Logs: $MAIN_LOG  (+ per-guest logs in $LOGDIR)"
[ "$tot_fail" -eq 0 ]
