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

The agent types are `phase-implementer` and `phase-reviewer`. When the skill is installed as a plugin they are listed as `ship:phase-implementer` and `ship:phase-reviewer`; use whichever name the agent list shows.

## Setup (once per repo)

If `.claude/phase.json` is missing, `$P` says so. Make one:

1. `<base directory>/phase.py init > .claude/phase.json`.
2. Fill it in from the repo's own docs (AGENTS.md or CLAUDE.md, the plan file, CI, deploy docs): plan columns, the test command, setup hooks for per-worktree databases, rules, deploy and smoke. `reference.md` in the base directory lists every key.
3. Run `$P doctor` until it is clean, then `$P ready`.
4. Show the user the config and let them commit it: it is part of the repo.

## 0. Preflight and resume (every run)

1. **Fresh session.** Every orchestrator turn re-reads the whole conversation. If this conversation already holds other work (a redesign, screenshots, long debugging), each turn of the run gets slow. In that case tell the user to `/clear` and run `/phase` again before starting anything. State lives in `.phase/`, so nothing is lost.
2. `$P doctor`. A FAIL stops work on that repo: tell the user the printed fix.
   - A `permissions:` warning means agents will stop on approval prompts and wait for the user, often for minutes per command. Show the printed rules and, with the user's OK, add them to `.claude/settings.local.json` before you start agents. Skip this only when the session runs in auto mode.
   - **One orchestrator per project.** The first command that changes tasks takes this session's lease. Exit code **3** (`busy:`) means another live session orchestrates the project, or the merge queue is in use: tell the user who (the message says) and stop; headless, just exit. Never `lease release --force` a session that may still be running: its agents would be duplicated. A lease whose Claude process has exited is taken over automatically, and its active tasks are named so you can resume them.
3. `$P status`: tasks from earlier sessions. State lives in `<worktrees>/.phase/`, so it survives compaction and new sessions.
   - `merging`: run `$P land` if the progress file was already edited in the integration worktree, otherwise `$P abort` and merge again.
   - `landing`: a land stopped after a commit or push (it prints the step). Run `$P land <ID> "<same message>"` again; it continues from that step. Never abort it: part of it may already be pushed.
   - `running` or `review` with an agent id: if that agent is alive in this session, wait for it. If not, run `$P check <ID> --quick`. With commits on the branch, review them and start a new implementer whose prompt says "continue: the branch already has N commits" plus the gate output. With no commits, start fresh.
   - Orphan `phase/*` branches: inspect them, then adopt with `$P add <ID>` or delete them.
4. `$P overlap` when anything is active.

## 1. Pick the tasks

- The plan is a progress file with task tables, or a plan written by the `scope` skill (read directly). No plan yet: write one with `/scope` first.
- `$P ready [scope]` lists each task with a state:

  - `ready`, `blocked` (with what it waits on), `manual`, `running`, `done`
  - `partial`: has status text but isn't done. Read the text; the rest is usually a deploy or user step.
  - `manual` with "blocked by open A3, CQ2" (scope plans): the task waits on a client or team answer. Name the question for the user; once it is answered or the assumption confirmed in the plan, the task becomes ready.

  - flags: `serial` (the plan says it can't run in parallel), phase caps, and `unblocks N` (how many unfinished tasks wait on it, directly or through others)
- Scope: phase ids, task ids or `all`. With no argument, take the first phase with a ready task.
- Read the project rules (`brief.read` in phase.json), and skim each candidate's spec only as far as you need to spot overlapping work. The brief carries the full spec to the implementer (`brief.inline`), so don't load it into your own context.
- **Never delegate:**
  - `manual` rows
  - anything that touches production (merging to the production branch, production servers or data)
  - irreversible steps (secret rotation, deleting data or cloud resources)

  Tell the user what is needed, with exact commands, and continue with the rest. Every production step needs the user's explicit go, given for that step, after the staging evidence.
- **Concurrency:**
  - At most `agents.max` implementers at once. Respect a repo's `max_agents` and the phase caps.
  - With fewer slots than ready tasks, start the highest `unblocks` first: they hold up the most later work.
  - A `serial` task runs with no other task active in the same repo.
  - `$P add` enforces these and refuses with the reason. Pass `--force` only when the user agreed.
  - Use the tier of each task (see "Tiers" below); `ready` shows it.
  - Don't run two tasks together whose specs rework the same feature (same module, service or table); start the second after the first lands. Shared wiring files (route lists, registries, indexes) are fine: they merge, and the checks catch the rest.
- Tell the user in 2–3 lines what you start, what you skip and why, then go. Wait for a yes only when a task needs something from them.

## 2. Start implementers

For each task, one Bash call each, never chained behind a `land` or another task's `add` (if one command hangs, only that one is lost):

```bash
$P add <ID>             # worktree, branch phase/<id>, env, slot and port, setup hooks
$P brief <ID> --write   # writes the brief to a file; prints the Agent parameters and a short prompt
```

The brief stays in its file, so it costs your own context nothing: don't print or read it. In the printed prompt, replace `Context from other tasks: none` with anything decided this session that the spec doesn't say: an interface another task depends on, a user decision, a file another running task is reworking. Keep it to a few lines; don't repeat the brief or the session's history.

Send all Agent calls **in one message**: `subagent_type` the implementer type (`phase-implementer` or `ship:phase-implementer`), the printed prompt, description `<ID>: <short task>` (the ID must come first: `$P cost` finds agents by it), and **the `model` and `effort` that `brief --write` printed**. Set both exactly as printed, and leave out the ones it doesn't print: this skill asks for them. If that agent type isn't listed, use `general-purpose` with `$P brief <ID> --inline-rules`. Then record each agent id: `$P note <ID> agent=<id>`.

The agents run in the background and you are notified as each finishes. Don't poll. Meanwhile, review and land whatever is done.

### Tiers

`agents.tiers` in phase.json names model and effort pairs; the plan's `Tier` column (or `agents.tier_of`) gives each task one. `$P tier <ID>` shows what a task and its reviewer get. With no tiers configured, agents inherit the session's model and effort, and nothing is printed to set.

Escalate when the cheaper attempt is not enough, instead of retrying at the same level:

- the implementer reports BLOCKED, or hands back twice without `RESULT: PASS`: `$P tier <ID> --escalate`, then a **fresh** implementer with the new parameters and the `$P brief <ID> --write` prompt plus "Continue: the branch has N commits; read the notes file and the report first."
- the reviewer finds a blocker or major: `$P fix-brief <ID>` prints who fixes it, and the escalated tier when that is a fresh agent.

Never change a running agent's model or effort; that throws its cache away.

## 3. Each finished task: gate, then review

1. `$P note <ID> status=review`, then `$P check <ID> --quick`. It takes seconds: every static check, plus whether review is required.
   - FAIL: send the lines back to the same agent (SendMessage), or fix small things in the worktree yourself, commit, and check again.
2. If it printed `review required (...)`, start a `phase-reviewer` agent in the background now, description `<ID>: review`, with the prompt and Agent parameters that `$P review-brief <ID> --write` prints. It has the diff and the spec as files, so the reviewer starts judging at once. Don't add your own conclusions, and never tell it what not to flag.
3. While it reviews, **run the full gate yourself**: `$P check <ID>`. Don't trust the report. Test commands that already passed on this exact commit are not re-run (the record is phase.py's own, and merge tests every combination that commit was not tested in); everything else is checked again. A fix commit needs the gate again, and a new approval.
4. Read the work:
   - With a reviewer: read the report and the verdict, not the whole diff and not the findings file. The reviewer reads it line by line in its own context; reading it twice only fills yours.
   - Without one: read the diff against the spec and the report (the diff command is in `$P review-brief <ID>`), and check each done-when point.
5. Reviewer verdicts:
   - **Blockers and majors** are fixed before merge, in one round with all of them:
     - `$P fix-brief <ID> [--only 1,3]` decides who fixes them and prints the message. `Resume the implementer`: SendMessage it at once, since its cache stays warm for minutes only. `Fresh agent`: start an implementer, description `<ID>: fix`, with the printed prompt and parameters. Follow what it prints: a warm agent already knows the code, a cold one costs more to wake than a fresh one, and a blocker gets a stronger pair of eyes. Run it as soon as the verdict arrives, before the minors.
     - Then gate again. After a blocker, `$P review-brief <ID> --recheck` gives a reviewer only the fix commits.
   - **Minors never start a round.** `$P minor <ID> "<file:line: what goes wrong → fix>"` for each, and merge. If you think a minor is really about visibility, rights, lost data or two users at once, treat it as major.
   - A finding you judge wrong: say why in the approve note.
   - Then record it: `$P approve <ID> --note "<reviewer APPROVE, or which findings you verified fixed>"`. Merge refuses a required review without an approval for the current tip, so a new commit needs a new approval.

6. No browser, device or visual checks during the run, by you or by any agent: they stall the queue. Collect the screens each task changed (from the reports' "Needs the user") into the final summary, for the user to look at.

## 4. Merge queue (one task at a time, in finishing order)

```bash
$P merge <ID>      # squash onto a fresh base in <worktrees>/_integration and run the full checks
```

When the base has not moved under the branch, the squash is the very tree the gate tested; with `gate.merge_min` set, merge then runs only those commands in its clean checkout. Any other merge runs everything (`--full` forces it).

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
- `$P remove <ID>`: teardown hooks, worktree, branch. The report is kept in `.phase/`, and later tasks get its Interfaces in their brief.
- Run `land`, `remove` and each `add` as **separate** Bash calls. phase.py kills a fetch, push, hook or test that hangs and says which one; a chain of five commands hides it.
- `$P overlap`: for every running task that shares files with what just landed, SendMessage its agent: "the base moved (<task> landed, touching <files>); at your next commit run the sync command and check again."
- **Rolling start:** run `$P ready <scope>` again and start any task in scope that became ready (section 2). Stop when nothing in scope is running, ready or queued.
- **Minors:** when nothing else is ready, or `$P minors` lists about 15, fix them in one batch: `$P add M<n>` (an ad-hoc task), one implementer with the list, gate, merge with a done-log line, then `$P minors --close <numbers>`.
- **Wave boundary:** when nothing is running, in review or queued but later tasks remain, and this conversation has grown long, tell the user to `/clear` and run `/phase <scope>` again. The next wave starts with a fresh context, and nothing is lost because state lives in `.phase/`.

## 5. Report

Finish with a short summary:

- tasks landed (commit shas)
- where the time went: the slowest step per task from `$P stats`, when one stands out
- what it cost: the per-task line of `$P cost <IDs>`, any agent it shows as COMPACTED, and any task that cost much more than the others or needed escalation (its tier, or its size, is wrong in the plan)
- open minors (`$P minors`)
- deploy and smoke results
- decisions made
- screens the tasks changed, for the user to look at (nothing was checked in a browser)
- what the user must do, as exact commands or console steps, with staging and production separated
- tasks still blocked and what unblocks them
- the next command

Never release to production yourself.

When you stop and no task is active (`$P status` shows none running, in review, merging or landing), `$P lease release`, so another session or a scheduled run can take over. With tasks still active, keep the lease.

## Running it unattended

- `/loop 30m /phase all` in an open session: each round resumes, lands what finished and starts what became ready. Same session, same lease.
- A scheduled headless run (`claude -p "/phase all"` from cron or launchd) is safe next to an interactive session: whichever runs second gets exit 3 and stops. It needs a permission allowlist for `phase.py`, git and the project's test tools, and a lower `agents.max` keeps usage limits in check.
