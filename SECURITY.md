# Security Policy

## Supported Versions

This project ships as a single script with no separate release branches.
Security fixes are only made against the latest commit on `main`. If you're
running an older checkout, update to the current `main` before reporting an
issue to make sure it hasn't already been fixed.

## Reporting a Vulnerability

Please **do not open a public GitHub issue** for security concerns.

Instead, report privately using one of:

- GitHub's [private vulnerability reporting](https://github.com/neojames/proxmox-storage-migrate/security/advisories/new)
  for this repository, or
- Email **james@neojames.me** with a description of the issue, steps to
  reproduce, and the potential impact.

You should get an acknowledgement within 5 business days. This is a
personal/community project maintained on a best-effort basis, so please be
patient — but reports are taken seriously and a fix or mitigation will be
prioritized once confirmed.

Please include, where relevant:

- The version/commit of `proxmox-storage-migrate` you're running.
- Proxmox VE version and cluster topology (single node vs. cluster).
- The exact command-line flags used and a minimal reproduction (guest config,
  storage config, or mock test case if possible).

## Scope and Threat Model

`bin/proxmox-storage-migrate` is intended to be run **by a trusted administrator, as
root, on a Proxmox VE node**. Given that, please keep the following in mind
when assessing impact:

- **Root execution is expected.** The script is designed to run as root (it
  needs to for `qm`/`pct`/`pvesm` and to read `/etc/pve`). Reports that simply
  note "this script does X as root" without a way for a *lower-privileged or
  remote* actor to influence that behavior are not actionable as vulnerabilities.
- **SSH between cluster nodes uses trust-on-first-use.** Remote nodes are
  reached via `ssh -o HostKeyAlias=<node> -o StrictHostKeyChecking=accept-new`,
  pinned to the node name rather than its IP, using the operator's existing
  root SSH keys/known_hosts. This is intentional (cluster nodes are already
  mutually trusted in Proxmox), but reports involving SSH option injection,
  host key handling, or credential exposure in logs are very much in scope.
- **Data loss is a first-class risk, not just a bug.** By default the tool
  deletes source volumes after a verified successful move (`--delete` unless
  `-k`/keep is given) and can shut down and restart running VMs (`-S`). Any
  input (guest config content, storage config, CLI flags, or `pvesm`/`qm`/
  `pct` output) that could cause the wrong volume to be deleted, a volume to
  be reported as migrated when it wasn't, or a guest to be stopped/started
  unexpectedly, is a high-priority report.
- **Command construction from config data.** Guest configs and
  `/etc/pve/storage.cfg` are read and parsed as data. Any way to get shell
  injection, path traversal, or unintended command execution out of a crafted
  volume string, storage ID, or guest config value is in scope.
- **No network service.** The script has no listener, API, or web interface —
  reports must describe a concrete local or cluster-adjacent attack path.

## Known Non-Issues

- Requiring root, or full access to `/etc/pve` and the Proxmox CLIs, is
  by design — this is a cluster administration tool, not a multi-tenant
  service.
- Deleting source volumes after a move is documented default behavior
  (`--delete` unless `-k`); this is a data-handling design choice, not a
  vulnerability, unless you can show the *verification* step can be fooled.

## Disclosure

Once a fix is available, a note will be added to `CHANGELOG.md` and, for
anything with real user impact, a GitHub Security Advisory will be published
crediting the reporter (unless anonymity is requested).
