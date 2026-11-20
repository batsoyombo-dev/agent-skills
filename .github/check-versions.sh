#!/usr/bin/env bash
# Fail when a plugin's files changed since <base> but its plugin.json version did not.
# Plugin installs (/plugin marketplace update) only pick up a new version, so an unbumped change never
# reaches them. Compares the working tree, so it also works before you commit:
#   .github/check-versions.sh origin/main
set -euo pipefail
base=${1:?usage: check-versions.sh <base-ref>}
cd "$(git rev-parse --show-toplevel)"
if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "skip: $base is not in this clone (new branch or force-push)"; exit 0
fi
version() { python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])' 2>/dev/null || true; }
status=0 changed=0
for d in plugins/*/; do
  p=${d%/}; m=$p/.claude-plugin/plugin.json
  git diff --quiet "$base" -- "$p" && continue
  changed=1
  old=$(git show "$base:$m" 2>/dev/null | version || true)
  new=$(version < "$m")
  if [ -z "$new" ]; then echo "FAIL  $m has no version"; status=1
  elif [ -z "$old" ]; then echo "ok    $p is new ($new)"
  elif [ "$old" = "$new" ]; then echo "FAIL  $p changed since $base but is still $new: bump version in $m"; status=1
  else echo "ok    $p $old -> $new"
  fi
done
[ $changed -eq 1 ] || echo "ok    no plugin changed since $base"
exit $status
