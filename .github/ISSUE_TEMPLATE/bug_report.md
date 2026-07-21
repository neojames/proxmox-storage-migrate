---
name: Bug report
about: Something broke, or a migration didn't do what it should have
title: ""
labels: bug
assignees: ""
---

<!--
Security issue? Don't file it here — see SECURITY.md for private reporting.
-->

## What happened

<!-- What you ran, what you expected, what actually happened. -->

## Command

```
# the exact command/flags you ran, e.g.:
proxmox-storage-migrate -s local-lvm -t ssd-pool -A -S
```

## Dry-run output

<!--
Please re-run the same command with -n added and paste the output — it
shows the detected storage types/format and the exact plan without changing
anything, and is usually the fastest way to spot a discovery/config-parsing
issue.
-->

```
paste -n output here
```

## Relevant log output

<!-- From /var/log/proxmox-storage-migrate-<timestamp>-<pid>/ (main.log
and/or the per-guest log for the affected VM/CT), with any hostnames/IPs you
don't want public redacted. -->

```
paste here
```

## Environment

- Proxmox VE version: <!-- pveversion -->
- `proxmox-storage-migrate` version/commit: <!-- proxmox-storage-migrate -h, or the .deb version -->
- Installed via: <!-- apt repo / standalone .deb / checkout -->
- Single node or cluster: <!-- if cluster, how many nodes -->
- Source storage type / Target storage type: <!-- e.g. dir / lvmthin / zfspool / rbd -->
- Guest type and state: <!-- VM or CT, running or stopped when you ran the command -->
