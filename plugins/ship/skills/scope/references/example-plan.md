---
plan_id: fix-csv-export-timeout
title: Fix CSV export timeout on large reports
type: bugfix
status: draft
version: 1
created: 2026-11-16
updated: 2026-11-16
stack_source: detected
---

# Fix CSV export timeout on large reports

## 1. Agent Instructions
You are a coding agent executing this plan. Rules:
1. Before any task, read §2 Goal, §3 Context and §6 Decisions and Assumptions.
2. Pick the first task whose **Status** is `todo` and whose **Depends on** tasks are all `done`. Tasks with **Parallel: yes** may run at the same time as other ready tasks.
3. When you start a task, set its Status to `in-progress`. When every acceptance criterion passes and the Verify commands succeed, tick the criteria and set Status to `done`.
4. Only change the files listed in a task's **Files**, unless you have to touch others to make it work; list any extra files in your summary.
5. Do not expand scope. Record anything missing or wrong in §10 Discovered Work, as `DW<n>`.
6. If a task lists an unconfirmed assumption under **Blocked by**, and the choice would be costly to reverse, stop and ask the human.
7. Before marking any task done, run the project checks: `bun run lint && bun test`.
8. When `/phase` runs this plan, follow your brief instead of rules 2–3: the orchestrator picks tasks and sets **Status**, and you never edit this file.

## 2. Goal
Exporting a report with more than ~50k rows as CSV times out after 30 s and returns a 504. Make exports of up to 1M rows complete reliably by streaming the response, without changing the CSV format. Done means a 1M-row export succeeds in staging and existing export tests still pass.

## 3. Context
- **Users / roles:** internal analysts (role `analyst`)
- **Stack:** Bun 1.2 (detected), Hono 4 (detected), Drizzle + Postgres (detected), nginx in front (detected)
- **Repo layout:** API in `apps/api/src`, report queries in `apps/api/src/reports/`
- **Commands:** install `bun install` · dev `bun run dev` · test `bun test` · lint `bun run lint`
- **Conventions:** route handlers return `c.json` errors as `{ error: { code, message } }`; tests sit next to source as `*.test.ts`
- **External systems:** none

## 4. Scope
### In scope
- Streaming CSV generation for `GET /reports/:id/export.csv`
### Out of scope
- Excel export, async/background export jobs, changing CSV columns

## 5. Architecture
N/A — change is local to the export handler and its query.

## 6. Decisions and Assumptions
| ID | Statement | Status | Affects |
|----|-----------|--------|---------|
| D1 | Stream rows with a Postgres cursor and a `ReadableStream` response | decided | T1.1 |
| A1 | nginx `proxy_read_timeout` can be raised to 300 s | unconfirmed | T1.2 |

## 7. Open Questions
### Top questions for the first client meeting
1. CQ1 — tells us the real upper bound to test against.
### Client questions
#### Usage
1. **CQ1** What is the largest report someone needs to export today, roughly how many rows? — affects: T1.3
### Team questions
1. **TQ1** Who can change the nginx config in staging/production? — affects: A1, T1.2

## 8. Phases and Tasks

### P0 — Reproduce
**Goal:** Reproduce the timeout with a test that fails today.
**Exit criteria:** A failing test exists that demonstrates the timeout.
**Detail level:** full

#### T0.1 — Add a failing large-export test
- **Status:** todo
- **Depends on:** —
- **Parallel:** no
- **Blocked by:** —
- **Goal:** Capture the bug in a test so the fix can be proven.
- **Files:**
  - `apps/api/src/reports/export.test.ts` (create)
- **Steps:**
  1. Seed 200k rows into the test report using the existing `seedReport` helper.
  2. Call `GET /reports/:id/export.csv` and measure the time until the first byte arrives.
- **Acceptance criteria:**
  - [ ] The test fails on current `main`, with time-to-first-byte > 10 s
- **Verify:**
  ```bash
  bun test apps/api/src/reports/export.test.ts
  ```
- **Out of scope:** Fixing the handler.

### P1 — Fix and verify
**Goal:** Stream the export and confirm it in staging.
**Exit criteria:** T0.1 passes and a 1M-row export succeeds in staging.
**Detail level:** full

#### T1.1 — Stream CSV rows from a cursor
- **Status:** todo
- **Depends on:** T0.1
- **Parallel:** no
- **Blocked by:** —
- **Goal:** Send rows as they are read instead of building the whole file in memory.
- **Files:**
  - `apps/api/src/reports/export.ts` (modify)
- **Steps:**
  1. Replace `await db.select()` with a cursor that reads 5,000 rows per batch.
  2. Return `new Response(stream, { headers: { "Content-Type": "text/csv" } })`.
- **Acceptance criteria:**
  - [ ] T0.1 passes, with time-to-first-byte < 1 s
  - [ ] Existing export tests pass unchanged
- **Verify:**
  ```bash
  bun test apps/api/src/reports
  ```
- **Out of scope:** Changing column order or CSV escaping.

#### T1.2 — Raise the nginx read timeout for exports
- **Status:** todo
- **Depends on:** —
- **Parallel:** yes
- **Blocked by:** A1, TQ1
- **Goal:** Stop nginx from cutting off long streams.
- **Files:**
  - `infra/nginx/api.conf` (modify)
- **Steps:**
  1. Add a `location /reports/` block with `proxy_read_timeout 300s;` and `proxy_buffering off;`.
- **Acceptance criteria:**
  - [ ] `nginx -t` passes
  - [ ] Only `/reports/` routes get the longer timeout
- **Verify:**
  ```bash
  nginx -t -c infra/nginx/api.conf
  ```
- **Out of scope:** Other nginx tuning.

#### T1.3 — Verify a 1M-row export in staging
- **Status:** todo
- **Depends on:** T1.1, T1.2
- **Parallel:** no
- **Blocked by:** CQ1
- **Goal:** Prove the fix at real scale.
- **Files:**
  - `docs/plans/fix-csv-export-timeout.md` (modify)
- **Steps:**
  1. Deploy to staging and export the 1M-row fixture report.
  2. Record the duration and peak memory in §10.
- **Acceptance criteria:**
  - [ ] The export completes with HTTP 200 and the file has 1,000,001 lines
  - [ ] API peak memory stays under 512 MB
- **Verify:**
  ```bash
  curl -s -o /tmp/out.csv -w "%{http_code}\n" "$STAGING_URL/reports/$FIXTURE_ID/export.csv" && wc -l /tmp/out.csv
  ```
- **Out of scope:** Load testing with multiple concurrent exports.

## 9. Risks
| ID | Risk | Impact | Mitigation |
|----|------|--------|-----------|
| R1 | A long-held cursor blocks DB connections | medium | Use a dedicated connection with a 5 min statement timeout |

## 10. Discovered Work
None yet.

## 11. Changelog
- 2026-11-16 v1 — Initial plan from bug report.
