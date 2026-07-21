# CLAUDE.md

Guidance for Claude Code (and other contributors) working in this repo.

## What this is

A single Bash tool, `bin/migrate-disks.sh`, that bulk-migrates Proxmox VE guest
storage (VM disks and container volumes) from one storage to another, optionally
across a whole cluster, in parallel. Everything of substance lives in that one
script; `tests/` exercises it against a mocked Proxmox environment.

## Repo layout

```
bin/migrate-disks.sh     the tool (all logic lives here)
tests/run-tests.sh       runs every tests/test_*.sh
tests/lib/mocks.sh       fake /etc/pve + qm/pct/pvesm/ssh stubs + assertions
tests/test_*.sh          one file per behaviour area
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
5. **Deferred phase** (`process_deferred_tpm`) handles `tpmstate` on running VMs
   when `-S` is set: after the main pass, shut down (graceful then force), move
   as raw, restart — concurrently.
6. **Verification** re-reads the guest config and confirms the volume now points
   at the target storage.
7. **Aggregation** sums per-guest result files (`results/` and
   `results-deferred/`) into the final Success/Failed/Skipped/Raw-fallback line.

## Invariants — don't break these

- **A guest is locked during a move.** Never move two volumes of the same guest
  concurrently, and never overlap a guest's disk move with its own shutdown.
- **Moves must run on the owning node.** Anything touching a guest goes through
  `run_on <node>`.
- **`tpmstate` is always `raw`** and only moves while the VM is stopped.
- **QCOW2 only on file storages.** Block types downgrade to raw up front;
  keep the per-disk runtime fallback (`is_format_error`).
- **Containers never take `--format`.**
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

## Safety

This tool deletes source volumes by default (`--delete`, unless `-k`) and can
stop/start VMs (`-S`). Treat changes to the move/delete/shutdown paths as
high-risk: add or update a test, and keep the dry-run (`-n`) output honest.
