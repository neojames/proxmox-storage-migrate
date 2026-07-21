# Contributing

Thanks for considering a contribution. This is a personal/community project
maintained on a best-effort basis — issues and PRs are welcome, but please be
patient.

## Before you start

- **Security issues**: don't open a public issue — see
  [SECURITY.md](SECURITY.md) for private reporting.
- **Bigger changes** (new flags, behavior changes, anything touching the
  move/delete/shutdown paths): open an issue first to discuss the approach
  before writing code. Small fixes and doc corrections can just be a PR.
- **Read [CLAUDE.md](CLAUDE.md) first.** It documents the architecture,
  invariants, and packaging pipeline in more depth than this file, and lists
  the Bash gotchas (`set -euo pipefail` traps, etc.) this codebase has
  already been bitten by once.

## Development environment

No Proxmox host, cluster, or root access needed. You only need:

- `bash`
- `python3` (used by the test harness and by cluster IP resolution)
- [`shellcheck`](https://www.shellcheck.net/) (CI lints at `--severity=warning`)

Everything of substance lives in `bin/proxmox-storage-migrate`; `tests/`
exercises it against a mocked Proxmox environment (`tests/lib/mocks.sh`
builds a throwaway `/etc/pve` tree and stubs `qm`/`pct`/`ssh`).

## Running the checks

```bash
tests/run-tests.sh                # the full suite
tests/run-tests.sh test_cluster   # a single test file

shellcheck -x --severity=warning \
  bin/proxmox-storage-migrate install.sh \
  tests/run-tests.sh tests/lib/mocks.sh tests/test_*.sh
```

Run both before opening a PR. **Always run the test suite after changing the
script** — this is called out in CLAUDE.md for a reason.

## Adding a test

Copy an existing `tests/test_*.sh`, `source lib/mocks.sh`, build an
environment with the `mock_add_*` helpers, call `mock_run <args>`, and assert
with `assert_contains` / `assert_calls` / `assert_no_calls` / `test_summary`.
See `tests/lib/mocks.sh` for the full helper list.

## Safety-critical areas

This tool deletes source volumes by default and can stop/start VMs. Changes
to the move, delete, or shutdown paths are treated as high-risk:

- Add or update a test covering the change.
- Keep the dry-run (`-n`) output honest — if a code path does something, `-n`
  should say so.
- Don't break the invariants listed in CLAUDE.md (a guest is locked during
  its own move, moves run on the owning node, tpmstate is always raw and
  stopped-only, etc.).

## Keeping docs in sync

If you add or rename a flag or config variable, update all of:

- `usage()` in the script and the man page (`man/proxmox-storage-migrate.1`)
- `README.md` (Usage/Examples/Config file sections)
- `config/proxmox-storage-migrate.default` (the template shipped by the `.deb`)
- `CHANGELOG.md`, for anything user-facing

## Pull requests

- Keep PRs focused — one behavior change per PR is easier to review and to
  bisect later.
- CI runs shellcheck and the test suite on every PR; make sure both pass
  locally first.
- Describe *why*, not just *what* — the commit message and PR description are
  where the reasoning lives. Keep code comments sparse; add one only where
  the *why* genuinely isn't obvious from the code itself (a workaround, a
  non-obvious invariant, a subtlety that would surprise a reader).

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Report
unacceptable behavior to james@neojames.me.
