---
name: scope
description: Scope (plan) a build. Turn any brief (a client request, a feature idea, a messy chat dump, a bug report, a whole product) into a standardized, validated execution plan that coding agents (Claude Code, Codex, Cursor, etc.) can run task by task. The plan has phases, full-spec tasks with IDs, dependencies, acceptance criteria and verify commands, plus plain-language follow-up questions to send the client. Use this whenever the user asks to plan, break down, scope, spec out, or make a roadmap, plan or tasks for something that will be built in code, pastes requirements and wants to know what to build and in what order, or wants to update an existing plan with new answers, even if they don't say "plan" explicitly.
---

# Scope: plan a build for coding agents

You turn a brief into a plan file that coding agents execute. The reader is **another agent with a fresh context and no access to this conversation**. It will be told things like "do T2.3" or "continue the plan", and it finds its place by grepping IDs and headings. So the two things that matter most are:

1. **Consistency.** Every plan has the identical skeleton, field names, ID scheme and field order. That makes plans predictable to agents, greppable, and checkable by a script. The format is defined in `references/plan-format.md` and enforced by `scripts/validate_plan.py`. Don't improvise sections, rename headings or reorder fields, even when the job seems to call for it. Extra material goes under `###` subheadings inside an existing section.
2. **Clarity for agents.** Every task can be done from §1–§6 plus that one task alone. It is concrete (real paths, names and commands) and its acceptance criteria can be checked.

Briefs usually arrive incomplete. So you also produce follow-up questions. Client questions are in plain language, so the user can forward them as they are; team questions can be technical.

## Before you write anything

Read `references/plan-format.md` (the spec) and `references/example-plan.md` (a small plan that passes validation). Mirror the example's shape exactly.

## Workflow

### 1. Understand the brief and the context
- Read everything the user gave you.
- **Detect the stack; don't assume it.** If there's a repo, inspect `package.json`/lockfiles, workspace config (`turbo.json`, `pnpm-workspace.yaml`), the ORM and migration setup, the test runner, lint/format tools, `README`, `CLAUDE.md`/`AGENTS.md`, and the folder layout. Note what's *missing* too: no migrations config or no tests means the plan needs setup tasks. Use real paths and the repo's real script commands. Set `stack_source: detected`. If there's no repo and the brief doesn't say, propose defaults as `A<n>` assumptions and set `stack_source: assumed`.
- Pick the `type`: greenfield, feature, refactor, bugfix, integration, infra or spike. It drives the plan's size (step 4).

### 2. Find the gaps and sort them
Look for anything an agent would otherwise have to guess: users and roles, MVP vs later, volumes, workflows and edge cases, permissions, integrations and API access, hosting and compliance, languages, deadlines, the stack.

Turn each gap into one of:
- **`CQ<n>` client question:** business or domain decisions only the client can answer. Use plain language and no jargon, and offer options where you can ("Can an approved document still be edited? (a) no, it's locked (b) yes, it creates a new version"). Group them under topic headings.
- **`TQ<n>` team question:** technical choices for the user's team.
- **`A<n>` assumption:** your working default, so planning can continue. Link it to the question that would confirm it.

Then choose up to **10 top questions for the first client meeting**, ordered by how much of the plan they unblock. Real client meetings are short; a list of 30 equal-weight questions doesn't get answered.

### 3. Ask first, or plan now?
Default to **planning now**, with assumptions marked. A plan with labelled assumptions is far more useful than a pile of questions, and assumptions are cheap to correct. Ask the user in chat first (3–5 questions at most) only when you can't tell what is being built at all.

### 4. Size the plan to the job
Over-planning is a real failure: a 15-task plan for a config bug wastes agent runs and buries the actual fix.
- **bugfix / spike:** at most 2 phases and about 8 tasks. Typically reproduce/investigate → fix and verify. Fold "check A, check B, check C" into one investigation task with several steps, instead of one task per hypothesis.
- **feature:** usually 2–4 phases and 5–15 tasks.
- **greenfield / large:** write **only the MVP phases at `Detail level: full`**. Later phases (integrations, SaaS, nice-to-haves) are `Detail level: outline`: a short bullet list with no task IDs, to be expanded in a later plan version once their questions are answered. This keeps the plan accurate instead of speculative. Aim for about 15–30 full tasks.
- **Task size:** about one focused PR. It can be completed and verified on its own, touching a handful of files. If you write "and also…", split the task; if it's one line, merge it.

### 5. Write the plan
Save it to `docs/plans/<plan_id>.md` in the repo, following an existing plans folder if there is one. With no repo, write it in the working directory. Follow the spec exactly:
- Frontmatter with every key.
- All 11 numbered sections, in order, with exact headings. Write `N/A — reason` for one that doesn't apply.
- §1 Agent Instructions copied verbatim from the spec, with the project's real check command filled in.
- Every task's 10 fields in the spec's order.
- IDs: `P<n>`, `T<p>.<n>`, `D<n>`, `A<n>`, `CQ<n>`, `TQ<n>`, `R<n>`, `DW<n>`. Every ID you reference must be defined.
- One term per concept throughout. Put code, paths and env vars in backticks. No "as discussed". No secrets.

### 6. Validate, then fix until clean
Run:
```bash
python3 <skill-dir>/scripts/validate_plan.py docs/plans/<plan_id>.md
```
Fix every `ERROR` and re-run until it prints `OK`. Treat `WARN` lines seriously too. A size warning on a bugfix usually means the tasks should be merged. The validator exists so that every plan comes out in the same format, whichever run wrote it. Don't deliver a plan that fails it.

### 7. Deliver
In chat, keep it short:
- the plan's path (send the file if a file-delivery tool exists)
- one line on its shape (`type`, phases, tasks) and the 2–3 assumptions that matter most
- the **top client questions**, ready to copy-paste. The full list stays in §7.
- if the repo has a `CLAUDE.md`/`AGENTS.md`, suggest adding one line pointing agents to the plan file. Don't edit those files unless asked.

- how to run it: `/phase P0` (or `/phase all`). If the repo has no `.claude/phase.json` yet, offer to set one up with `plan.file` and `land.progress_file` both pointing at the plan (the `phase` skill's Setup section).

Don't restate the plan in chat.

### 8. Updating an existing plan
When the user brings client answers or changes, edit the existing file rather than writing a new one:
- Set the assumptions' Status to `confirmed` or `rejected`, and add new `D<n>` decisions.
- Move answered questions to the matching decision (keep the CQ IDs, append `— answered: …`).
- Expand `outline` phases into `full` tasks once their questions are answered.
- Never renumber or reuse an ID. Add new tasks with the next free number.
- Bump `version` and `updated`, add a Changelog line, and re-run the validator.
