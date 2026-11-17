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

| `plan.file` | the plan file with the task tables, read from the base branch (required) |
| `plan.columns` | header names per field: `id`, `task`, `deps`, `status`, `owner`, `spec`, `done_when`, `parallel` (case-insensitive lists) |
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
| `worktree.exclude` | extra paths for `.git/info/exclude` (generated config files) |
| `gate.tests` | commands that must pass, run in the worktree for `check` and in the integration worktree for `merge` |
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
| `review.checklist` | project invariants the reviewer checks one by one |
| `doctor.require` | tools that must exist (placeholders allowed) |
| `doctor.checks` | `[{name, run}]` commands that must exit 0 (database reachable, infra up) |

## Scope plans (task blocks)

Plans from the `scope` skill are read directly: `### P<n> — Name` phases, `#### T<p>.<n> — Title` task blocks with `- **Status:**`, `**Depends on:**`, `**Parallel:**`, `**Blocked by:**`, `**Acceptance criteria:**` and `**Verify:**`. `todo` and `in-progress` mean not started, `done` is done, `blocked` is manual. The brief points the implementer at the task block, uses the acceptance criteria as done-when and lists the Verify commands. Set `plan.file` and `land.progress_file` to the plan; after `merge`, `phase.py mark <ID>` sets `Status: done` and ticks the criteria. Repo markers are matched against the phase heading and its Goal/Exit lines, row markers against the task title and Goal.

## Plan format (tables)


Markdown tables under phase headings, either `**P0: Name**` or `## P0: Name` (text after the bold title, such as "(max 2 agents)", feeds `cap`, `manual_phases` and the repo markers). The first row whose cell matches `columns.id` is the header. Dependencies are separated by `,`, `;` or `+`. Ranges expand: `A1–A4`, `T0.1-T0.3`, `E2a–E2e`. Any other word ("adoption") makes the task `manual` with a "gated on" note. Status text that isn't done makes the task `partial`.

## Merge-queue guarantees

- `merge` needs a passed gate on the branch tip, and when the gate said `review required`, an `approve` for that same tip.
- Only one task is in `merging` or `landing` at a time.
- `land` records each step (`land_step`: `committed`, `other_committed`, `other_pushed`). If a push fails, running `land` again continues from there; `merge` and `abort` refuse while a secondary-repo commit is already pushed.
