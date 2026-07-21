#!/usr/bin/env bash
#
# Run the full test suite against the mock Proxmox environment.
# No real Proxmox, cluster, or root required — see lib/mocks.sh.
#
# Usage: tests/run-tests.sh [test_name ...]
#   With no args, runs every tests/test_*.sh. With args, runs only those.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

command -v python3 >/dev/null 2>&1 || { echo "python3 is required for the tests"; exit 1; }

if [ "$#" -gt 0 ]; then
  mapfile -t tests < <(for t in "$@"; do echo "${t%.sh}.sh"; done)
else
  mapfile -t tests < <(ls test_*.sh 2>/dev/null)
fi

pass=0 fail=0 failed=()
for t in "${tests[@]}"; do
  echo "=============================================================="
  echo ">>> $t"
  echo "--------------------------------------------------------------"
  if bash "$t"; then
    echo "<<< $t OK"; pass=$((pass+1))
  else
    echo "<<< $t FAILED"; fail=$((fail+1)); failed+=("$t")
  fi
  echo
done

echo "=============================================================="
echo "SUITE: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { printf 'Failed: %s\n' "${failed[*]}"; exit 1; }
