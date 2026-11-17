#!/usr/bin/env bash
# Test install.sh against a throwaway Claude config dir: link, idempotence, conflicts backed up outside the
# scanned dirs, stale-link pruning, list, partial and full uninstall. Exit 0 = all passed.
set -uo pipefail
ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/install-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
has()  { if printf '%s' "$2" | grep -qE -- "$3"; then pass=$((pass+1)); echo "  ok    $1"; else fail=$((fail+1)); echo "  FAIL  $1 (expected /$3/)"; printf '%s\n' "$2" | sed 's/^/        | /' | head -20; fi; }
I() { CLAUDE_CONFIG_DIR=$T "$ROOT/install.sh" "$@" 2>&1; }

mkdir -p "$T/skills/phase" "$T/agents"
echo old > "$T/skills/phase/SKILL.md"                       # a conflicting real directory
ln -s "$ROOT/plugins/removed/agents/x.md" "$T/agents/x.md"   # a stale link into this repo
echo mine > "$T/agents/unrelated.md"                         # something we must never touch

out=$(I)
has "links the skill" "$out" "linked +skills/phase"
has "links the agents" "$out" "linked +agents/phase-implementer.md"
has "backs up the conflict" "$out" "moved the existing skills/phase to agent-skills-backup/"
has "backup is outside skills/" "$(ls "$T/skills")" "^phase$"
has "prunes stale links" "$out" "removed stale agents/x.md"
has "skill resolves to the repo" "$(readlink "$T/skills/phase")" "plugins/phase/skills/phase$"
has "engine is executable" "$(test -x "$T/skills/phase/phase.py" && echo yes)" "yes"
has "idempotent" "$(I)" "ok +skills/phase"
has "list" "$(I --list)" "skill +phase +\\[installed\\]"
I --uninstall phase >/dev/null
has "uninstall removes our links" "$(ls "$T/skills" "$T/agents")" "unrelated.md"
has "uninstall leaves other files" "$(cat "$T/agents/unrelated.md")" "mine"
has "partial uninstall keeps other plugins" "$(ls "$T/skills")" "^scope$"
has "links scope too" "$(readlink "$T/skills/scope")" "plugins/scope/skills/scope$"
I --uninstall >/dev/null
has "nothing of ours left" "$(find "$T/skills" "$T/agents" -type l | wc -l | tr -d ' ')" "^0$"
echo; echo "install test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
