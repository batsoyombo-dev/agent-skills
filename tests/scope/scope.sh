#!/usr/bin/env bash
# scope: the validator accepts its own example, and a scope-format plan runs through /phase end to end
# (ready, blockers, brief, gate, merge, mark, land), staying valid after landing. Local repos only.
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCOPE="$ROOT/plugins/scope/skills/scope"
PHASE="$ROOT/plugins/phase/skills/phase/phase.py"
VALIDATE="$SCOPE/scripts/validate_plan.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/scope-test.XXXXXX")
trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=true
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok    $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /' | head -30; }
has()  { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (expected /$3/)" "$2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qE -- "$3"; then bad "$1 (unexpected /$3/)" "$2"; else ok "$1"; fi; }
P()    { python3 "$PHASE" "$@" 2>&1; }

echo "scope"
has "skill is named scope" "$(head -3 "$SCOPE/SKILL.md")" "^name: scope$"
has "validator accepts the example" "$(python3 "$VALIDATE" "$SCOPE/references/example-plan.md")" "^OK: .* 4 tasks"
has "example carries the /phase rule" "$(cat "$SCOPE/references/example-plan.md")" "^8\\. When \`/phase\` runs this plan"

echo "scope plan under /phase"
git init -q -b staging "$T/r" && cd "$T/r" && mkdir -p docs/plans .claude
cp "$SCOPE/references/example-plan.md" docs/plans/fix.md
printf '{"remote": null, "plan": {"file": "docs/plans/fix.md"}, "worktree": {"env_file": ""}, "gate": {"tests": ["true"]}, "land": {"progress_file": "docs/plans/fix.md"}}' > .claude/phase.json
git add -A && git commit -qm init

out=$(P ready all)
has "T0.1 ready" "$out" "T0.1 +P0 +main +ready +no deps; serial"
has "T1.1 waits on T0.1" "$out" "T1.1 +P1 .*blocked +waits on T0.1"
has "T1.2 held by open A1, TQ1" "$out" "T1.2 .*manual +blocked by open A1, TQ1"
has "T1.3 held by open CQ1" "$out" "T1.3 .*manual +blocked by open CQ1"
hasnt "decision, assumption and risk rows are not tasks" "$out" "^(D1|A1|R1) "

P add T0.1 >/dev/null
out=$(P brief T0.1)
has "brief points at the task block" "$out" "Spec: the \`#### T0.1\` task block in docs/plans/fix.md"
has "brief has the acceptance criteria" "$out" "Done when: The test fails on current"
has "brief copies the task block" "$out" "^===== docs/plans/fix.md, task block T0.1 ====="
has "copied block is T0.1's" "$out" "^#### T0.1 "
hasnt "copied block stops before the next task" "$out" "^#### T1.1 "
has "brief has the plan's verify commands" "$out" "Verify \\(from the plan; run these too\\): bun test apps/api/src/reports/export.test.ts"

( cd .worktrees/t0_1 && mkdir -p apps && echo t > apps/export.test.ts && git add -A && git commit -qm "T0.1: test" )
has "gate blocks an implementer edit of the plan" "$( (cd .worktrees/t0_1 && echo x >> docs/plans/fix.md && git commit -qam edit); P check T0.1)" "docs/plans/fix.md is the orchestrator's"
( cd .worktrees/t0_1 && git reset -q --hard HEAD~1 )
has "gate passes" "$(P check T0.1)" "RESULT: PASS"
has "merge" "$(P merge T0.1)" "^ok"
has "mark sets Status done" "$(P mark T0.1)" "T0.1: status set to 'done'"
has "land" "$(P land T0.1 'T0.1: failing export test')" "landed T0.1"
landed=$(git show staging:docs/plans/fix.md)
has "landed plan has T0.1 done" "$(printf '%s' "$landed" | sed -n '/^#### T0.1/,/^#### T1.1/p')" "^- \\*\\*Status:\\*\\* done$"
has "landed plan ticked T0.1's criteria" "$(printf '%s' "$landed" | sed -n '/^#### T0.1/,/^#### T1.1/p')" "^  - \\[x\\] The test fails"
hasnt "other tasks untouched" "$(printf '%s' "$landed" | sed -n '/^#### T1.1/,$p')" "Status:\\*\\* done"
git show staging:docs/plans/fix.md > "$T/landed.md"
has "landed plan still validates" "$(python3 "$VALIDATE" "$T/landed.md")" "^OK:"
has "T1.1 ready after T0.1 landed" "$(P ready all)" "T1.1 +P1 .*ready"
P remove T0.1 >/dev/null

echo "blockers"
perl -pi -e 's/^(\| A1 \|.*\| )unconfirmed( \|)/${1}confirmed${2}/; s/^(1\. \*\*TQ1\*\*.*)$/$1 — answered: ops team/' docs/plans/fix.md
git commit -qam "client answers"
out=$(P ready all)
has "confirmed A1 + answered TQ1 release T1.2" "$out" "T1.2 .*ready"
has "T1.3 still held by CQ1" "$out" "T1.3 .*manual +blocked by open CQ1"
python3 - .claude/phase.json <<'EOF'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["plan"]["blocked_by"] = "warn"; json.dump(c, open(p, "w"))
EOF
git commit -qam "warn mode"
has "blocked_by warn: open CQ1 no longer holds T1.3" "$(P ready all)" "T1.3 .*blocked +waits on T1.1,T1.2"

echo
echo "scope: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
