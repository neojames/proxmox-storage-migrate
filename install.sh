#!/usr/bin/env bash
#
# install.sh — set up the proxmox-storage-migrate apt repo on this host and
# install the package. Run as root on a Proxmox VE (Debian-based) host:
#
#   curl -fsSL https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh | bash
#
# Safe to re-run: it just re-writes the key/source file and upgrades the
# package to whatever's current.

set -euo pipefail

REPO_URL="https://neojames.github.io/proxmox-storage-migrate"
KEYRING="/usr/share/keyrings/proxmox-storage-migrate.gpg"
SOURCES_FILE="/etc/apt/sources.list.d/proxmox-storage-migrate.list"
PACKAGE="proxmox-storage-migrate"
# The apt repo's signing key fingerprint (a repo-dedicated key, not tied to
# any personal identity). Update this if the key is ever rotated.
EXPECTED_FINGERPRINT="CFC6CD3A1A098F9844E4B30FD5D542163CFB456C"

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must be run as root, e.g.: curl -fsSL https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh | sudo bash"
command -v apt-get >/dev/null 2>&1 || die "apt-get not found — this installer is for Debian/Proxmox VE hosts."
command -v curl >/dev/null 2>&1 || die "curl not found. Install it first: apt-get install -y curl"

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

log "Done. Run 'proxmox-storage-migrate -h' to get started; future updates: apt update && apt upgrade."
