#!/usr/bin/env bash
# End-to-end test of the phase skill: builds throwaway repos with local bare remotes (nothing leaves the machine)
# and walks the whole flow: doctor, ready, add, isolation, brief, gate, overlap, merge, land, conflicts,
# a secondary repo, smoke, remove, resume and local-only mode. Exit 0 = all passed.
# Needs git, python3, bash. Run: tests/phase/e2e.sh   (KEEP=1 keeps the temp dir for inspection)
set -uo pipefail

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PHASE="$ROOT/plugins/ship/skills/phase/phase.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/phase-e2e.XXXXXX")
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=true
pass=0; fail=0
SERVER=""
cleanup() { [ -n "$SERVER" ] && { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }; [ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"; }
PORT=$((20000 + RANDOM % 20000))
trap cleanup EXIT

ok()   { pass=$((pass + 1)); echo "  ok    $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /' | head -30; }
has()  { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (expected /$3/)" "$2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qE -- "$3"; then bad "$1 (unexpected /$3/)" "$2"; else ok "$1"; fi; }
P()    { python3 "$PHASE" "$@" 2>&1; }
edit() { perl -pi -e "$1" "$2"; }   # portable in-place edit (BSD and GNU)

echo "phase e2e in $T"
cd "$T"
for r in proj app; do git init -q --bare "$r-origin.git"; git init -q -b staging "$r"; git -C "$r" remote add origin "$T/$r-origin.git"; done

# ---------------------------------------------------------------- fixture
cd "$T/proj"
mkdir -p docs/plan src migrations .claude
cat > docs/plan/progress.md <<'EOF'
# Progress

## Phases

**A: core**

| Id | Task | Depends on | Owner | Status |
|---|---|---|---|---|
| A1 | Add greeting | — | agent | |
| A2 | Add farewell | — | agent | |
| A3 | Use both | A1, A2 | agent | |
| A4 | Ask the client | — | you | |

**B: app** (`app` repo)

| Id | Task | Depends on | Owner | Status |
|---|---|---|---|---|
| B1 | App screen | A1 | agent | |
EOF
printf 'greet() { echo hi; }\n' > src/lib.sh
printf '# Spec\n## A1 Add greeting\nUse the `greetings` table and `src/lib.sh`.\n### Notes\ninner note A1\n## A10 Not this one\nA10 body\n' > docs/plan/spec.md
printf '# Data\n#### `greetings`\ngreetings columns\n#### `farewells`\nfarewells columns\n' > docs/plan/data.md
printf 'one\n' > routes.txt
printf 'create table t (id int);\n' > migrations/2026_01_01_100000_init.sql
cat > test.sh <<'EOF'
set -e
for f in src/*.sh; do bash -n "$f"; done
grep -q '^DB_NAME=db_' .env || { echo "worktree env not isolated"; exit 1; }
EOF
printf '.env\n' > .gitignore
printf 'DB_NAME=shared\nSECRET=real\n' > .env
cat > .claude/phase.json <<EOF
{
  "project": "the demo plan",
  "agents": { "max": 2 },
  "plan": { "file": "docs/plan/progress.md" },
  "repos": {
    "core": { "path": ".", "primary": true },
    "app": { "path": "../app", "markers": ["\`app\` repo"],
             "worktree": { "env_file": "", "setup": ["echo app-\$PHASE_ACTION > .setup-marker"] },
             "gate": { "tests": ["test -f screen.txt"] } }
  },
  "slots": { "vars": { "migration_prefix": "{date}_{slot}00" },
             "avoid": { "path": "migrations", "regex": "^{date}_(\\\\d\\\\d)" } },
  "worktree": {
    "env_file": ".env",
    "env": { "DB_NAME": "db_{id}", "PORT": "{port}", "SECRET": "" },
    "setup": ["echo setup-\$PHASE_ACTION-{id} > .setup-marker"],
    "teardown": ["echo teardown \$PHASE_ID >> $T/teardown.log"],
    "exclude": [".setup-marker"]
  },
  "gate": {
    "tests": ["bash test.sh"],
    "per_file": [{ "glob": "*.sh", "run": "bash -n {file}", "name": "bash -n on changed scripts" }],
    "immutable": ["migrations/*"],
    "test_globs": ["tests/*"],
    "rules": [
      { "name": "no xtrace", "regex": "set -x", "paths": ["src/*"], "level": "fail", "message": "set -x leaks secrets" },
      { "name": "no TODO", "regex": "TODO", "paths": ["src/*"], "level": "warn" }
    ],
    "review": { "lines": 400, "triggers": [{ "name": "schema", "paths": "^migrations/" }] }
  },
  "land": { "progress_file": "docs/plan/progress.md" },
  "smoke": { "base_url": "http://127.0.0.1:$PORT" },
  "brief": { "spec": "the {ID} row in docs/plan/progress.md", "read": ["README.md"],
             "rules": ["Shell only."], "extra": ["Migrations: name new files {migration_prefix}01_<name>.sql"],
             "inline": [{ "file": "docs/plan/spec.md", "heading": "## {ID}" },
                        { "file": "docs/plan/data.md", "heading": "#### \`{name}\`", "names_from": "\`([a-z_]+)\`" }] },
  "doctor": { "require": ["git", "bash"], "checks": [{ "name": "bash works", "run": "true" }] }
}
EOF
git add -A && git commit -qm init && git push -q origin staging
(cd "$T/app" && echo app > README && git add -A && git commit -qm init && git push -q origin staging)

# ---------------------------------------------------------------- plan
echo "plan"
out=$(P doctor); has "doctor clean" "$out" "check bash works"; hasnt "doctor has no FAIL" "$out" "^FAIL"
mkdir -p "$T/home"
out=$(HOME="$T/home" P doctor)
has "doctor warns: gate commands would prompt" "$out" "^warn  permissions: [0-9]+ command\(s\) agents run will stop"
has "doctor suggests the allow rules" "$out" 'Bash\(git commit \*\)'
echo '{"permissions":{"allow":["Bash"],"ask":["Bash(git commit *)"]}}' > .claude/settings.local.json
out=$(HOME="$T/home" P doctor); has "doctor: ask rule still prompts" "$out" "git commit -m x  \(matches an ask rule\)"
echo '{"permissions":{"allow":["Bash(git add *)","Bash(git commit:*)","Bash(*/phase.py *)","Bash(bash *)","Bash(sh *)","Bash(true)","Bash(test *)"]}}' > .claude/settings.local.json
out=$(HOME="$T/home" P doctor); hasnt "doctor: no permission warning once allowed" "$out" "will stop and wait"
rm -f .claude/settings.local.json
out=$(P ready)
has "A1 ready" "$out" "A1 +A +core +ready"
has "A3 blocked on A1,A2" "$out" "A3 .*blocked +waits on A1,A2"
has "A4 manual (owner you)" "$out" "A4 .*manual +owner you"
has "ready shows what a task unblocks" "$out" "A1 .*unblocks 2"
has "B1 routed to the app repo" "$out" "B1 +B +app +blocked"

# ---------------------------------------------------------------- add, isolation, brief
echo "add"
P add A1 >/dev/null; P add a2 >/dev/null
has "add refuses past agents.max" "$(P add A4)" "not starting A4: 2 implementers active"
hasnt "refused add made no worktree" "$(ls .worktrees)" "^a4$"
env1=$(cat .worktrees/a1/.env)
has "own database per worktree" "$env1" "^DB_NAME=db_a1"
has "secret blanked" "$env1" "^SECRET=$"
has "setup hook ran" "$(cat .worktrees/a1/.setup-marker)" "setup-add-a1"
has "worktree files are excluded" "$(git -C .worktrees/a1 status --porcelain | wc -l | tr -d ' ')" "^0$"
out=$(P brief A1)
has "brief has the gate command" "$out" "check A1"
has "brief has project rules" "$out" "Shell only"
has "brief renders slot vars" "$out" "Migrations: name new files [0-9_]+00"
has "brief fills done-when" "$out" "Done when: every acceptance point"
has "brief inlines the task's spec section" "$out" "inner note A1"
hasnt "inlined section stops at the next heading" "$out" "A10 body"
has "brief inlines sections named in the spec" "$out" "greetings columns"
hasnt "brief skips sections the spec doesn't name" "$out" "farewells columns"

echo "tiers, brief file"
cp .claude/phase.json "$T/phase.json.bak"
python3 - <<'EOF'
import json
c = json.load(open(".claude/phase.json"))
c["agents"].update(tiers={"standard": {"model": "opus", "effort": "medium"}, "strong": {"model": "opus", "effort": "high"}},
                   default_tier="standard", review_tier="strong", escalate_tier="strong", tier_of={"A2": "strong"})
c["brief"]["inline"].append({"file": "docs/plan/progress.md", "line": r"^\| {name} \|", "names_from": r"## (A\d+)", "names_in": "first"})
c["brief"]["exports"] = {"regex": r"^\w+\(\)"}
json.dump(c, open(".claude/phase.json", "w"))
EOF
out=$(P brief A1 --write)
has "brief --write prints the tier's parameters" "$out" "Agent parameters: model: opus, effort: medium \(tier standard\)"
has "brief --write prints a short prompt" "$out" "Your complete brief is .*/.phase/a1.brief.md"
hasnt "brief --write keeps the spec out of the prompt" "$out" "inner note A1"
b=$(cat .worktrees/.phase/a1.brief.md)
has "brief file has the spec" "$b" "inner note A1"
has "brief file copies named lines" "$b" "^\| A1 \| Add greeting"
hasnt "and only those" "$b" "^\| A2 \|"
has "brief maps the files the spec names" "$b" "^src/lib.sh \(1 lines\)"; has "with their exports" "$b" "1: greet\(\)"
has "brief names the notes file" "$b" "Notes: .*a1.notes.md"
has "tier_of overrides the default" "$(P tier A2)" "build: +strong -> model: opus, effort: high"
P tier A1 --escalate >/dev/null
has "escalated tier sticks" "$(P brief A1 --write)" "effort: high \(tier strong\)"
has "ready rows still print" "$(P ready)" "A3 .*blocked"
python3 -c 'import json; c=json.load(open(".claude/phase.json")); c["agents"]["tier_of"]={"A1":"nope"}; json.dump(c, open(".claude/phase.json","w"))'
P note A1 tier= >/dev/null
has "unknown tier is refused" "$(P tier A1)" "unknown tier 'nope'"

echo "timeouts"
python3 - <<'EOF'
import json
c = json.load(open(".claude/phase.json"))
c["worktree"].update(hook_timeout=1, refresh=["sleep 31.4159 & wait"])
json.dump(c, open(".claude/phase.json", "w"))
EOF
out=$(cd "$T/proj" && python3 - "$PHASE" <<'EOF'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("phase", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
proj, t = m.Project("."), time.time()
try:
    m.run_hooks(proj, proj.ctx("A1"), proj.rcfg("core", "worktree")["refresh"], "refresh", ".")
except m.Fail as e:
    print("%s | in %s" % (e, "time" if time.time() - t < 10 else "LATE"))
EOF
)
has "a hanging hook is killed and named" "$out" "sleep 31"; has "with the reason, in time" "$(printf '%s' "$out" | tr '\n' ' ')" "timed out after 1s.*in time"
hasnt "its children are gone" "$(ps -Ao args | grep -xE 'sleep 31[.]4159' || true)" "sleep"
cp "$T/phase.json.bak" .claude/phase.json
# stopping phase.py itself must not leave its tests running
python3 - "$PHASE" <<'EOF' &
import importlib.util, signal, sys
spec = importlib.util.spec_from_file_location("phase", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
signal.signal(signal.SIGTERM, lambda n, _f: sys.exit(128 + n))
m.run("sleep 32.7182 & wait", shell=True, timeout=60)
EOF
pid=$!; sleep 1; kill -TERM $pid; wait $pid 2>/dev/null
hasnt "stopping phase.py stops its children" "$(ps -Ao args | grep -xE 'sleep 32[.]7182' || true)" "sleep"

# ---------------------------------------------------------------- gate catches violations
echo "gate"
( cd .worktrees/a1
  printf 'set -x\nhello() { greet; } # TODO\n' > src/hello.sh
  echo edit >> migrations/2026_01_01_100000_init.sql
  echo x >> docs/plan/progress.md
  echo a1 >> routes.txt
  printf 'AKIA%s\n' ABCDEFGHIJKLMNOP > src/key.txt
  printf 'X=1\n' > .env.local
  mkdir -p tests && printf '# markTestSkipped("later")\n' > tests/a1_test.sh
  git add -A && git commit -qm "A1: greeting" )
out=$(P check A1)
has "forbidden file" "$out" "FAIL  must not be committed: .env.local"
has "owned progress file" "$out" "FAIL  docs/plan/progress.md is the orchestrator's"
has "immutable migration" "$out" "FAIL  existing file under an immutable path"
has "fail rule" "$out" "FAIL  set -x leaks secrets"
has "warn rule" "$out" "warn  no TODO"
has "secret scan" "$out" "FAIL  secret-looking values"
has "review trigger" "$out" "review required \\(schema\\)"
has "skip marker in a test file" "$out" "FAIL  skipped or focused tests added"
has "gate fails" "$out" "RESULT: FAIL"

( cd .worktrees/a1
  git rm -q --cached .env.local; rm -f .env.local src/key.txt
  git checkout -q origin/staging -- docs/plan/progress.md migrations/2026_01_01_100000_init.sql
  printf 'hello() { greet; }\n' > src/hello.sh
  printf '# tests hello\n' > tests/a1_test.sh
  printf '# A1 report\n## Interfaces\n- `hello()` in src/hello.sh\n## Smoke\n- `GET /index.html` → 200\n- `GET /missing` → 404\n' > .phase-report.md
  git add -A && git commit -qm "A1: fixes" )
( cd .worktrees/a2
  echo a2 >> routes.txt; printf 'bye() { echo bye; }\n' > src/bye.sh
  printf 'alter table t add c int;\n' > migrations/2026_11_17_110001_add_c.sql
  git add -A && git commit -qm "A2: farewell" )
has "quick gate says review is required" "$(P check A2 --quick)" "review required \\(schema\\)"
has "review-brief works after a quick gate" "$(P review-brief A2)" "Why review is required: required \\(schema\\)"
echo "review package, findings, minors"
out=$(P review-brief A2 --write)
has "review-brief --write prints a short prompt" "$out" "Your complete review brief is .*a2.review-brief.md"
has "no tiers: nothing to set" "$out" "Agent parameters: no model or effort"
rb=$(cat .worktrees/.phase/a2.review-brief.md)
has "review brief lists the diff part" "$rb" "a2.review/diff-01.txt"
has "diff part holds the change" "$(cat .worktrees/.phase/a2.review/diff-01.txt)" "bye\(\) \{ echo bye"
has "review brief names the findings file" "$rb" "Findings file: .*a2.review/findings-1.md"
has "fix-brief needs findings" "$(P fix-brief A2)" "no findings file"
printf 'VERDICT: CHANGES\n1. src/bye.sh:1 major\n' > .worktrees/.phase/a2.review/findings-1.md
out=$(P fix-brief A2 --only 1); has "fix-brief points at the findings" "$out" "Fix finding\(s\) 1 of .*findings-1.md"; has "fix-brief has the gate" "$out" "check A2"
( cd .worktrees/a2 && printf 'bye() { echo goodbye; }\n' > src/bye.sh && git commit -qam "A2: review fixes" )
out=$(P review-brief A2 --recheck); has "recheck is round 2" "$out" "findings-2.md"
rd=$(cat .worktrees/.phase/a2.review/diff-01.txt)
has "recheck shows the fix" "$rd" "echo goodbye"; hasnt "recheck leaves the rest out" "$rd" "alter table"
P minor A2 "src/bye.sh:1: wording" >/dev/null
has "minor is listed" "$(P minors)" "1 - \[ \] A2: src/bye.sh:1: wording"
P minors --close 1 >/dev/null; has "minor closed" "$(P minors)" "no open minors"
has "worktree stays clean of run files" "$(git -C .worktrees/a2 status --porcelain | wc -l | tr -d ' ')" "^0$"
has "gate passes after fixes" "$(P check A1)" "RESULT: PASS"
out=$(P check A1); has "gate reuses tests passed on the same commit" "$out" "not re-run"; has "reused gate passes" "$out" "RESULT: PASS"
hasnt "check --full re-runs the tests" "$(P check A1 --full)" "not re-run"
has "overlap sees the shared file" "$(P overlap)" "core:routes.txt +A1, A2"
P note A1 agent=agent-a1 >/dev/null
has "status shows agent and gate" "$(P status)" "A1 +core +running +agent-a1 .* pass"

# ---------------------------------------------------------------- merge queue
echo "merge queue"
has "merge refuses an ungated tip" "$(P merge A2)" "gate has not passed"
has "merge A1" "$(P merge A1)" "^ok +squash of phase/a1"
has "land needs the progress edit" "$(P land A1 'A1: greeting')" "unchanged .* update it first"
edit 's/^\| A1 \| Add greeting \| — \| agent \| \|$/| A1 | Add greeting | — | agent | done 2026-11-17 |/' .worktrees/_integration/docs/plan/progress.md
echo untested > .worktrees/_integration/src/sneaky.sh
has "land refuses an untracked untested file" "$(P land A1 'A1: greeting')" "untested\\): src/sneaky.sh"
rm .worktrees/_integration/src/sneaky.sh
has "land A1" "$(P land A1 "$(printf 'A1: greeting\n\nCo-Authored-By: t <t@example.invalid>')")" "landed A1"
stat=$(git -C "$T/proj-origin.git" show --stat --format=%s staging)
has "one squash commit with code and progress" "$stat" "docs/plan/progress.md"
hasnt "nothing untested landed" "$stat" "sneaky"
has "rolling: A3 now waits only on A2" "$(P ready A)" "A3 .*blocked +waits on A2 "

out=$(P check A2)
has "gate passes for A2 alone" "$out" "RESULT: PASS"
has "warns when no test changed" "$out" "warn  no test files changed"
has "merge refuses a required review without approval" "$(P merge A2)" "review required \\(schema\\) and no approval"
has "approve records the tip" "$(P approve A2 --note 'reviewer APPROVE')" "approval recorded for A2"
has "squash conflict detected" "$(P merge A2)" "CONFLICT squashing phase/a2"
has "sync --keep leaves the rebase" "$(P sync A2 --keep)" "left in progress"
( cd .worktrees/a2 && printf 'one\na1\na2\n' > routes.txt && git add routes.txt && git rebase --continue >/dev/null 2>&1 )
has "stale gate after rebase" "$(P merge A2)" "gate has not passed"
P check A2 >/dev/null
has "approval is tied to the tip" "$(P merge A2)" "no approval recorded"
P approve A2 >/dev/null; has "merge A2" "$(P merge A2)" "^ok"
P add A3 --force >/dev/null 2>&1; P check A3 --quick >/dev/null
has "merge queue is serial" "$(P merge A3)" "merge queue is busy with A2"
P remove A3 --force >/dev/null
edit 's/^\| A2 \| Add farewell \| — \| agent \| \|$/| A2 | Add farewell | — | agent | done 2026-11-17 |/' .worktrees/_integration/docs/plan/progress.md
has "land A2" "$(P land A2 'A2: farewell')" "landed A2"
out=$(P stats); has "stats lists a landed task" "$out" "A2 +merged"; has "stats counts merge attempts" "$out" "A2 .* [0-9]+× "

# ---------------------------------------------------------------- secondary repo
echo "secondary repo"
has "B1 ready once A1 is done" "$(P ready all)" "B1 +B +app +ready"
P add B1 >/dev/null
has "app setup hook" "$(cat "$T/app/.worktrees/b1/.setup-marker")" "app-add"
( cd "$T/app/.worktrees/b1" && echo screen > screen.txt && git add -A && git commit -qm "B1: screen" )
P check B1 >/dev/null; has "merge B1" "$(P merge B1)" "write \\{sha\\}"
edit 's/^\| B1 \| App screen \| A1 \| agent \| \|$/| B1 | App screen | A1 | agent | done 2026-11-17 (app `{sha}`) |/' .worktrees/_integration/docs/plan/progress.md
printf '#!/bin/sh\necho "rejected for the test" >&2\nexit 1\n' > "$T/proj-origin.git/hooks/pre-receive"; chmod +x "$T/proj-origin.git/hooks/pre-receive"
has "primary push fails after the app push" "$(P land B1 'B1: app screen')" "push failed 3 times"
has "half-landed task is not re-merged" "$(P merge B1)" "half landed \\(committed\\)"
has "abort refuses after the app push" "$(P abort)" "not aborting: B1 already pushed"
rm "$T/proj-origin.git/hooks/pre-receive"
has "land B1 resumes and finishes" "$(P land B1 'B1: app screen')" "landed B1: core [0-9a-f]+, app [0-9a-f]+"
has "app got exactly one B1 commit" "$(git -C "$T/app-origin.git" log --format=%s staging | grep -c '^B1: app screen$')" "^1$"

appsha=$(git -C "$T/app-origin.git" rev-parse --short=7 staging)
has "progress row carries the app sha" "$(git -C "$T/proj-origin.git" show staging:docs/plan/progress.md)" "app \`$appsha\`"
has "primary progress commit subject" "$(git -C "$T/proj-origin.git" log -1 --format=%s staging)" "^B1: progress \\(app $appsha\\)"

# ---------------------------------------------------------------- smoke
echo "smoke"
mkdir -p "$T/www" && echo ok > "$T/www/index.html"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" >/dev/null 2>&1 &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do python3 -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:$PORT/index.html')" 2>/dev/null && break; sleep 0.3; done
out=$(P smoke A1)
has "smoke 200" "$out" "ok +GET /index.html -> 200"
has "smoke 404" "$out" "ok +GET /missing -> 404"
has "smoke summary" "$out" "smoke: 2 checked, 0 failed"

# ---------------------------------------------------------------- remove and resume
echo "remove and resume"
P add A3 >/dev/null; ( cd .worktrees/a3 && echo wip > src/wip.sh && git add -A && git commit -qm wip )
has "remove refuses unmerged work" "$(P remove A3)" "unmerged commits"
rm -rf .worktrees/a3
has "add resumes the existing branch" "$(P add A3)" "resumed existing branch phase/a3"
out=$(P brief A3)
has "brief carries what the dependencies built" "$out" "`hello\(\)` in src/hello.sh"; hasnt "only the useful sections" "$out" "/index.html"
has "resumed branch keeps its commit" "$(git -C .worktrees/a3 log -1 --format=%s)" "^wip$"
for t in A1 A2 B1; do P remove $t >/dev/null; done; P remove A3 --force >/dev/null
has "teardown hooks ran" "$(cat "$T/teardown.log")" "teardown b1"
has "no task branches left" "$(git branch --list 'phase/*' | wc -l | tr -d ' ')" "^0$"
has "status --all keeps history" "$(P status --all)" "A1 +core +merged"

# ---------------------------------------------------------------- local-only mode
echo "local-only mode"
git init -q -b staging "$T/loc" && cd "$T/loc" && mkdir -p docs .claude
printf '**P0: Base**\n\n**Goal:** a bold label line must not become a phase.\n\n| Id | Task | Depends on | Parallel | Owner | Status |\n|---|---|---|---|---|---|\n| T0.1 | One | — | no | agent | |\n| T0.2 | Two | T0.1 | yes | agent | |\n' > docs/progress.md
printf 'true\n' > t.sh
printf '{"remote": null, "plan": {"file": "docs/progress.md"}, "worktree": {"env_file": ""}, "gate": {"tests": ["bash t.sh"]}, "land": {"progress_file": "docs/progress.md"}}' > .claude/phase.json
git add -A && git commit -qm init
has "serial flag and dotted ids" "$(P ready)" "T0.1 +P0 +main +ready +no deps; serial"
P add T0.1 >/dev/null; ( cd .worktrees/t0_1 && echo x > x.txt && git add -A && git commit -qm "T0.1: x" )
has "a serial task runs alone" "$(P add T0.2)" "T0.1 is serial and still active"

P check T0.1 >/dev/null; P merge T0.1 >/dev/null
has "mark sets the table status cell" "$(P mark T0.1)" "status set to 'done 20[0-9-]+'"
has "only T0.1's row changed" "$(grep -c '| done 20' .worktrees/_integration/docs/progress.md)" "^1$"
has "land fast-forwards the local base" "$(P land T0.1 'T0.1: x')" "landed T0.1"
has "checked-out base moved and is clean" "$(git status --porcelain | wc -l | tr -d ' ') $(ls x.txt 2>/dev/null)" "^0 x.txt$"
has "T0.2 ready after T0.1" "$(P ready)" "T0.2 .*ready"

echo
echo "phase e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
