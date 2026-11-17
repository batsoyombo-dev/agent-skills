#!/usr/bin/env bash
# Run every test: tests/<area>/*.sh. Exit 0 = all green.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
status=0
for t in */*.sh; do
  echo "=== $t"
  bash "$t" || status=1
done
[ $status -eq 0 ] && echo "ALL GREEN" || echo "SOME TESTS FAILED"
exit $status
