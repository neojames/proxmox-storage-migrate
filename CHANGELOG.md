# Changelog

All notable changes to this project are documented here.

## [1.2.0-beta.3]

Beta: tagged for testing. A `*-beta*` tag builds the `.deb` and attaches it to
a GitHub Release marked **Pre-release** (a stable, no-auth download link) —
but unlike a `v*` tag, never publishes it to the apt repo. (`-beta.1` predates
this pipeline and never got a `.deb` built; `-beta.2` used a workflow artifact
instead of a pre-release. No functional changes since `-beta.1`.)

### Changed
- `-s`/`-t` no longer have defaults — they're required, from *some* source
  (a flag or the new config file below). Omitting both fails fast with a
  clear error and the usage text, instead of falling through to a confusing
  "storage '' not defined" error.

### Added
- `/etc/default/proxmox-storage-migrate`: an optional config file setting
  new defaults for any flag (`SRC_STORAGE`, `FORMAT`, `MAX_PARALLEL`, …).
  Precedence is built-in default < config file < command-line flag. Ships
  commented-out via the `.deb`; template also at
  `config/proxmox-storage-migrate.default` for checkout installs.

## [1.1.0]

### Changed
- Container volumes now always move offline: a running container's storage
  can't move live, so `migrate-disks.sh` shuts it down (graceful, then
  force), migrates every one of its volumes, and restarts it — deferred to a
  concurrent phase after the main pass, the same way TPM state is handled for
  VMs. This happens unconditionally (no flag), since it's required rather
  than optional.

### Added
- Debian packaging (`debian/`): installs as `/usr/bin/migrate-disks`, with a
  man page and `Depends` on `python3`/`openssh-client`. Pushing a `v*` tag
  builds the `.deb` and attaches it to a GitHub Release.
- Self-hosted, GPG-signed apt repo published to GitHub Pages
  (`neojames.github.io/proxmox-storage-migrate`): every tagged release is
  added automatically, so installed hosts pick up updates with a plain
  `apt update && apt upgrade` instead of re-downloading a `.deb` by hand.
- `install.sh`: one-line `curl | bash` installer that sets up the apt repo
  (verifying the signing key's fingerprint), runs `apt-get update`, and
  installs the package.

## [1.0.0]
Initial release. A single Bash tool to bulk-migrate Proxmox VE guest storage.

### Features
- Bulk-migrate VM disks (`qm move-disk`) and container volumes
  (`pct move-volume`) from a source storage to a target storage.
- Parallel migration across guests (configurable, default 5), with each guest's
  volumes moved strictly one at a time.
- VM disks converted to QCOW2 with automatic raw fallback on block storage
  (decided up front from storage type, plus a per-disk runtime fallback).
- `tpmstate` handled correctly: always raw; on running VMs either skipped and
  reported, or (with `-S`) deferred to a phase that gracefully shuts down
  (force after a grace window), moves, and restarts — without blocking the main
  migration.
- Container support, with bind/device mounts ignored.
- Cluster-wide mode (`-A`): moves run on each guest's owning node, locally or
  over SSH (node IP + HostKeyAlias, accept-new host keys), with an SSH
  reachability preflight.
- Per-move verification and detailed logging under a unique per-run directory.

- GitHub Actions CI runs shellcheck (warning severity) and the test suite on
  every push and PR.

### Notes
- Source volumes are deleted after a successful move unless `-k` is given.
- Ships with a mock-based test suite that needs no real Proxmox.
