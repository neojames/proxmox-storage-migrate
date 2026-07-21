## What / why

<!-- What does this change, and why? Link an issue if there is one. -->

## How this was tested

<!-- tests/run-tests.sh output, or manual steps if this isn't something the
mock harness can cover. -->

## Checklist

- [ ] `tests/run-tests.sh` passes
- [ ] `shellcheck -x --severity=warning bin/proxmox-storage-migrate install.sh tests/run-tests.sh tests/lib/mocks.sh tests/test_*.sh` passes
- [ ] Added or updated a test for the behavior change (required for anything
      touching the move/delete/shutdown paths — see CLAUDE.md's Safety
      section)
- [ ] Dry-run (`-n`) output still reflects what the code actually does
- [ ] Updated docs if a flag/config variable/behavior changed: `usage()` +
      man page, `README.md`, `config/proxmox-storage-migrate.default`
- [ ] Updated `CHANGELOG.md` (and bumped `debian/changelog`/tagged a release,
      if this needs one — see CLAUDE.md's Packaging & releases section)
