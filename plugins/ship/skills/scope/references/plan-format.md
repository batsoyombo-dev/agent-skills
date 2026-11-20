# Plan format spec (plan-format v1)

Every plan this skill writes uses this exact format. Coding agents are told "do T2.3" or "continue the plan", and they find their place by grepping IDs and headings. They only work reliably if every plan has the same skeleton. `scripts/validate_plan.py` checks this spec. Run it before delivering.

## Why the format is strict
- **Stable, greppable IDs:** an agent can `grep "#### T2.3"` and land on exactly one task.
- **Fixed field order:** an agent (or a script) can parse status and dependencies without guessing.
- **Self-contained tasks:** an agent with a fresh context reads §1–§6 and one task, and has everything it needs.
- **Machine-checkable:** IDs that a task references must exist, and there must be no dependency cycles. A broken reference sends an agent off course.

## File location and name
- `docs/plans/<plan_id>.md` in the repo. If the repo already has a plans folder (`plans/`, `.plans/`, `docs/specs/`), use that instead.
- `plan_id` is kebab-case, short and stable (`auth-email-password`, `dms-mvp`, `fix-random-logouts`).
- One plan per file. If a later stage of a big project needs its own detailed plan, make it a separate file (`dms-phase-2-workflows.md`) and link to it.

## Skeleton (headings exact, in this order, all present)

````markdown
---
plan_id: <kebab-case>
title: <Human title>
type: greenfield | feature | refactor | bugfix | integration | infra | spike
status: draft | active | done
version: 1
created: YYYY-MM-DD
updated: YYYY-MM-DD
stack_source: detected | decided | assumed
---

# <Title>

## 1. Agent Instructions
## 2. Goal
## 3. Context
## 4. Scope
## 5. Architecture
## 6. Decisions and Assumptions
## 7. Open Questions
## 8. Phases and Tasks
## 9. Risks
## 10. Discovered Work
## 11. Changelog
````

If a section has nothing to say, keep the heading and write `N/A — <one-line reason>`. For example, `## 5. Architecture` for a bug fix can be `N/A — fix stays within existing auth config`. Never delete or rename a heading, and never add new numbered top-level sections. Extra material goes under `###` subheadings inside the closest section (e.g. a findings log goes under §10 Discovered Work).

## Section contents

### 1. Agent Instructions
Copy this block verbatim. Only change the verify command line.

```markdown
You are a coding agent executing this plan. Rules:
1. Before any task, read §2 Goal, §3 Context and §6 Decisions and Assumptions.
2. Pick the first task whose **Status** is `todo` and whose **Depends on** tasks are all `done`. Tasks with **Parallel: yes** may run at the same time as other ready tasks.
3. When you start a task, set its Status to `in-progress`. When every acceptance criterion passes and the Verify commands succeed, tick the criteria and set Status to `done`.
4. Only change the files listed in a task's **Files**, unless you have to touch others to make it work; list any extra files in your summary.
5. Do not expand scope. Record anything missing or wrong in §10 Discovered Work, as `DW<n>`.
6. If a task lists an unconfirmed assumption under **Blocked by**, and the choice would be costly to reverse, stop and ask the human.
7. Before marking any task done, run the project checks: `<lint/typecheck/test command>`.
8. When `/phase` runs this plan, follow your brief instead of rules 2–3: the orchestrator picks tasks and sets **Status**, and you never edit this file.
```

### 2. Goal
2–5 sentences: what is being built, for whom, why, and what "done" means for the whole plan.

### 3. Context
A bullet list, always these keys in this order. Write `unknown (see TQn)` instead of leaving a key out.
- **Users / roles:**
- **Stack:** with `(detected)`, `(decided)` or `(assumed — A<n>)` after each item
- **Repo layout:** key folders, and where new code goes
- **Commands:** install / dev / test / lint / typecheck / build / migrate, as exact commands in backticks
- **Conventions:** patterns to follow (error format, validation, naming, test location)
- **External systems:**

### 4. Scope
Two subsections: `### In scope` and `### Out of scope`, as bullet lists. Out of scope stops agents from gold-plating, so it's required.

### 5. Architecture
Components, data model (entities and key fields), and main flows. Keep only what agents need in order to stay consistent across tasks.

### 6. Decisions and Assumptions
One table:

| ID | Statement | Status | Affects |
|----|-----------|--------|---------|
| D1 | Use existing Drizzle + Postgres in `packages/db` | decided | all |
| A1 | Max upload size 50 MB | unconfirmed | T2.1, T2.4 |

- IDs: `D<n>` for decisions (status is always `decided`). `A<n>` for assumptions (status is `unconfirmed`, `confirmed` or `rejected`).
- When the client confirms an assumption, change its Status. Don't renumber.

### 7. Open Questions
Exactly these three subsections:
- `### Top questions for the first client meeting`: at most 10, ordered by impact, each a reference like `CQ4` with one line on why it matters.
- `### Client questions`: `CQ<n>`, grouped under `####` topic headings. Use plain language and no jargon; offer options where possible. End each with `— affects: A3, T4.2` (or `— affects: scope`).
- `### Team questions`: `TQ<n>`, which can be technical, ending with `— affects: ...`.

### 8. Phases and Tasks

Phase heading: `### P<n> — <Name>`, numbered from 0. Directly under it:

```markdown
**Goal:** <one sentence>
**Exit criteria:** <what runs / is verifiable when the phase is complete>
**Detail level:** full | outline
```

`full` phases contain tasks in the format below. `outline` phases (later phases that are waiting on client answers, or big products beyond the MVP) contain only a bullet list of intended tasks, with no IDs. They get expanded into full tasks in a later plan version, once their questions are answered.

Task block (heading level 4; fields in this exact order; all fields present; `—` when empty):

````markdown
#### T<phase>.<n> — <Imperative title>
- **Status:** todo
- **Depends on:** T1.1, T1.2
- **Parallel:** yes
- **Blocked by:** A3
- **Goal:** <1–2 sentences: what and why>
- **Files:**
  - `apps/api/src/routes/auth.ts` (create)
  - `packages/db/src/schema.ts` (modify)
- **Steps:**
  1. <concrete step>
  2. <concrete step>
- **Acceptance criteria:**
  - [ ] <observable, checkable statement>
  - [ ] <observable, checkable statement>
- **Verify:**
  ```bash
  bun test apps/api/src/routes/auth.test.ts
  ```
- **Out of scope:** <what not to do in this task>
````

Field rules:
- **Status:** one of `todo`, `in-progress`, `done`, `blocked`.
- **Depends on:** task IDs, or `—`. They must exist, and there must be no cycles.
- **Parallel:** `yes` or `no`. Use `yes` when the task can run at the same time as the other tasks in its phase whose dependencies are met.
- **Blocked by:** `A<n>`, `CQ<n>` or `TQ<n>` IDs whose answer could change this task, or `—`.
- **Files:** backticked paths, each with `(create)`, `(modify)` or `(delete)`. When the repo is unknown, use the paths you intend and set `stack_source: assumed`.
- **Steps:** a numbered list, concrete. Name functions, endpoints, tables and env vars.
- **Acceptance criteria:** checkboxes. Each one is observable (behaviour, response code, test name, command output), never "works well" or "is clean".
- **Verify:** a fenced `bash` block of runnable commands. For manual checks, add a `# manual:` comment line explaining what to look at.
- **Out of scope:** one line.

Task numbering: `T<phase>.<n>` starting at 1 within each phase (T0.1, T0.2, T1.1 …). Don't reuse an ID. When tasks are added later, append new numbers rather than renumbering.

### 9. Risks
Table: `| ID | Risk | Impact | Mitigation |` with `R<n>` IDs.

### 10. Discovered Work
Starts as `None yet.` Agents append `- DW<n> (found in T2.3): <description>`.

### 11. Changelog
`- YYYY-MM-DD v<version> — <what changed>`. Bump `version` and `updated` in the frontmatter whenever you add a line.

## Writing style for agents
- Use imperative, specific, unambiguous language. "Add a `refresh_tokens` table with columns …", not "Handle refresh tokens".
- Use one term per concept, everywhere. If §5 calls it a `Workflow`, no task calls it a "pipeline" or "flow". Define domain terms in §5 if they're ambiguous.
- Don't refer back to chat or earlier context ("as discussed"). The plan is the only source of truth.
- Put code identifiers, paths, env vars and commands in backticks.
- Never write secrets or credentials in the plan. Refer to them by env var name.
