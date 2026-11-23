# phase.json reference

`<repo>/.claude/phase.json` holds everything project-specific; the skill and `phase.py` hold nothing. The file is deep-merged over the defaults in `phase.py` (`DEFAULTS`), so you only write what differs. Start from `phase.py init`.

## Placeholders

Strings in `worktree.env`, the hooks, `gate.tests`, `gate.per_file`, `brief.*`, `review.checklist` and `slots.vars` can use:

| Placeholder | Value |
|---|---|
| `{ID}`, `{id}` | task id as in the plan (`T0.4`); normalized for names (`t0_4`) |
| `{wt}`, `{main}` | the task's worktree; the repo's main checkout |
| `{port}`, `{slot}` | per-task port (`slots.port_base + slot`); slot 10–99, unique among active tasks |
| `{date}` | the day the task was added, `YYYY_MM_DD` |
| `{repo}`, `{base}`, `{phase}` | repo name, base branch, the phase.py command line |
| `{task}`, `{spec}`, `{done_when}` | plan columns (in `brief`) |
| `{file}` | the changed file (in `gate.per_file`) |
| `{main_env:KEY}` | KEY from the main checkout's env file |
| `{<var>}` | any key of `vars`; the environment overrides it with `PHASE_VAR_<VAR>` |

Hooks run with `bash` in the worktree. They also get `PHASE_ID`, `PHASE_TASK`, `PHASE_WT`, `PHASE_MAIN`, `PHASE_PORT`, `PHASE_SLOT`, `PHASE_REPO`, `PHASE_BASE`, and `PHASE_ACTION` (`add`, `integration`, `refresh`, `test` or `remove`).

## Keys

| Key | Meaning |
|---|---|
| `project` | name used in prompts ("the Release 1 plan") |
| `base` | branch tasks are cut from and land on (default `staging`) |
| `remote` | remote name (default `origin`); `null` = local only, so land fast-forwards the local base branch |
| `vars` | values for placeholders (tool paths and the like) |
| `agents.max` | implementers at once (default 5). `add` refuses past it, past a repo's `max_agents`, past a phase cap, and next to a serial task, unless `--force` |
| `agents.tiers` | `{name: {model, effort}}`: named Agent tool parameters (`model`: `opus`, `sonnet`, ...; `effort`: `low` to `max`). Leave one out, or use `inherit`, to take the session's. Empty (default) = everything inherits |
| `agents.default_tier`, `agents.tier_of` | the tier of a task whose plan row names none; `{task id: tier}` overrides the plan |
| `agents.review_tier`, `agents.escalate_tier` | the tier of reviewers; the tier a task moves to when its first attempt is not enough (`tier <ID> --escalate`, `fix-brief`) |
| `plan.file` | the plan file with the task tables, read from the base branch (required) |
| `plan.columns` | header names per field: `id`, `task`, `deps`, `status`, `owner`, `spec`, `done_when`, `parallel`, `tier` (case-insensitive lists) |
| `plan.done` | regex on status that means done (default `^done\b`) |
| `plan.agent_owners` | owner values (prefixes) a subagent may take; anything else is `manual` (default `agent` and empty) |
| `plan.manual_markers` | text in the task cell that makes it manual (default `` `you` ``) |
| `plan.manual_phases` | regex on a phase heading that makes the whole phase manual (default `no subagents\|^ops\b`) |
| `plan.serial_values` | `parallel` column values that mean "run alone" (default `no`) |
| `plan.cap` | regex on a phase heading giving a per-phase agent cap (default `max (\d+) agents?`) |
| `plan.format` | `auto` (default), `table` or `blocks`. `blocks` = a plan written by the `scope` skill; `auto` detects it |
| `plan.blocked_by` | scope plans: `manual` (default) holds a task whose **Blocked by** names an `A<n>` still `unconfirmed` or a `CQ`/`TQ` not marked answered; `warn` starts it anyway and puts the open items in the brief |
| `repos` | `{name: {path, primary, env, clone, markers, row_markers, max_agents, worktree, gate, deploy, brief, review}}`. The primary repo holds the plan, the state and the progress file. `env` names an environment variable that overrides `path`; `clone` is a URL for the error message. `markers` are strings in a phase heading, and `row_markers` regexes on a task row, that send tasks to this repo. Per-repo sections override the top-level ones. |
| `slots.port_base` | default 8100; the integration worktree gets `port_base - 1` |
| `slots.avoid` | `{repo, path, regex}`: treat slots already used today under `path` as taken (regex with `{date}`, group 1 = slot), e.g. migration names |
| `slots.vars` | derived placeholders, e.g. `"migration_prefix": "{date}_{slot}00"` |
| `worktree.dir` | default `.worktrees` (added to `.git/info/exclude`) |
| `worktree.env_file`, `env_fallback` | copied from the main checkout (or the fallback), then `env` overrides are applied |
| `worktree.env` | `KEY: value` overrides per worktree: own database, port, blanked credentials |
| `worktree.clone` | directories copied from the main checkout (copy-on-write on macOS), e.g. `vendor` |
| `worktree.copy`, `link` | globs to copy if missing; paths to symlink (e.g. `node_modules` when it is safe to share) |
| `worktree.setup` | commands after creation (create databases, install, migrate); idempotent |
| `worktree.refresh` | commands after a sync or squash (reinstall when lockfiles change, migrate) |
| `worktree.teardown` | commands on remove (drop databases) |
| `worktree.hook_timeout` | seconds before a setup, refresh or teardown hook is killed with its children (default 600). A hook over 30 s is named in the output |
| `worktree.exclude` | extra paths for `.git/info/exclude` (generated config files) |
| `gate.tests` | commands that must pass, run in the worktree for `check` and in the integration worktree for `merge` |
| `gate.test_timeout` | seconds before one test command is killed (default 1800) |
| `gate.slots` | how many test runs (`check`, `merge`) may go at once on this machine (default 0: no limit). Agents' gates that compete for the CPU make slow tests hit their timeouts; 2 is a good value with parallel test runners |
| `gate.merge_min` | commands `merge` runs when the squash is exactly the tree the gate already tested with the same commands, and the base has not moved under the branch (default null: always run everything). Type check and build are the useful ones: a file the task forgot to commit passes its own gate but not a clean checkout. `[]` runs nothing. `merge --full` runs everything |
| `gate.conditional` | `[{when: regex on changed paths, run: [commands]}]`, e.g. integration tests when the schema changed |
| `gate.per_file` | `[{glob, run, name}]` run on each added or modified file (`{file}`), e.g. a syntax check |
| `gate.forbid` | globs that must never be committed (defaults cover env files, keys, `node_modules`, the report); `forbid_allow` lists exceptions |
| `gate.owned` | globs only the orchestrator edits (the plan and progress files are always included) |
| `gate.immutable` | globs where existing files must not change, only new ones be added (applied migrations, baselines) |
| `gate.rules` | `[{name, regex, paths, exclude, level: fail\|warn, message}]` on added lines |
| `gate.secret_exclude` | globs skipped by the built-in secret scan (public client keys) |
| `gate.test_globs` | globs of test files. When set, the gate checks that code changes come with test changes, and fails on skipped or focused tests added in them |
| `gate.require_tests` | `warn` (default) or `fail` when code changed but no file in `test_globs` did |
| `gate.no_tests_needed` | changed paths that need no tests (default `*.md`, `docs/*`) |
| `gate.skip_markers` | regex for skipped/focused tests on added lines in `test_globs` (default covers PHPUnit, Jest/Vitest/Mocha, pytest, Go, Flutter `skip:`); empty to turn off |
| `gate.review.lines` | changed lines above which review is required (default 400) |
| `gate.review.skip_diff` | globs of generated files left out of the reviewer's diff (lock files, `*.gen.*`, snapshots) |
| `gate.review.triggers` | `[{name, paths: regex}]`; a match makes review required, with that reason |
| `land.progress_file` | must change in the landing commit; empty to skip |
| `land.allow_after_merge` | globs the orchestrator may edit after merge's checks (default `docs/*`) |
| `land.ssh_push_when` | globs that force an SSH push (a token without `workflow` scope can't push workflow files) |
| `deploy` | `{github_workflow, health_url, health_status}` (top level or per repo); used by `deploy-wait` |
| `smoke` | `{base_url, basic_auth: {user, password_file, skip_paths: regex}}`; used by `smoke` |
| `brief.spec`, `brief.done_when` | how to point an implementer at the spec ("the `#### {ID}` section of docs/plan.md") |
| `brief.read` | documents every implementer and reviewer reads first |
| `brief.rules` | project rules added to every implementer and reviewer prompt |
| `brief.extra` | extra brief lines, e.g. "Migrations: name new files {migration_prefix}01_<name>" |
| `brief.inline` | spec sections copied into the brief, so the implementer doesn't spend turns finding and reading them: `[{file, heading, names_from?}]`. `file` may use placeholders and globs (`{spec}`, `docs/plan/*.md`); `heading` is the start of the heading line (`## {ID}` matches `## T0.2 Add tenants`, not `## T0.20`), and the section runs to the next heading of the same or a higher level. With `names_from` (a regex with one group), the entry repeats for each name it finds in the sections copied so far, with `{name}` in `heading`: e.g. `` {"file": "docs/plan/02-data-model.md", "heading": "#### `{name}`", "names_from": "`([a-z_]+)`"} `` copies the subsection of every table the spec names. Scope plans always get their task block copied |
| `brief.inline` with `line` | `{file, line, names_from?}` copies single lines instead of a section: rows of a requirements or decisions table. `line` is a regex that may use `{name}`: e.g. `{"file": "docs/prd.md", "line": "^\\| {name} \\|", "names_from": "\\b(DM-E\\d+-\\d+)\\b"}` copies the row of every requirement the spec cites |
| `brief.inline` `names_in` | `"first"`: look for names only in the first section copied (the task's own spec). Without it every section copied so far counts, so one table's text can pull in tables and rows the task doesn't need |
| `brief.exports` | `{regex, max}`: for each existing file the spec names in backticks, its length and the lines matching `regex` (exported signatures), up to `max` characters (default 8000). Empty regex = off. TypeScript: `^export (default )?(async )?(abstract )?(function\|class\|const\|type\|interface\|enum)\b` |
| `brief.dep_reports` | characters of the direct dependencies' reports (Interfaces, Spec differences, Built) copied into the brief (default 6000; 0 = off) |
| `brief.inline_max` | character budget for `brief.inline` (default 40000); sections past it are listed for the implementer to read |
| `review.checklist` | project invariants the reviewer checks one by one |
| `doctor.require` | tools that must exist (placeholders allowed) |
| `doctor.checks` | `[{name, run}]` commands that must exit 0 (database reachable, infra up). `doctor` also warns when a gate, test or commit command agents run would prompt for approval (it reads the user and project `.claude/settings*.json` allow, ask and deny rules) and prints the rules to add |

## Scope plans (task blocks)

Plans from the `scope` skill are read directly: `### P<n> — Name` phases, `#### T<p>.<n> — Title` task blocks with `- **Status:**`, `**Depends on:**`, `**Parallel:**`, `**Blocked by:**`, `**Acceptance criteria:**` and `**Verify:**`. `todo` and `in-progress` mean not started, `done` is done, `blocked` is manual. The brief points the implementer at the task block, uses the acceptance criteria as done-when and lists the Verify commands. Set `plan.file` and `land.progress_file` to the plan; after `merge`, `phase.py mark <ID>` sets `Status: done` and ticks the criteria. Repo markers are matched against the phase heading and its Goal/Exit lines, row markers against the task title and Goal.

## Plan format (tables)


Markdown tables under phase headings, either `**P0: Name**` or `## P0: Name` (text after the bold title, such as "(max 2 agents)", feeds `cap`, `manual_phases` and the repo markers). The first row whose cell matches `columns.id` is the header. Dependencies are separated by `,`, `;` or `+`. Ranges expand: `A1–A4`, `T0.1-T0.3`, `E2a–E2e`. Any other word ("adoption") makes the task `manual` with a "gated on" note. Status text that isn't done makes the task `partial`.

## Merge-queue guarantees

- `merge` needs a passed gate on the branch tip, and when the gate said `review required`, an `approve` for that same tip.
- Only one task is in `merging` or `landing` at a time.
- `land` records each step (`land_step`: `committed`, `other_committed`, `other_pushed`). If a push fails, running `land` again continues from there; `merge` and `abort` refuse while a secondary-repo commit is already pushed.

## Sessions and locks

- **Lease** (`.phase/lease.json`): one orchestrator session per project. `add`, `note`, `merge`, `land`, `abort`, `approve`, `mark` and `remove` take or renew it. The session is `PHASE_SESSION`, else Claude Code's session id, else `terminal:<user>@<host>`; its pid is `PHASE_SESSION_PID`, else `CLAUDE_PID`. Another session is refused with exit code 3 while the holder's process is alive (same host); a lease with no pid, or from another host, holds until released. `lease`, `lease release`, `lease release --force`. Read-only commands and the implementer's `check` and `sync` don't need it.
- **State lock** (`.phase/state.lock`, flock, waits up to 60 s): every state write, and `add`'s capacity check + slot allocation + claim as one step, so racing adds can't exceed the limits or share a slot.
- **Queue lock** (`.phase/queue.lock`, flock, no wait): held for all of `merge`, `land`, `mark` and `abort`, which share the integration worktree. Busy = exit 3.
- flock locks are dropped by the kernel when a process exits, crash included, and are not inherited by hooks or test commands. They need a local filesystem: don't put `worktree.dir` on NFS.

## Run files

Briefs, notes, review packages (`<id>.brief.md`, `<id>.notes.md`, `<id>.review/`), kept reports and `minors.md` live in the state directory next to the task states, outside every worktree, so they can't be committed and don't trip formatters.

## Timeouts

`git fetch` is killed after 60 s (the last known base is used), a push after 300 s (land rebases and retries, up to 3 times), hooks after `worktree.hook_timeout`, test commands after `gate.test_timeout`. The whole process group goes, so nothing is left running; stopping phase.py itself (TERM or HUP) stops them too.

## Cost

`phase.py cost [ID ...] [--days N]` reads Claude Code's transcripts of this project (`$CLAUDE_CONFIG_DIR` or `~/.claude`) and prints, per agent, the model, effort, calls, largest context, output tokens, compactions and the price at API rates (`PRICES` in phase.py; `-` for a model not listed). It finds agents by their description, which must start with `<ID>:`. A compaction is a call without usage in the transcript, so its price is a floor: a cached read of the context plus the summary. With cache reads at a twentieth of the input price, compacting a run of a few dozen calls costs more than it saves, so the agents' `autoCompactWindow` is a safety net, not a saving. The last lines price each orchestrator session as a whole. Compare a new tier or a config change with it before rolling it out: look at price per landed task, fix agents included, next to the review findings.

## Timing

`add`, `check`, `note status=...`, `approve`, `merge` and `land` append timed events to the task's state. `phase.py stats [ID ...]` turns them into per-task durations: build (add to `status=review`), gate runs (and how many reused a test pass on the same commit), review wait (`status=review` to the last approval), merge attempts, land and total. Use it to see where a slow run's time went.
