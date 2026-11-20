#!/usr/bin/env python3
"""Validate a plan file against plan-format v1 (see references/plan-format.md).

Usage: python3 validate_plan.py <plan.md> [--json]
Exit code 0 = no errors (warnings allowed), 1 = errors found.
"""
import json
import re
import sys

SECTIONS = [
    "1. Agent Instructions", "2. Goal", "3. Context", "4. Scope", "5. Architecture",
    "6. Decisions and Assumptions", "7. Open Questions", "8. Phases and Tasks",
    "9. Risks", "10. Discovered Work", "11. Changelog",
]
FRONT_KEYS = ["plan_id", "title", "type", "status", "version", "created", "updated", "stack_source"]
ENUMS = {
    "type": {"greenfield", "feature", "refactor", "bugfix", "integration", "infra", "spike"},
    "status": {"draft", "active", "done"},
    "stack_source": {"detected", "decided", "assumed"},
}
TASK_FIELDS = ["Status", "Depends on", "Parallel", "Blocked by", "Goal", "Files", "Steps",
               "Acceptance criteria", "Verify", "Out of scope"]
TASK_STATUS = {"todo", "in-progress", "done", "blocked"}
CONTEXT_KEYS = ["Users / roles", "Stack", "Repo layout", "Commands", "Conventions", "External systems"]
OQ_SUBS = ["Top questions for the first client meeting", "Client questions", "Team questions"]
SIZE_LIMITS = {"bugfix": (2, 8), "spike": (2, 6)}  # (max full phases, max tasks)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    path = sys.argv[1]
    text = open(path, encoding="utf-8").read()
    errors, warnings = [], []
    E, W = errors.append, warnings.append

    # Frontmatter
    fm = {}
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        E("missing YAML frontmatter at top of file")
    else:
        for line in m.group(1).splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                fm[k.strip()] = v.strip()
        for k in FRONT_KEYS:
            if k not in fm or not fm[k]:
                E(f"frontmatter: missing '{k}'")
        for k, allowed in ENUMS.items():
            if k in fm and fm[k] not in allowed:
                E(f"frontmatter: {k}='{fm[k]}' not in {sorted(allowed)}")
        if "plan_id" in fm and not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", fm["plan_id"]):
            E("frontmatter: plan_id must be kebab-case")

    # Sections in order
    h2 = re.findall(r"^## (.+?)\s*$", text, re.M)
    if h2 != SECTIONS:
        missing = [s for s in SECTIONS if s not in h2]
        extra = [s for s in h2 if s not in SECTIONS]
        if missing:
            E(f"missing sections: {missing}")
        if extra:
            E(f"unexpected top-level sections (use ### inside an existing one): {extra}")
        if not missing and not extra:
            E("sections are out of order")

    def section(name):
        mm = re.search(rf"^## {re.escape(name)}\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
        return mm.group(1) if mm else ""

    ctx = section("3. Context")
    for k in CONTEXT_KEYS:
        if f"**{k}:**" not in ctx:
            E(f"§3 Context: missing key '**{k}:**'")
    scope = section("4. Scope")
    for s in ["### In scope", "### Out of scope"]:
        if s not in scope:
            E(f"§4 Scope: missing '{s}'")
    oq = section("7. Open Questions")
    for s in OQ_SUBS:
        if f"### {s}" not in oq:
            E(f"§7 Open Questions: missing '### {s}'")
    top = re.search(r"### Top questions.*?(?=^### |\Z)", oq, re.M | re.S)
    if top and len(set(re.findall(r"\bCQ\d+\b", top.group(0)))) > 10:
        E("§7: top questions list has more than 10 entries")

    # Defined IDs
    defined = set()
    for pat in [r"^\|\s*((?:A|D|R)\d+)\s*\|", r"\*\*((?:CQ|TQ)\d+)\*\*", r"^\s*(?:\d+\.|-)\s*((?:CQ|TQ)\d+)\b"]:
        defined |= set(re.findall(pat, text, re.M))

    # Phases & tasks
    plan_sec = section("8. Phases and Tasks")
    phases = re.split(r"^(### P\d+ — .+)$", plan_sec, flags=re.M)
    task_ids, deps, n_full = [], {}, 0
    seen_ids = set()
    for i in range(1, len(phases), 2):
        head, body = phases[i], phases[i + 1]
        pnum = re.match(r"### P(\d+)", head).group(1)
        for k in ["**Goal:**", "**Exit criteria:**", "**Detail level:**"]:
            if k not in body:
                E(f"{head.strip()}: missing {k}")
        lvl = re.search(r"\*\*Detail level:\*\*\s*(\w+)", body)
        lvl = lvl.group(1) if lvl else "?"
        if lvl not in {"full", "outline"}:
            E(f"{head.strip()}: Detail level must be 'full' or 'outline'")
        tasks = re.split(r"^(#### T\d+\.\d+ — .+)$", body, flags=re.M)
        if lvl == "full":
            n_full += 1
            if len(tasks) < 3:
                E(f"{head.strip()}: full phase has no tasks")
        if lvl == "outline" and len(tasks) > 1:
            W(f"{head.strip()}: outline phase contains full task blocks")
        for j in range(1, len(tasks), 2):
            th, tb = tasks[j], tasks[j + 1]
            tid = re.match(r"#### (T(\d+)\.\d+)", th)
            tid_s = tid.group(1)
            if tid.group(2) != pnum:
                E(f"{tid_s}: ID prefix does not match phase P{pnum}")
            if tid_s in seen_ids:
                E(f"{tid_s}: duplicate task ID")
            seen_ids.add(tid_s)
            task_ids.append(tid_s)
            found = re.findall(r"^- \*\*(.+?):\*\*", tb, re.M)
            if found != TASK_FIELDS:
                miss = [f for f in TASK_FIELDS if f not in found]
                if miss:
                    E(f"{tid_s}: missing fields {miss}")
                else:
                    E(f"{tid_s}: fields out of order (expected {TASK_FIELDS})")
            st = re.search(r"^- \*\*Status:\*\*\s*(\S+)", tb, re.M)
            if st and st.group(1) not in TASK_STATUS:
                E(f"{tid_s}: Status '{st.group(1)}' invalid")
            par = re.search(r"^- \*\*Parallel:\*\*\s*(\S+)", tb, re.M)
            if par and par.group(1) not in {"yes", "no"}:
                E(f"{tid_s}: Parallel must be yes/no")
            dep = re.search(r"^- \*\*Depends on:\*\*\s*(.*)$", tb, re.M)
            deps[tid_s] = re.findall(r"T\d+\.\d+", dep.group(1)) if dep else []
            blk = re.search(r"^- \*\*Blocked by:\*\*\s*(.*)$", tb, re.M)
            if blk:
                for ref in re.findall(r"\b(?:A|CQ|TQ)\d+\b", blk.group(1)):
                    if ref not in defined:
                        E(f"{tid_s}: Blocked by references undefined {ref}")
            ac = re.search(r"\*\*Acceptance criteria:\*\*(.*?)(?=^- \*\*)", tb, re.M | re.S)
            if ac and not re.search(r"- \[[ x]\]", ac.group(1)):
                E(f"{tid_s}: acceptance criteria must be checkboxes")
            if ac:
                for vague in ["works well", "works correctly", "is clean", "as expected"]:
                    if vague in ac.group(1).lower():
                        W(f"{tid_s}: vague acceptance criterion ('{vague}')")
            vf = re.search(r"\*\*Verify:\*\*(.*?)(?=^- \*\*)", tb, re.M | re.S)
            if vf and "```" not in vf.group(1):
                E(f"{tid_s}: Verify must contain a fenced code block")
            fl = re.search(r"\*\*Files:\*\*(.*?)(?=^- \*\*)", tb, re.M | re.S)
            if fl and not re.search(r"`[^`]+`\s*\((create|modify|delete)\)", fl.group(1)):
                E(f"{tid_s}: Files entries need `path` (create|modify|delete)")
            if re.search(r"as discussed|as mentioned (above|earlier)|see chat", tb, re.I):
                W(f"{tid_s}: refers to outside context")

    if not task_ids:
        E("no tasks found (expected '#### T<p>.<n> — Title' under '### P<n> — Name')")
    for t, ds in deps.items():
        for d in ds:
            if d not in seen_ids:
                E(f"{t}: depends on unknown task {d}")
            if d == t:
                E(f"{t}: depends on itself")

    # cycle check
    state = {}

    def visit(n, stack):
        if state.get(n) == 1:
            E(f"dependency cycle: {' -> '.join(stack + [n])}")
            return
        if state.get(n) == 2:
            return
        state[n] = 1
        for d in deps.get(n, []):
            if d in deps:
                visit(d, stack + [n])
        state[n] = 2

    for n in deps:
        visit(n, [])

    # size guidance
    lim = SIZE_LIMITS.get(fm.get("type"))
    if lim:
        if n_full > lim[0]:
            W(f"type={fm['type']}: {n_full} full phases (guide: <= {lim[0]})")
        if len(task_ids) > lim[1]:
            W(f"type={fm['type']}: {len(task_ids)} tasks (guide: <= {lim[1]})")

    # undefined refs anywhere
    for ref in sorted(set(re.findall(r"\b(?:A|CQ|TQ)\d+\b", text)) - defined):
        W(f"ID {ref} is referenced but never defined")

    res = {"file": path, "ok": not errors, "tasks": len(task_ids), "full_phases": n_full,
           "errors": errors, "warnings": warnings}
    if "--json" in sys.argv:
        print(json.dumps(res, indent=2))
    else:
        print(f"{'OK' if not errors else 'FAIL'}: {path} — {len(task_ids)} tasks, {n_full} full phases")
        for e in errors:
            print(f"  ERROR: {e}")
        for w in warnings:
            print(f"  WARN:  {w}")
    sys.exit(0 if not errors else 1)


if __name__ == "__main__":
    main()
