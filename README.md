# proxmox-storage-migrate

[![CI](https://github.com/neojames/proxmox-storage-migrate/actions/workflows/ci.yml/badge.svg)](https://github.com/neojames/proxmox-storage-migrate/actions/workflows/ci.yml)

Bulk-migrate Proxmox VE guest storage from one storage to another — across an
entire cluster, in parallel — with sensible handling of the awkward cases
(QCOW2 vs raw, TPM state, containers, running guests).

It wraps `qm move-disk` and `pct move-volume` with discovery, parallelism,
format handling, verification, and logging, so you don't have to click through
every disk of every guest by hand.

> **Heads up:** this moves real data and can delete the source copy. Always run
> a dry run (`-n`) first and read the plan before committing.

## What it does

- **Discovers every guest volume** on a source storage from the replicated
  `/etc/pve` config — VMs (`qm`) and containers (`pct`) — and migrates each to
  the target storage.
- **Runs in parallel across guests** (default 5 at a time) while keeping a
  single guest's volumes strictly sequential, because Proxmox locks a guest for
  the duration of each move.
- **Converts VM disks to QCOW2**, automatically falling back to `raw` when the
  target is block storage (LVM/LVM-thin/ZFS/Ceph/RBD/iSCSI) that can't hold
  QCOW2 — decided up front from the storage type, with a per-disk runtime
  fallback as a safety net.
- **Handles TPM state correctly**: `tpmstate` volumes are always `raw` and can
  only move while the VM is stopped. On a running VM they're skipped and
  reported by default, or (with `-S`) deferred to a phase that shuts the VM
  down gracefully — force-stopping after a grace window — moves the volume, and
  restarts it. Regular disks migrate live first, so downtime is just the tiny
  TPM-state move.
- **Migrates containers** as-is (no format flag; the target storage decides the
  on-disk format). Bind mounts and device mounts are ignored automatically. A
  container's volumes can only move while it's stopped, so a running container
  is always (no flag needed) stopped, fully migrated, and restarted in a
  deferred phase — mirroring how TPM state is handled for VMs.
- **Runs cluster-wide** (`-A`): each move executes on the node that owns the
  guest — locally, or over SSH to remote nodes the way Proxmox itself does
  (node IP + `HostKeyAlias`, accepting new host keys).
- **Verifies every move** by re-reading the guest config, and writes a full log
  plus per-guest logs under `/var/log/migrate-disks-<timestamp>-<pid>/`.

## Requirements

- A Proxmox VE node, run as **root**.
- `qm` and/or `pct`, `pvesm`/`/etc/pve`, and `python3` (used for cluster IP
  resolution).
- For cluster mode: working passwordless root SSH between nodes (standard in a
  healthy PVE cluster).

## Installation

### From the apt repo (recommended)

Every tagged release is published to a self-hosted apt repo on GitHub Pages,
so hosts can just `apt upgrade` to pick up new versions. On the Proxmox host,
as root:

```bash
curl -fsSL https://raw.githubusercontent.com/neojames/proxmox-storage-migrate/main/install.sh | bash
```

This adds the apt repo (verifying the signing key's fingerprint before
trusting it), runs `apt update`, and installs the package — safe to re-run any
time to pick up a new release. Prefer to do it by hand, or can't pipe a script
into `bash`? Same three steps, spelled out:

```bash
curl -fsSL https://neojames.github.io/proxmox-storage-migrate/KEY.gpg \
  -o /usr/share/keyrings/proxmox-storage-migrate.gpg

echo "deb [signed-by=/usr/share/keyrings/proxmox-storage-migrate.gpg] https://neojames.github.io/proxmox-storage-migrate/ stable main" \
  > /etc/apt/sources.list.d/proxmox-storage-migrate.list

apt update
apt install proxmox-storage-migrate
```

From then on, `apt update && apt upgrade` picks up new releases. Packages are
signed with a repo-dedicated GPG key (not tied to any personal identity).

This installs the tool as `migrate-disks` on your `PATH`, plus a man page
(`man migrate-disks`). From here on, replace `bin/migrate-disks.sh` in the
examples below with `migrate-disks`.

### From a standalone `.deb`

Every tagged release also publishes the `.deb` directly on the
[Releases page](https://github.com/neojames/proxmox-storage-migrate/releases),
for hosts that can't reach the apt repo:

```bash
wget https://github.com/neojames/proxmox-storage-migrate/releases/download/vX.Y.Z/proxmox-storage-migrate_X.Y.Z_all.deb
apt install ./proxmox-storage-migrate_X.Y.Z_all.deb
```

To build the `.deb` yourself instead: `dpkg-buildpackage -us -uc -b` from a
checkout (needs `debhelper` and `devscripts`).

### From a checkout

Just run `bin/migrate-disks.sh` directly — no build step, no dependencies
beyond `bash`, `python3`, and (for cluster mode) `openssh-client`.

## Usage

```
bin/migrate-disks.sh [options]
  -s <storage>  Source storage        (default: Neohosting)
  -t <storage>  Target storage        (default: TN01SSD1600-NeoHosting)
  -f <format>   Preferred VM format    (default: qcow2; auto-falls back to raw)
  -p <N>        Max guests in parallel (default: 5)
  -A            All nodes (whole cluster). Default is this node only.
  -V            VMs only (skip containers)
  -C            Containers only (skip VMs)
  -S            Stop/move/start VMs to migrate offline-only volumes (tpmstate)
  -k            Keep source volumes (omit --delete)
  -n            Dry run
  -y            Skip confirmation
  -h            Help
```

The default source/target storage names are placeholders — set your own with
`-s`/`-t` (or edit the defaults at the top of the script).

### Examples

```bash
# See exactly what would happen on this node — changes nothing
bin/migrate-disks.sh -s local-lvm -t ssd-pool -n

# Migrate this node's guests, 5 in parallel
bin/migrate-disks.sh -s local-lvm -t ssd-pool

# Whole cluster, VMs only, 8 in parallel, auto-handle TPM state
bin/migrate-disks.sh -A -V -S -p 8 -s ceph -t ssd-pool

# Keep the source copies (don't delete after move)
bin/migrate-disks.sh -s a -t b -k
```

## How TPM state is handled

`tpmstate` can't be QCOW2 and can't move while the VM runs. So:

- **Without `-S`:** on a running VM it's skipped and counted under `Skipped`,
  with a note. The rest of that VM (and everything else) still migrates. Stop
  those VMs and re-run, or use `-S`.
- **With `-S`:** the VM's regular disks migrate live in the main pass; the
  `tpmstate` is deferred to a second phase that runs after the main pass so no
  parallel slot ever idles waiting on a shutdown. In that phase the VM is shut
  down gracefully (`GRACEFUL_TIMEOUT`, default 300s) then force-stopped if
  needed, the volume is moved as `raw`, and the VM is restarted. Shutdowns in
  this phase run concurrently.

## How container shutdown is handled

A container's storage can only move while it's stopped — there's no live path
like there is for VM disks. So this isn't gated behind a flag:

- **Stopped containers** migrate inline in the main pass, like any other
  volume.
- **Running containers** are deferred as a whole guest (all of its volumes
  together, not moved live one-by-one) to a phase that runs after the main
  pass: the container is shut down gracefully (`GRACEFUL_TIMEOUT`, default
  300s) then force-stopped if needed, every volume is moved in turn, and the
  container is restarted. Deferred containers in this phase run concurrently,
  the same way deferred TPM state does.

## Safety notes

- **Dry run first, every time.** `-n` prints the exact per-guest commands and
  the detected storage type/format.
- The source volume is **deleted after a successful move** unless you pass `-k`.
- Cluster mode requires inter-node root SSH; the script does a reachability
  preflight and aborts with the real error (and remediation) if a node can't be
  reached.
- Container moves need the target storage enabled for `rootdir` content, and
  cross-node moves need the target available on the owning node.

## Testing

The suite runs the real script against a **mock Proxmox environment** — no
cluster, root, or `qm`/`pct` needed. It builds a throwaway `/etc/pve` tree and
stubs the Proxmox commands.

```bash
tests/run-tests.sh            # run everything
tests/run-tests.sh test_cluster   # run one
```

Requires `bash` and `python3`. See `tests/lib/mocks.sh` for the harness.

## License

MIT — see [LICENSE](LICENSE).
