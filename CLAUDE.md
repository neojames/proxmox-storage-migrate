# CLAUDE.md

Guidance for Claude Code (and other contributors) working in this repo.

## What this is

A single Bash tool, `bin/proxmox-storage-migrate`, that bulk-migrates Proxmox
VE guest storage (VM disks and container volumes) from one storage to another,
optionally across a whole cluster, in parallel. Everything of substance lives
in that one script; `tests/` exercises it against a mocked Proxmox environment.

## Repo layout

```
bin/proxmox-storage-migrate   the tool (all logic lives here)
config/*.default              template for /etc/default/proxmox-storage-migrate
tests/run-tests.sh            runs every tests/test_*.sh
tests/lib/mocks.sh            fake /etc/pve + qm/pct/pvesm/ssh stubs + assertions
tests/test_*.sh               one file per behaviour area
```

## Running the tests

```bash
tests/run-tests.sh
```

No Proxmox, cluster, or root required. Tests build a throwaway `/etc/pve` tree,
stub the Proxmox CLIs as shell functions (so `command -v` still passes), and
path-redirect the script's hard-coded `/etc/pve` via `sed`. `python3` is
required (used for cluster IP resolution and by the harness). **Always run the
suite after changing the script.**

To add a test: copy an existing `tests/test_*.sh`, `source lib/mocks.sh`, build
an env with the `mock_add_*` helpers, call `mock_run <args>`, and assert with
`assert_contains` / `assert_calls` / `assert_no_calls` / `test_summary`.

## Architecture / how the script works

1. **Discovery** reads guest configs directly from the replicated
   `/etc/pve/nodes/<node>/{qemu-server,lxc}/<id>.conf` (top section only —
   snapshot sections start with `[`). This is cluster-wide and needs no SSH.
   Storage *type* comes from `/etc/pve/storage.cfg` (`type: id`), so it works
   even when the target isn't mounted locally.
2. **Work list** groups volumes by guest into `UNIT_VOLS`, keyed
   `vm:<node>:<id>` / `ct:<node>:<id>`.
3. **Dispatch** runs up to `MAX_PARALLEL` per-guest workers (`process_unit`)
   concurrently; each worker moves its guest's volumes one at a time.
4. **Execution** goes through `run_on <node> …`: direct locally, over SSH for
   remote nodes (`ssh_node` resolves the node IP from `/etc/pve/.members` and
   uses `-o HostKeyAlias=<node> -o StrictHostKeyChecking=accept-new`).
5. **Deferred phases** move volumes that can't move on a live guest, after the
   main pass, concurrently:
   - **Phase 2** (`process_deferred_tpm`) handles `tpmstate` on running VMs
     when `-S` is set: shut down (graceful then force), move as raw, restart.
   - **Phase 3** (`process_deferred_ct`) handles running containers
     unconditionally (no flag): a container's volumes can only move while it's
     stopped, so `process_unit` defers the *whole guest* (not per-volume) the
     moment it sees the container running; phase 3 shuts it down (graceful then
     force), moves every one of its volumes in order, then restarts it.
6. **Verification** re-reads the guest config and confirms the volume now points
   at the target storage.
7. **Aggregation** sums per-guest result files (`results/` and
   `results-deferred/`, the latter shared by both deferred phases) into the
   final Success/Failed/Skipped/Raw-fallback line.

## Config file

`/etc/default/proxmox-storage-migrate` is sourced right after the hardcoded
defaults are set and *before* `getopts` parsing — so precedence is
built-in default < config file < command-line flag. It's entirely optional
(the script just checks `[ -r "$CONFIG_FILE" ]`) and sets the exact same
internal variables the flags do (`SRC_STORAGE`, `FORMAT`, `DELETE_SRC`, …) —
no translation layer, so whatever's in the file is exactly what a matching
flag would have set. The canonical template lives at
`config/proxmox-storage-migrate.default` (installed commented-out by the
`.deb`); keep the two in sync with each other and with the flag reference in
`usage()`/the man page/README if you add or rename a variable. `-s`/`-t`
being "required" really means "required from *some* source" — the config
file can satisfy it just as well as a flag.

Tests can't write to the real `/etc/default/...`, so `tests/lib/mocks.sh`
path-redirects it into the mock tree (same trick as `/etc/pve`) and exposes
`mock_set_config`. `mock_run` always injects `-s`/`-t` defaults (since the
script itself doesn't); use `mock_run_no_defaults` instead when a test needs
to exercise what happens with genuinely nothing on the command line.

## Invariants — don't break these

- **A guest is locked during a move.** Never move two volumes of the same guest
  concurrently, and never overlap a guest's disk move with its own shutdown.
- **Moves must run on the owning node.** Anything touching a guest goes through
  `run_on <node>`.
- **`tpmstate` is always `raw`** and only moves while the VM is stopped.
- **QCOW2 only on file storages.** Block types downgrade to raw up front;
  keep the per-disk runtime fallback (`is_format_error`).
- **Containers never take `--format`.**
- **A running container's volumes always defer to phase 3.** Unlike VM disks
  (which move live) or tpmstate (opt-in via `-S`), container storage can only
  move while the container is stopped, so this isn't optional — no flag gates
  it, and it must defer the entire guest, not move some volumes live and defer
  others.
- **Discovery/verification stay SSH-free** (read `/etc/pve`); only mutating
  operations and status checks use `run_on`.

## Bash conventions / gotchas

- The script runs under `set -euo pipefail`. Watch the classic traps:
  - `((x++))` returns nonzero when `x` was 0 → aborts under `set -e`. Use
    `x=$((x+1))`.
  - `cond && action` as a **function's last line** propagates a nonzero status
    to the caller. End such functions with an `if` or `; return 0`.
- Increment counters with `$(( ))`, not `(( ))`.
- Keep helper functions safe to call from backgrounded workers (they run in
  subshells and inherit exported functions/vars).
- Per-run state goes under a unique `LOGDIR` (timestamp + PID) so concurrent or
  same-second invocations don't collide.

## Packaging & releases

- `debian/` packages `bin/proxmox-storage-migrate` as
  `/usr/bin/proxmox-storage-migrate` (a standard `debhelper` package;
  `man/proxmox-storage-migrate.1` ships as its man page;
  `config/proxmox-storage-migrate.default` ships as
  `/etc/default/proxmox-storage-migrate`, a conffile since it's under `/etc`).
  `debian/changelog`'s top version must match the git tag being released —
  bump both together, and keep `CHANGELOG.md` in sync.
- Pushing a `v*` tag runs `.github/workflows/release.yml`, which: re-lints and
  re-tests, checks the tag against `debian/changelog`, builds the `.deb` with
  `dpkg-buildpackage`, attaches it to a GitHub Release, then publishes it to a
  self-hosted apt repo on the `gh-pages` branch (served via GitHub Pages at
  `neojames.github.io/proxmox-storage-migrate/`):
  - `pool/main/p/proxmox-storage-migrate/` accumulates every released `.deb`;
    `dists/stable/main/binary-all/Packages(.gz)` is regenerated from the whole
    pool each time via `dpkg-scanpackages --multiversion` (so old versions
    stay installable by exact version, `apt upgrade` still finds the newest).
  - `dists/stable/Release` is hand-built (no `apt-ftparchive`, to avoid an
    extra dependency) and signed twice — clearsigned as `InRelease`, and
    detached as `Release.gpg` — for compatibility with both old and new apt.
  - Signing key: a repo-dedicated GPG key (not personal), private half in the
    `APT_SIGNING_KEY` repo secret, public half published as `KEY.gpg`/`KEY.asc`
    at the Pages root. Rotating it means regenerating the key, updating the
    secret, and re-publishing `KEY.*` — old signatures on already-published
    releases don't get retroactively re-signed.
  - The publish step needs a second checkout (`ref: gh-pages, path: gh-pages`)
    alongside the main one, and pushes back to `gh-pages` using the default
    `GITHUB_TOKEN` (needs `permissions: contents: write` on the workflow).
- **Beta tags**: `X.Y.Z-beta.N` (e.g. `1.2.0-beta.1`) — deliberately *not*
  `v`-prefixed, so `release.yml`'s `v*` trigger never fires for them (defense
  in depth: its trigger also explicitly excludes `!*-beta*`). These run
  `.github/workflows/beta.yml` instead: same lint/test/changelog-version
  checks and `dpkg-buildpackage`, and the `.deb` *is* attached to a GitHub
  Release for a stable, no-auth download link — but that release is created
  with `--prerelease` (so it's visually distinct from real releases and never
  becomes "Latest") and the apt-repo publish steps don't run. **Never push a
  tag combining both** (e.g. `v1.2.0-beta.1`) — it would match both triggers.
- `install.sh` (repo root) is the curl-pipe-to-bash installer: adds the apt
  repo (verifying the downloaded key's fingerprint against a hardcoded
  `EXPECTED_FINGERPRINT` before trusting it — bump that constant if the
  signing key is ever rotated), runs `apt-get update`, installs the package.
  It's fetched from `raw.githubusercontent.com` (main branch), not published
  via the release pipeline, so edits take effect immediately on push — no tag
  needed. Keep it in the CI/release shellcheck file lists.

## Safety

This tool deletes source volumes by default (`--delete`, unless `-k`) and can
stop/start VMs (`-S`). Treat changes to the move/delete/shutdown paths as
high-risk: add or update a test, and keep the dry-run (`-n`) output honest.
