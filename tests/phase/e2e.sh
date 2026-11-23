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

# ---------------------------------------------------------------- merge reuse, test slots, fix-brief, cost
echo "merge reuse, test slots, fix-brief, cost"
git init -q -b staging "$T/eff" && cd "$T/eff" && mkdir -p docs .claude
export CLAUDE_CONFIG_DIR="$T/claude"
printf '**P0: Base**\n\n| Id | Task | Depends on | Owner | Status | Tier |\n|---|---|---|---|---|---|\n| T1 | One | — | agent | | |\n| T2 | Two | — | agent | | |\n| T3 | Three | — | agent | | small |\n| T4 | Four | — | agent | | |\n| T5 | Five | — | agent | | |\n' > docs/progress.md
printf 'echo full >> "%s/runs.log"\n' "$T" > t.sh; printf 'echo min >> "%s/runs.log"; test ! -e need.txt || test -e lib.txt\n' "$T" > m.sh
cat > .claude/phase.json <<'EOF'
{"remote": null, "plan": {"file": "docs/progress.md"}, "worktree": {"env_file": ""},
 "agents": {"tiers": {"big": {"model": "opus", "effort": "high"}, "mid": {"model": "opus", "effort": "medium"}, "small": {"model": "sonnet"}},
            "default_tier": "mid", "escalate_tier": "big"},
 "gate": {"tests": ["bash t.sh"], "merge_min": ["bash m.sh"], "slots": 1, "review": {"lines": 0}}, "land": {"progress_file": "docs/progress.md"}}
EOF
git add -A && git commit -qm init
runs() { tr '\n' ' ' < "$T/runs.log"; : > "$T/runs.log"; }
task() { P add "$1" >/dev/null; ( cd ".worktrees/$(echo "$1" | tr A-Z a-z)" && echo "$1" > "$1.txt" && git add -A && git commit -qm "$1: x" ); }
task T1; task T2; task T4; : > "$T/runs.log"
P check T1 >/dev/null; P approve T1 >/dev/null; has "the gate runs the tests" "$(runs)" "^full $"
out=$(P merge T1); has "identical tree: merge says what it skipped" "$out" "same files as the gate tested"; has "identical tree: only merge_min runs" "$(runs)" "^min $"
P mark T1 >/dev/null; has "reused merge lands" "$(P land T1 'T1: x')" "landed T1"
P check T2 >/dev/null; P approve T2 >/dev/null; runs >/dev/null
hasnt "moved base: nothing is skipped" "$(P merge T2)" "same files as the gate"; has "moved base: the full checks run" "$(runs)" "^full $"
P abort >/dev/null
P sync T2 >/dev/null; P check T2 >/dev/null; P approve T2 >/dev/null; runs >/dev/null
has "synced onto the new base: skipped again" "$(P merge T2)" "same files as the gate tested"; P abort >/dev/null; runs >/dev/null
hasnt "merge --full skips nothing" "$(P merge T2 --full)" "same files as the gate"; has "merge --full runs the tests" "$(runs)" "^full $"
P abort >/dev/null
edit 's/"bash t.sh"/"bash t.sh", "true"/' .claude/phase.json
hasnt "other commands than the gate ran: nothing is skipped" "$(P merge T2)" "same files as the gate"; P abort >/dev/null; git checkout -q .claude/phase.json
( cd .worktrees/t4 && printf 'lib.txt\n' > .gitignore && echo x > need.txt && echo x > lib.txt && git add -A && git commit -qm "T4: forgot lib.txt" )
P sync T4 >/dev/null; has "own gate misses the ignored file" "$(P check T4)" "RESULT: PASS"; P approve T4 >/dev/null
has "merge_min in the clean checkout catches it" "$(P merge T4)" "FAIL +full checks after the squash"

python3 - "$T/eff/.worktrees/.phase/test-slot-1.lock" <<'EOF' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(8)
EOF
holder=$!; sleep 1; out=$(P check T2 --full); wait "$holder" 2>/dev/null
has "a full machine makes the gate wait for a slot" "$out" "waited .* for a test slot \(gate.slots: 1\)"; has "then it passes" "$out" "RESULT: PASS"

sess="$CLAUDE_CONFIG_DIR/projects/$(cd "$T/eff" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')/s1/subagents"; mkdir -p "$sess"
task T3; P add T5 >/dev/null
for t in T2 T3; do mkdir -p ".worktrees/.phase/$(echo $t | tr A-Z a-z).review"; printf 'VERDICT: CHANGES\n1. `a.ts:1` - major\n   wrong\n2. `b.ts:1`\n   - severity: blocker\n' > ".worktrees/.phase/$(echo $t | tr A-Z a-z).review/findings-1.md"; done
P note T2 agent=ag2 >/dev/null; P note T3 agent=ag3 >/dev/null
has "no transcript: a fresh agent" "$(P fix-brief T2 --only 1)" "Fresh agent \(no transcript"
cat > "$sess/agent-ag2.jsonl" <<'EOF'
{"type":"assistant","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_creation_input_tokens":100000,"cache_read_input_tokens":0,"output_tokens":1000}}}
{"type":"system","subtype":"compact_boundary","compactMetadata":{"trigger":"auto","preTokens":200000}}
{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"SUMMARY"}}
EOF
echo '{"agentType":"phase-implementer","description":"T2: two"}' > "$sess/agent-ag2.meta.json"
cp "$sess/agent-ag2.jsonl" "$sess/agent-ag3.jsonl"
out=$(P fix-brief T2 --only 1); has "warm: resume the implementer" "$out" "Resume the implementer .* SendMessage to ag2"; has "resume names the finding" "$out" "Fix finding\(s\) 1 of"; hasnt "resume starts no agent" "$out" "Agent parameters"
has "a blocker gets a fresh agent" "$(P fix-brief T2)" "Fresh agent \(a blocker\)"
has "fresh agent has the escalated tier" "$(P fix-brief T2)" "Agent parameters: model: opus, effort: high"
has "--fresh forces one" "$(P fix-brief T2 --only 1 --fresh)" "Fresh agent \(--fresh\)"
has "a weaker model is not resumed" "$(P fix-brief T3 --only 1)" "Fresh agent \(built on sonnet, fixes need opus\)"
touch -t 202001010000 "$sess/agent-ag2.jsonl"; has "cold: a fresh agent" "$(P fix-brief T2 --only 1)" "Fresh agent \(the implementer has been idle"
touch "$sess/agent-ag2.jsonl"; printf '{"type":"assistant","message":{"id":"o1","model":"claude-opus-5-5","usage":{"input_tokens":0,"cache_read_input_tokens":50000,"output_tokens":0}}}\n' > "$(dirname "$(dirname "$sess")")/s1.jsonl"
out=$(P cost T2); has "cost counts compactions and the context they cut" "$out" "T2 +implementer +opus-5-5 +- +1 +0\.0 +200k +1k +1 +\\\$0.56"
has "cost says what compacting cost" "$out" "compactions: 1, at least \\\$0.04"; has "cost prices the orchestrator session" "$out" "orchestrator session s1: \\\$0.01, 1 calls"
has "brief asks for one Read call" "$(P brief T5 --write)" "with one Read call"
has "cost has the actions column" "$(P cost T2)" "PER CALL"
python3 - "$sess/agent-ag2.jsonl" <<'EOF'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(50):
        for k in range(1 if i else 2):
            f.write(json.dumps({"type": "assistant", "message": {"id": "c%d" % i, "model": "claude-opus-5-5", "usage": {"output_tokens": 1},
                    "content": [{"type": "tool_use", "id": "t%d-%d" % (i, k), "name": "Bash", "input": {}}]}}) + "\n")
EOF
out=$(P cost T2); has "actions per call are counted" "$out" "T2 +implementer +opus-5-5 +- +50 +1\.0 "; has "one action at a time is named" "$out" "one action at a time .*T2 implementer \(50 calls\)"

echo "checklist, lessons, doctor timeout"
hasnt "no checklist and no lessons: no self-check" "$(P brief T5)" "Self-check"
edit 's/"review": \{"lines": 0\}/"review": {"lines": 0}}, "review": {"checklist": ["every list is scoped"]/' .claude/phase.json
out=$(P brief T5); has "the implementer gets the reviewer's checklist" "$out" "Self-check, before the gate"; has "with its points" "$out" "^- every list is scoped"
has "lessons start empty" "$(P lessons)" "no lessons"
printf 'VERDICT: CHANGES\n1. `a.ts:1` - major\n   wrong\n   Lesson: A filter must not reveal what the row hides.\n2. `b.ts:1` - minor\n   - **Lesson:** Show a button only if the API would allow it {x}.\n' > .worktrees/.phase/t2.review/findings-1.md
out=$(P approve T2); has "approve collects the lessons" "$out" "A filter must not reveal what the row hides"
hasnt "the same lesson is kept once" "$(P approve T2)" "A filter must not"
has "lesson repeated by hand is not added" "$(P lesson T3 'a filter must not reveal what the row hides')" "already recorded"
has "lesson by hand" "$(P lesson T3 'Test the empty list')" "recorded"
out=$(P lessons); has "lessons are numbered with their task" "$out" "1 T2: A filter must not"; has "third lesson" "$out" "3 T3: Test the empty list"
out=$(P brief T5); has "implementer brief carries lessons" "$out" "lesson from an earlier review: A filter must not reveal what the row hides. \(T2\)"; has "braces in a lesson are kept" "$out" "would allow it \{x\}"
has "review brief carries lessons" "$(P review-brief T5)" "Mistakes earlier reviews found"
edit 's/"checklist": \["every/"lessons": 1, "checklist": ["every/' .claude/phase.json
out=$(P brief T5); has "the newest lessons win" "$out" "Test the empty list"; hasnt "older ones stay out" "$out" "A filter must not"; has "and are marked" "$(P lessons)" "1 \(too old for briefs\) T2"
P lessons --drop 1 3 >/dev/null; out=$(P lessons); has "drop removes" "$out" "1 T2: Show a button"; hasnt "dropped lesson is gone" "$out" "A filter must not"
edit 's/"remote": null/"doctor": {"timeout": 1, "checks": [{"name": "stuck service", "run": "sleep 30"}]}, "remote": null/' .claude/phase.json
t0=$(date +%s); out=$(P doctor); has "a stuck check is a FAIL that says so" "$out" "FAIL +check stuck service: .*timed out after 1s"
[ $(( $(date +%s) - t0 )) -lt 10 ] && ok "doctor does not hang" || bad "doctor hung"
unset CLAUDE_CONFIG_DIR

echo
echo "phase e2e: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
