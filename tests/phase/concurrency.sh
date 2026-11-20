#!/usr/bin/env bash
# phase under concurrency: orchestrator lease between sessions, racing adds against agents.max and slots,
# no lost updates to task state, and the merge-queue lock (fail fast, freed when its holder is killed).
# Local repos only. Run: tests/phase/concurrency.sh   (KEEP=1 keeps the temp dir)
set -uo pipefail
unset PHASE_SESSION PHASE_SESSION_PID CLAUDE_CODE_SESSION_ID CLAUDE_PID

ROOT=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PHASE="$ROOT/plugins/ship/skills/phase/phase.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/phase-conc.XXXXXX")
trap '[ -n "${KEEP:-}" ] && echo "kept $T" || rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=true
pass=0; fail=0
ok()   { pass=$((pass + 1)); echo "  ok    $1"; }
bad()  { fail=$((fail + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        | /' | head -30; }
has()  { if printf '%s' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1 (expected /$3/)" "$2"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
hasnt(){ if printf "%s" "$2" | grep -qE -- "$3"; then bad "$1 (unexpected /$3/)" "$2"; else ok "$1"; fi; }
ME=$$
as()   { local s=$1 pid=$2; shift 2; PHASE_SESSION=$s PHASE_SESSION_PID=$pid python3 "$PHASE" "$@" 2>&1; }
dead_pid() { sleep 0 & local p=$!; wait $p 2>/dev/null; echo $p; }

repo() { # dir: local-only repo with six independent tasks, agents.max 3
  git init -q -b staging "$1" && cd "$1" && mkdir -p docs .claude
  { printf '**P1: Work**\n\n| Id | Task | Depends on | Owner | Status |\n|---|---|---|---|---|\n'
    for i in 1 2 3 4 5 6; do printf '| T%d | Task %d | — | agent | |\n' $i $i; done; } > docs/progress.md
  printf '{"remote": null, "agents": {"max": 3}, "plan": {"file": "docs/progress.md"}, "worktree": {"env_file": ""}, "gate": {"tests": ["true"]}, "land": {"progress_file": "docs/progress.md"}}' > .claude/phase.json
  git add -A && git commit -qm init
}

echo "lease"
repo "$T/a"
out=$(as s1 $ME add T1); has "s1 starts T1" "$out" "worktree: "
out=$(as s2 $ME add T2); rc=$?
eq "a second live session is refused with exit 3" "$rc" "3"
has "refusal names the holder" "$out" "busy: another orchestrator holds this project: session s1"
eq "refused add claimed nothing" "$(ls .worktrees | grep -c t2)" "0"
out=$(as s2 $ME status)
has "read-only commands still work for s2" "$out" "^T1 +main +running"
has "status names the orchestrator" "$out" "^orchestrator: session s1 "
hasnt "the lease file is not a task" "$out" "^\? "
has "implementer commands need no lease" "$(as s2 $ME check T1 --quick)" "RESULT: FAIL .*"
out=$(as s2 $ME lease release); rc=$?
eq "s2 cannot release s1's lease" "$rc" "3"
has "release refuses while tasks are active" "$(as s1 $ME lease release)" "tasks are still active \\(T1\\)"
has "s1 releases its own lease with --force" "$(as s1 $ME lease release --force)" "released lease of session s1"
gone=$(dead_pid)
as s3 "$gone" note T1 a=1 >/dev/null
has "lease shows an exited holder" "$(as s2 $ME lease)" "session s3 .*process exited: free to take over"
out=$(as s2 $ME note T1 b=2)
has "a dead session's lease is taken over, with its active tasks named" "$out" "taking over the lease from session s3.*resume its tasks: T1"
out=$(as s1 $ME note T1 c=3); rc=$?
eq "s1 is now refused (s2 is alive)" "$rc" "3"
has "--force releases a lease whose session is gone" "$(as s1 $ME lease release --force)" "released lease of session s2"
cd "$T"

echo "racing adds (one session, agents.max 3)"
repo "$T/b"
for i in 1 2 3 4 5 6; do ( as s1 $ME add T$i > "$T/add$i.log" ) & done; wait
eq "exactly agents.max tasks claimed" "$(grep -l '"status": "running"' .worktrees/.phase/*.json | wc -l | tr -d ' ')" "3"
eq "exactly agents.max worktrees" "$(ls .worktrees | grep -c '^t')" "3"
eq "the others were refused for capacity" "$(grep -l 'not starting T.: 3 implementers active' "$T"/add*.log | wc -l | tr -d ' ')" "3"
slots=$(python3 -c 'import glob,json; s=[json.load(open(f))["slot"] for f in glob.glob(".worktrees/.phase/t*.json")]; print(len(s), len(set(s)))')
eq "slots (ports, migration prefixes) are unique" "$slots" "3 3"
eq "no claim left behind by a refused add" "$(ls .worktrees/.phase/*.json | grep -v lease | wc -l | tr -d ' ')" "3"

echo "no lost updates"
first=$(cd .worktrees/.phase && ls t*.json | head -1 | sed 's/.json$//' | tr a-z A-Z)
for i in $(seq 1 20); do ( as s1 $ME note "$first" "k$i=$i" >/dev/null ) & done; wait
keys=$(python3 -c "import json; d=json.load(open('.worktrees/.phase/$(echo "$first" | tr A-Z a-z).json')); print(sum(1 for i in range(1,21) if d.get('k%d'%i)==str(i)))")
eq "20 concurrent writes to one task all kept" "$keys" "20"

echo "merge queue lock"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT); fcntl.flock(fd, fcntl.LOCK_EX); os.pwrite(fd, b"pid holder-test", 0); time.sleep(60)' .worktrees/.phase/queue.lock &
holder=$!
for _ in $(seq 1 50); do python3 -c 'import fcntl,os,sys; fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)' .worktrees/.phase/queue.lock 2>/dev/null || break; sleep 0.1; done
out=$(as s1 $ME merge "$first"); rc=$?
eq "merge while the queue is held exits 3" "$rc" "3"
has "and says who holds it" "$out" "busy: the merge queue is in use by pid holder-test"
kill -9 $holder; wait $holder 2>/dev/null
out=$(as s1 $ME merge "$first")
has "a killed holder frees the queue (no stale lock)" "$out" "gate has not passed"
cd "$T"

echo
echo "phase concurrency: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
