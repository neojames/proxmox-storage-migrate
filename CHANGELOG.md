# Changelog

All notable changes to this project are documented here.

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
