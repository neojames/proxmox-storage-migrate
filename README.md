# proxmox-storage-migrate

[![CI](https://github.com/neojames/proxmox-storage-migrate/actions/workflows/ci.yml/badge.svg)](https://github.com/neojames/proxmox-storage-migrate/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/neojames/proxmox-storage-migrate?include_prereleases&label=release)](https://github.com/neojames/proxmox-storage-migrate/releases)
[![Last commit](https://img.shields.io/github/last-commit/neojames/proxmox-storage-migrate)](https://github.com/neojames/proxmox-storage-migrate/commits/main)
[![Open issues](https://img.shields.io/github/issues/neojames/proxmox-storage-migrate)](https://github.com/neojames/proxmox-storage-migrate/issues)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Bulk-migrate Proxmox VE guest storage from one storage to another — across an
entire cluster, in parallel — with sensible handling of the awkward cases
(QCOW2 vs raw, TPM state, containers, running guests).

It wraps `qm move-disk` and `pct move-volume` with discovery, parallelism,
format handling, verification, and logging, so you don't have to click through
every disk of every guest by hand.

> **Heads up:** this moves real data and can delete the source copy. Always run
> a dry run (`-n`) first and read the plan before committing.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Installation](#installation)
  - [From the apt repo (recommended)](#from-the-apt-repo-recommended)
  - [From a standalone .deb](#from-a-standalone-deb)
  - [From a checkout](#from-a-checkout)
  - [Beta builds](#beta-builds)
- [Usage](#usage)
  - [Examples](#examples)
- [Config file](#config-file)
- [How TPM state is handled](#how-tpm-state-is-handled)
- [How container shutdown is handled](#how-container-shutdown-is-handled)
- [Safety notes](#safety-notes)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

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
  TPM-state move. Details: [How TPM state is handled](#how-tpm-state-is-handled).
- **Migrates containers** as-is (no format flag; the target storage decides the
  on-disk format). Bind mounts and device mounts are ignored automatically. A
  container's volumes can only move while it's stopped, so a running container
  is always (no flag needed) stopped, fully migrated, and restarted in a
  deferred phase — mirroring how TPM state is handled for VMs. Details:
  [How container shutdown is handled](#how-container-shutdown-is-handled).
- **Runs cluster-wide** (`-A`): each move executes on the node that owns the
  guest — locally, or over SSH to remote nodes the way Proxmox itself does
  (node IP + `HostKeyAlias`, accepting new host keys).
- **Verifies every move** by re-reading the guest config, and writes a full log
  plus per-guest logs under `/var/log/proxmox-storage-migrate-<timestamp>-<pid>/`.

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

If already installed, it asks whether to upgrade (default) or remove instead
— removing keeps `/etc/default/proxmox-storage-migrate` in place (`apt purge`
removes that too). Otherwise it adds the apt repo (verifying the signing
key's fingerprint before trusting it), runs `apt update`, and installs the
package — safe to re-run any time to pick up a new release. If this node is
part of a multi-node Proxmox cluster, it then asks (default **No**) whether
to install on the other nodes too, over SSH — nothing is asked on a
standalone node. Prefer to do it by hand, or can't pipe a script into
`bash`? Same three steps, spelled out:

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

This installs the tool as `proxmox-storage-migrate` on your `PATH`, plus a man
page (`man proxmox-storage-migrate`) — the command used in the examples below.

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

Just run `bin/proxmox-storage-migrate` directly — no build step, no
dependencies beyond `bash`, `python3`, and (for cluster mode)
`openssh-client`. Use `bin/proxmox-storage-migrate` in place of the installed
`proxmox-storage-migrate` shown in the examples below.

### Beta builds

Tags like `1.2.0-beta.1` (no `v` prefix) build a `.deb` and attach it to a
[GitHub Release](https://github.com/neojames/proxmox-storage-migrate/releases)
marked **Pre-release**, for testing an in-progress version before it ships.
Unlike a real `vX.Y.Z` tag, a beta tag never touches the apt repo — install
the `.deb` directly instead:

```bash
wget https://github.com/neojames/proxmox-storage-migrate/releases/download/1.2.0-beta.1/proxmox-storage-migrate_1.2.0-beta.1_all.deb
apt install ./proxmox-storage-migrate_1.2.0-beta.1_all.deb
```

## Usage

```
proxmox-storage-migrate [options]
  -s <storage>  Source storage        (required)
  -t <storage>  Target storage        (required)
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

`-s`/`-t` have no defaults — the minimum viable command is:

```bash
proxmox-storage-migrate -s <source storage> -t <target storage>
```

Omit either one (or leave it empty), and neither is set in the
[config file](#config-file) either, and the script exits immediately with an
error and the usage text — rather than guessing or falling through to a
confusing "storage not defined" error further down.

### Examples

```bash
# See exactly what would happen on this node — changes nothing
proxmox-storage-migrate -s local-lvm -t ssd-pool -n

# Migrate this node's guests, 5 in parallel
proxmox-storage-migrate -s local-lvm -t ssd-pool

# Whole cluster, VMs only, 8 in parallel, auto-handle TPM state
proxmox-storage-migrate -A -V -S -p 8 -s ceph -t ssd-pool

# Keep the source copies (don't delete after move)
proxmox-storage-migrate -s a -t b -k
```

## Config file

`/etc/default/proxmox-storage-migrate` sets new defaults for any of the
options above, so a host that always migrates the same way doesn't need the
flags repeated on every run. It's entirely optional:

- If the file doesn't exist, nothing changes — the script's built-in defaults
  apply, same as before this file existed.
- Every setting inside it is also optional — comment out (or omit) any line
  to keep that one setting's built-in default.
- **Command-line flags always win** over this file, which in turn always wins
  over the script's built-in defaults. Precedence is: flag > config file >
  built-in default.
- The `.deb` installs it commented-out at that path; from a checkout, copy
  [`config/proxmox-storage-migrate.default`](config/proxmox-storage-migrate.default)
  there yourself.

It's a plain shell snippet — the file is `source`d, so values need quoting
the way you'd quote a shell variable assignment. Every setting is documented
inline in the file itself:

```bash
# /etc/default/proxmox-storage-migrate
SRC_STORAGE="local-lvm"      # -s — no built-in default, so set it here or on
DST_STORAGE="ssd-pool"       # -t   the command line (or the script errors out)
FORMAT="qcow2"                # -f — default: qcow2
MAX_PARALLEL=5                 # -p — default: 5
CLUSTER=0                      # -A — 0 = this node only, 1 = whole cluster
INCLUDE_VMS=1                  # -C sets this to 0 for that run
INCLUDE_CTS=1                  # -V sets this to 0 for that run
STOP_FOR_OFFLINE=0             # -S — 0 = skip+report tpmstate, 1 = auto-handle
DELETE_SRC="--delete"          # -k sets this to "" for that run
GRACEFUL_TIMEOUT=300           # config-file only, no matching flag
DRY_RUN=0                      # -n — be careful setting this to 1 here
ASSUME_YES=0                   # -y — be careful setting this to 1 here
```

This is the same set of internal variables the script itself uses, so
whatever's set here is exactly what a matching command-line flag would have
set — nothing is translated or reinterpreted.

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
- Found a security issue? See [SECURITY.md](SECURITY.md) for how to report it
  privately.

## Testing

The suite runs the real script against a **mock Proxmox environment** — no
cluster, root, or `qm`/`pct` needed. It builds a throwaway `/etc/pve` tree and
stubs the Proxmox commands.

```bash
tests/run-tests.sh            # run everything
tests/run-tests.sh test_cluster   # run one
```

Requires `bash` and `python3`. See `tests/lib/mocks.sh` for the harness.

## Contributing

[CLAUDE.md](CLAUDE.md) documents the architecture, invariants, and packaging
pipeline in more depth than this README — start there before changing the
script, tests, or `.github/workflows/`. [CHANGELOG.md](CHANGELOG.md) tracks
what shipped in each version.

## License

MIT — see [LICENSE](LICENSE).
