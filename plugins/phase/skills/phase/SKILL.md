---
name: phase
description: Run a project's plan tasks in parallel with subagents, in any repo that has a .claude/phase.json. Each ready task gets its own git worktree, environment and implementer agent; finished branches pass a deterministic gate and, when needed, an independent review, then land on the base branch through a serial merge queue (squash, full checks, progress file in the same commit, push, deploy watch, smoke). Tasks start as soon as their dependencies land. Use when asked to "do phase P0", "run T0.4", "next phase", "run everything ready", or /phase. Args - phase ids, task ids, "all", or nothing (= the first phase with ready tasks). Also use to set up phase.json for a new repo.
---

# Run plan tasks in parallel

You are the orchestrator. Implementers build in parallel, each in its own worktree. Only you touch the base branch, one task at a time, through the merge queue. This skill knows nothing about any project; everything project-specific is in the repo's `.claude/phase.json`.

The engine is `phase.py` in this skill's base directory (the path shown when the skill loads). Below, `$P` stands for `<base directory>/phase.py --project <repo>`; `--project` can be left out when you run it inside the repo. Type the command out in full, because a shell variable holding a command doesn't word-split in zsh. Commands the script prints are already complete, with absolute paths.

```bash
<base directory>/phase.py --project <repo> help
```

The agent types are `phase-implementer` and `phase-reviewer`. When the skill is installed as a plugin they are listed as `phase:phase-implementer` and `phase:phase-reviewer`; use whichever name the agent list shows.

## Setup (once per repo)

If `.claude/phase.json` is missing, `$P` says so. Make one:

1. `<base directory>/phase.py init > .claude/phase.json`.
2. Fill it in from the repo's own docs (AGENTS.md or CLAUDE.md, the plan file, CI, deploy docs): plan columns, the test command, setup hooks for per-worktree databases, rules, deploy and smoke. `reference.md` in the base directory lists every key.
3. Run `$P doctor` until it is clean, then `$P ready`.
4. Show the user the config and let them commit it: it is part of the repo.

## 0. Preflight and resume (every run)

1. `$P doctor`. A FAIL stops work on that repo: tell the user the printed fix.
2. `$P status`: tasks from earlier sessions. State lives in `<worktrees>/.phase/`, so it survives compaction and new sessions.
   - `merging`: run `$P land` if the progress file was already edited in the integration worktree, otherwise `$P abort` and merge again.
   - `landing`: a land stopped after a commit or push (it prints the step). Run `$P land <ID> "<same message>"` again; it continues from that step. Never abort it: part of it may already be pushed.
   - `running` or `review` with an agent id: if that agent is alive in this session, wait for it. If not, run `$P check <ID> --quick`. With commits on the branch, review them and start a new implementer whose prompt says "continue: the branch already has N commits" plus the gate output. With no commits, start fresh.
   - Orphan `phase/*` branches: inspect them, then adopt with `$P add <ID>` or delete them.
3. `$P overlap` when anything is active.

## 1. Pick the tasks

- The plan is a progress file with task tables, or a plan written by the `scope` skill (read directly). No plan yet: write one with `/scope` first.
- `$P ready [scope]` lists each task with a state:

  - `ready`, `blocked` (with what it waits on), `manual`, `running`, `done`
  - `partial`: has status text but isn't done. Read the text; the rest is usually a deploy or user step.
  - `manual` with "blocked by open A3, CQ2" (scope plans): the task waits on a client or team answer. Name the question for the user; once it is answered or the assumption confirmed in the plan, the task becomes ready.

  - flags: `serial` (the plan says it can't run in parallel) and phase caps
- Scope: phase ids, task ids or `all`. With no argument, take the first phase with a ready task.
- Read the project rules (`brief.read` in phase.json) and each candidate's spec before starting it.
- **Never delegate:**
  - `manual` rows
  - anything that touches production (merging to the production branch, production servers or data)
  - irreversible steps (secret rotation, deleting data or cloud resources)

  Tell the user what is needed, with exact commands, and continue with the rest. Every production step needs the user's explicit go, given for that step, after the staging evidence.
- **Concurrency:**
  - At most `agents.max` implementers at once. Respect a repo's `max_agents` and the phase caps.
  - A `serial` task runs with no other task active in the same repo.
  - `$P add` enforces these and refuses with the reason. Pass `--force` only when the user agreed.
  - Don't run two tasks together whose specs rework the same feature (same module, service or table); start the second after the first lands. Shared wiring files (route lists, registries, indexes) are fine: they merge, and the checks catch the rest.
- Tell the user in 2–3 lines what you start, what you skip and why, then go. Wait for a yes only when a task needs something from them.

## 2. Start implementers

For each task, one Bash call each:

```bash
$P add <ID>        # worktree, branch phase/<id>, env, slot and port, setup hooks
$P brief <ID>      # the implementer prompt
```

Replace the brief's `Context from other tasks: none` with anything decided this session that the spec doesn't say: an interface another task depends on, a user decision, a file another running task is reworking.

Send all Agent calls **in one message**: `subagent_type` the implementer type (`phase-implementer` or `phase:phase-implementer`), the brief as the prompt, description `<ID>: <short task>`. If that agent type isn't listed, use `general-purpose` with `$P brief <ID> --inline-rules`. Then record each agent id: `$P note <ID> agent=<id>`.

The agents run in the background and you are notified as each finishes. Don't poll. Meanwhile, review and land whatever is done.

## 3. Each finished task: gate, then review

1. `$P note <ID> status=review`, then **run the gate yourself**: `$P check <ID>`. Don't trust the report.
   - FAIL: send the lines back to the same agent (SendMessage), or fix small things in the worktree yourself, commit, and check again.
2. Read the diff against the spec and the report (the diff command is in `$P review-brief <ID>`), and check each done-when point.
3. If the gate printed `review required (...)`, start a `phase-reviewer` agent in the background with `$P review-brief <ID>` as its prompt. Don't add your own conclusions.
   - On `VERDICT: CHANGES`: blockers and majors go back to the implementer, or you fix them; then gate again. Send a blocker fix to the reviewer again.
   - Minors you may record and skip.
   - Then record it: `$P approve <ID> --note "<reviewer APPROVE, or which findings you verified fixed>"`. Merge refuses a required review without an approval for the current tip, so a new commit needs a new approval.

4. Check anything the gate can't, such as device or browser behaviour the spec asks for, the way the project rules say.

## 4. Merge queue (one task at a time, in finishing order)

```bash
$P merge <ID>      # squash onto a fresh base in <worktrees>/_integration and run the full checks
```

- `CONFLICT`: `$P sync <ID> --keep`, resolve in the task worktree, `git rebase --continue`, `$P check <ID>`, merge again. For a non-trivial conflict, send it back to the implementer.
- Checks red after the squash: the task collides with something landed since it was cut. Sync, fix, check, merge.

When merge says ok, edit the progress file **in the integration worktree** (the path is printed):

- Set the task's status: `$P mark <ID>` (done, with the date for table plans; for a `scope` plan it sets `Status: done` and ticks the criteria). Pass a status (`$P mark <ID> "deployed; smoke pending"`) when deploy or user steps remain.
- Add a line to the done log.
- Under open items: every deploy step from the report (config with production and staging values, migrations, jobs, packages, one-off commands) and every user ask.
- Other plan-doc notes may go in the same commit; land refuses anything outside `land.allow_after_merge`.
- For a task in a secondary repo, write `{sha}` where its commit goes. Land fills it in and makes the primary progress commit.

```bash
$P land <ID> "<ID>: <what>

Co-Authored-By: <the attribution trailer from the system prompt>"
```

`land` commits and pushes. If the base moved meanwhile, it rebases and re-runs the checks. With `remote: null` it fast-forwards the local base branch instead. After it:

- `$P deploy-wait <sha>` with `run_in_background: true`, when deploy is configured. Keep merging meanwhile; it follows the run containing your commit even when a newer push cancels a pending one.
- After the deploy: `$P smoke <ID>` runs the report's Smoke lines.
  - Deploy or smoke failure: stop the queue and fix forward with a new commit. Never force-push.
- `$P remove <ID>`: teardown hooks, worktree, branch. The report is kept in `.phase/`.
- `$P overlap`: for every running task that shares files with what just landed, SendMessage its agent: "the base moved (<task> landed, touching <files>); at your next commit run the sync command and check again."
- **Rolling start:** run `$P ready <scope>` again and start any task in scope that became ready (section 2). Stop when nothing in scope is running, ready or queued.

## 5. Report

Finish with a short summary:

- tasks landed (commit shas)
- deploy and smoke results
- decisions made
- what the user must do, as exact commands or console steps, with staging and production separated
- tasks still blocked and what unblocks them
- the next command

Never release to production yourself.
