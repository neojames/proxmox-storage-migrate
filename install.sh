#!/usr/bin/env bash
#
# install.sh — set up the proxmox-storage-migrate apt repo on this host and
# install the package. Run as root on a Proxmox VE (Debian-based) host:
#
#   curl -fsSL https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh | bash
#
# Safe to re-run: if already installed, it offers to upgrade (default) or
# remove; otherwise it just re-writes the key/source file and installs
# whatever's current.

set -euo pipefail

REPO_URL="https://neojames.github.io/proxmox-storage-migrate"
INSTALL_URL="https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh"
KEYRING="/usr/share/keyrings/proxmox-storage-migrate.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/proxmox-storage-migrate.list"
PACKAGE="proxmox-storage-migrate"
# The apt repo's signing key fingerprint (a repo-dedicated key, not tied to
# any personal identity). Update this if the key is ever rotated.
EXPECTED_FINGERPRINT="CFC6CD3A1A098F9844E4B30FD5D542163CFB456C"

# Set by --no-cluster-prompt, which this script passes to itself over SSH
# when fanning out to other cluster nodes below — so a remote leg installs
# only on itself instead of asking again and fanning out further.
SKIP_CLUSTER_PROMPT=0
for arg in "$@"; do
  case "$arg" in
    --no-cluster-prompt) SKIP_CLUSTER_PROMPT=1 ;;
  esac
done

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root, e.g.: curl -fsSL https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh | sudo bash"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer is for Debian/Proxmox VE hosts."
command -v curl >/dev/null 2>&1 || die "curl not found. Install it first: apt-get install -y curl"

# ---- already installed? offer to upgrade (default) or remove --------------
if [ "$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null || true)" = "install ok installed" ]; then
  CURRENT_VERSION="$(dpkg-query -W -f='${Version}' "$PACKAGE" 2>/dev/null || true)"
  log "$PACKAGE $CURRENT_VERSION is already installed."
  if [ -r /dev/tty ]; then
    ans=""
    read -r -p "Upgrade to the latest version, or remove it instead? [U/r] " ans </dev/tty || true
    if [[ "$ans" =~ ^[Rr] ]]; then
      log "Removing $PACKAGE..."
      apt-get remove -y "$PACKAGE"
      log "Removed. /etc/default/proxmox-storage-migrate was left in place (run 'apt purge $PACKAGE' to also delete it); the apt source ($SOURCES_FILE) and signing key ($KEYRING) were left in place too."
      exit 0
    fi
  fi
  log "Continuing to upgrade $PACKAGE..."
fi

log "Fetching signing key from $REPO_URL/KEY.gpg ..."
tmp_key="$(mktemp)"
trap 'rm -f "$tmp_key"' EXIT
curl -fsSL "$REPO_URL/KEY.gpg" -o "$tmp_key" || die "failed to download the signing key"

if command -v gpg >/dev/null 2>&1; then
  fp="$(gpg --with-colons --show-keys "$tmp_key" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  [ -n "$fp" ] || die "couldn't read a fingerprint from the downloaded key — refusing to trust it."
  if [ "$fp" != "$EXPECTED_FINGERPRINT" ]; then
    die "signing key fingerprint mismatch (got $fp, expected $EXPECTED_FINGERPRINT) — refusing to trust it. If the repo key was legitimately rotated, get an updated install.sh."
  fi
  log "Signing key fingerprint verified: $fp"
else
  log "NOTE: gpg not found, skipping fingerprint verification (apt will still verify signatures at update/install time via gpgv)."
fi

install -Dm644 "$tmp_key" "$KEYRING"
log "Installed signing key to $KEYRING"

echo "deb [signed-by=$KEYRING] $REPO_URL stable main" > "$SOURCES_FILE"
log "Wrote apt source to $SOURCES_FILE"

log "Running apt-get update..."
apt-get update

log "Installing $PACKAGE..."
apt-get install -y "$PACKAGE"

# ---- optional: also install on the rest of the cluster --------------------
# Only offered on an actual Proxmox host that's part of a *multi*-node
# cluster; a standalone node, a non-Proxmox host, or a remote leg of this
# same fan-out (--no-cluster-prompt) gets none of this.
if [ "$SKIP_CLUSTER_PROMPT" -eq 0 ] && [ -d /etc/pve/nodes ]; then
  LOCAL_NODE="$(basename "$(readlink -f /etc/pve/local 2>/dev/null)" 2>/dev/null || true)"
  OTHER_NODES=()
  if [ -n "$LOCAL_NODE" ] && [ "$LOCAL_NODE" != "." ]; then
    mapfile -t ALL_NODES < <(ls /etc/pve/nodes/ 2>/dev/null)
    for n in "${ALL_NODES[@]}"; do
      [ "$n" != "$LOCAL_NODE" ] && OTHER_NODES+=("$n")
    done
  fi

  if [ "${#OTHER_NODES[@]}" -gt 0 ] && [ -r /dev/tty ]; then
    echo
    echo "This node ($LOCAL_NODE) is part of a cluster with ${#OTHER_NODES[@]} other node(s): ${OTHER_NODES[*]}"
    ans=""
    read -r -p "Install $PACKAGE on those nodes too, over SSH? [y/N] " ans </dev/tty || true
    if [[ "$ans" =~ ^[Yy]$ ]]; then
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
      SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
      for n in "${OTHER_NODES[@]}"; do
        ip="$(node_ip "$n")"
        log "Installing on $n..."
        if [ -n "$ip" ]; then
          ssh "${SSH_OPTS[@]}" -o HostKeyAlias="$n" "root@$ip" \
            "curl -fsSL $INSTALL_URL | bash -s -- --no-cluster-prompt"
        else
          ssh "${SSH_OPTS[@]}" "root@$n" \
            "curl -fsSL $INSTALL_URL | bash -s -- --no-cluster-prompt"
        fi && log "$n: done" || log "$n: FAILED — install it manually, e.g.: ssh root@$n 'curl -fsSL $INSTALL_URL | bash'"
      done
    fi
  fi
fi

log "Done. Run 'proxmox-storage-migrate -h' to get started; future updates: apt update && apt upgrade."
