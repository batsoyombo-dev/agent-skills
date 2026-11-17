#!/usr/bin/env python3
"""phase: run plan tasks in parallel git worktrees, gate them, land them through a serial merge queue.

Project-agnostic. Everything project-specific comes from <repo>/.claude/phase.json (see reference.md).
Python 3.8+, standard library only. Run `phase.py help`.
Source: github.com/batsoyombo-dev/agent-skills (plugins/phase).
"""

import base64
import datetime
import fnmatch
import glob
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

SKILL_DIR = os.path.dirname(os.path.abspath(__file__))
REPORT = ".phase-report.md"
INTEGRATION = "_integration"
ACTIVE = ("running", "review", "merging")

DEFAULTS = {
    "project": "",
    "base": "staging",
    "remote": "origin",
    "vars": {},
    "agents": {"max": 5},
    "plan": {
        "file": "",
        "columns": {
            "id": ["id"],
            "task": ["task", "title"],
            "deps": ["depends on", "deps", "dependencies"],
            "status": ["status"],
            "owner": ["owner"],
            "spec": ["spec"],
            "done_when": ["done when", "acceptance"],
            "parallel": ["parallel"],
        },
        "done": r"^done\b",
        "agent_owners": ["agent", ""],
        "manual_markers": ["`you`"],
        "manual_phases": r"no subagents|^ops\b",
        "serial_values": ["no"],
        "cap": r"max (\d+) agents?",
    },
    "slots": {"port_base": 8100, "avoid": None},
    "worktree": {
        "dir": ".worktrees",
        "env_file": "",
        "env_fallback": "",
        "env": {},
        "copy": [],
        "clone": [],
        "link": [],
        "exclude": [],
        "setup": [],
        "refresh": [],
        "teardown": [],
    },
    "gate": {
        "tests": [],
        "conditional": [],
        "per_file": [],
        "forbid": [
            ".env", "*/.env", ".env.*", "*/.env.*", "*.pem", "*.p12", "*.p8", "*.jks", "*.keystore",
            "*key.properties", "*id_rsa*", "node_modules/*", ".worktrees/*", REPORT,
        ],
        "forbid_allow": [".env.example", "*/.env.example", ".env.*.example"],
        "owned": [],
        "immutable": [],
        "rules": [],
        "secret_exclude": [],
        "review": {"lines": 400, "triggers": []},
    },
    "land": {
        "progress_file": "",
        "require_progress": True,
        "allow_after_merge": ["docs/*"],
        "ssh_push_when": [".github/workflows/*"],
    },
    "deploy": None,
    "smoke": None,
    "brief": {"spec": "{spec}", "done_when": "{done_when}", "read": [], "rules": [], "extra": []},
    "review": {"checklist": []},
    "doctor": {"require": [], "checks": []},
    "repos": {},
}

SECRETS = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}|sk_live_[0-9a-zA-Z]{10,}"
    r"|xox[bpas]-[0-9A-Za-z\-]{10,}|ghp_[0-9A-Za-z]{36}|github_pat_[0-9A-Za-z_]{40,}"
)


# ---------------------------------------------------------------- helpers

class Fail(Exception):
    pass


def die(msg):
    raise Fail(msg)


def info(msg):
    print("phase: " + msg, file=sys.stderr)


def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M")


def run(cmd, cwd=None, check=True, env=None, shell=False):
    """Run a command, return CompletedProcess with text stdout/stderr."""
    p = subprocess.run(
        cmd, cwd=cwd, shell=shell, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        executable="/bin/bash" if shell else None,
    )
    if check and p.returncode != 0:
        shown = cmd if isinstance(cmd, str) else " ".join(shlex.quote(c) for c in cmd)
        die("command failed (%d): %s\n%s" % (p.returncode, shown, (p.stderr or p.stdout).strip()[-2000:]))
    return p


def git(repo, *args, check=True):
    return run(["git", "-C", repo] + list(args), check=check).stdout.strip()


def git_ok(repo, *args):
    return run(["git", "-C", repo] + list(args), check=False).returncode == 0


def norm_id(task):
    return re.sub(r"[^a-z0-9]", "_", task.lower())


def deep_merge(a, b):
    if not isinstance(a, dict) or not isinstance(b, dict):
        return b
    out = dict(a)
    for k, v in b.items():
        out[k] = deep_merge(a[k], v) if k in a and isinstance(a[k], dict) and isinstance(v, dict) else v
    return out


def glob_any(path, globs):
    return any(fnmatch.fnmatch(path, g) for g in globs or [])


def read_env_file(path):
    out = {}
    if path and os.path.isfile(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
            if m:
                v = m.group(2)
                if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                    v = v[1:-1]
                out[m.group(1)] = v
    return out


def set_env(path, key, value):
    lines = open(path, encoding="utf-8").read().splitlines() if os.path.exists(path) else []
    done = False
    for i, line in enumerate(lines):
        if re.match(r"^\s*%s\s*=" % re.escape(key), line):
            lines[i] = "%s=%s" % (key, value)
            done = True
    if not done:
        lines.append("%s=%s" % (key, value))
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------- project

class Project:
    def __init__(self, path=None):
        start = path or os.environ.get("PHASE_PROJECT") or os.getcwd()
        if not os.path.isdir(start):
            die("no such directory: %s" % start)
        common = run(["git", "-C", start, "rev-parse", "--path-format=absolute", "--git-common-dir"], check=False)
        if common.returncode != 0:
            die("%s is not inside a git repository" % start)
        self.main = os.path.dirname(common.stdout.strip())
        self.config_path = os.path.join(self.main, ".claude", "phase.json")
        if not os.path.isfile(self.config_path):
            die("no %s. Create one: phase.py init > .claude/phase.json, then edit it (see %s/reference.md)"
                % (self.config_path, SKILL_DIR))
        try:
            raw = json.load(open(self.config_path, encoding="utf-8"))
        except ValueError as e:
            die("invalid JSON in %s: %s" % (self.config_path, e))
        self.raw = raw
        self.cfg = deep_merge(DEFAULTS, raw)
        if not self.cfg["plan"]["file"]:
            die("plan.file is required in %s" % self.config_path)
        self.state_dir = os.path.join(self.main, self.cfg["worktree"]["dir"], ".phase")
        self.base = self.cfg["base"]
        self.remote = self.cfg["remote"]
        repos = self.cfg["repos"] or {"main": {"path": "."}}
        self.primary = next((n for n, r in repos.items() if r.get("primary")), next(iter(repos)))
        self.repos = repos
        self.script = "%s --project %s" % (shlex.quote(os.path.abspath(__file__)), shlex.quote(self.main))

    # -- config per repo
    def rcfg(self, repo, section):
        base = self.cfg.get(section)
        over = self.repos.get(repo, {}).get(section)
        if over is None:
            return base
        if base is None:
            return over
        return deep_merge(base, over)

    def repo_root(self, repo):
        r = self.repos.get(repo)
        if r is None:
            die("unknown repo '%s' (configured: %s)" % (repo, ", ".join(self.repos)))
        p = os.environ.get(r["env"]) if r.get("env") else None
        p = p or r.get("path", ".")
        root = os.path.abspath(os.path.join(self.main, os.path.expanduser(p)))
        if not os.path.exists(os.path.join(root, ".git")):
            hint = (" Clone it: git clone %s %s" % (r["clone"], root)) if r.get("clone") else ""
            die("repo '%s' not found at %s%s%s" % (repo, root, (" (or set %s)" % r["env"]) if r.get("env") else "", hint))
        return root

    def base_ref(self):
        return "%s/%s" % (self.remote, self.base) if self.remote else self.base

    def vars(self):
        v = {}
        for k, val in self.cfg["vars"].items():
            v[k] = os.environ.get("PHASE_VAR_" + k.upper(), val)
        return v

    def fmt(self, s, ctx):
        def rep(m):
            key = m.group(1)
            if key.startswith("main_env:"):
                env_file = self.rcfg(ctx.get("repo", self.primary), "worktree")["env_file"]
                return read_env_file(os.path.join(ctx.get("main", self.main), env_file)).get(key[9:], "")
            return str(ctx[key]) if key in ctx else m.group(0)
        return re.sub(r"\{([A-Za-z_][A-Za-z0-9_]*(?::[A-Za-z0-9_]+)?)\}", rep, s)

    # -- state
    def sfile(self, task):
        return os.path.join(self.state_dir, norm_id(task) + ".json")

    def state(self, task):
        f = self.sfile(task)
        return json.load(open(f)) if os.path.isfile(f) else {}

    def save(self, _task, **kv):
        os.makedirs(self.state_dir, exist_ok=True)
        st = self.state(_task)
        st.setdefault("task", _task)
        st.update(kv)
        st["updated"] = now()
        tmp = self.sfile(_task) + ".tmp"
        json.dump(st, open(tmp, "w"), indent=1, sort_keys=True)
        os.replace(tmp, self.sfile(_task))
        return st

    def states(self):
        if not os.path.isdir(self.state_dir):
            return []
        out = []
        for name in sorted(os.listdir(self.state_dir)):
            if name.endswith(".json"):
                out.append(json.load(open(os.path.join(self.state_dir, name))))
        return out

    def task_repo(self, task):
        return self.state(task).get("repo") or self.primary

    def wt(self, task, repo=None):
        repo = repo or self.task_repo(task)
        return os.path.join(self.repo_root(repo), self.rcfg(repo, "worktree")["dir"], norm_id(task))

    def int_wt(self, repo):
        return os.path.join(self.repo_root(repo), self.rcfg(repo, "worktree")["dir"], INTEGRATION)

    def ctx(self, task, repo=None):
        st = self.state(task)
        repo = repo or st.get("repo") or self.primary
        c = dict(self.vars())
        c.update({
            "ID": task, "id": norm_id(task), "repo": repo, "main": self.repo_root(repo), "base": self.base,
            "wt": st.get("worktree") or self.wt(task, repo), "port": st.get("port", ""), "slot": st.get("slot", ""),
            "date": st.get("date", datetime.date.today().strftime("%Y_%m_%d")), "phase": self.script,
        })
        for k, v in (self.cfg.get("slots", {}).get("vars") or {}).items():
            c[k] = self.fmt(v, c)
        return c

    def fetch(self, root):
        if not self.remote:
            return
        p = run(["git", "-C", root, "fetch", "-q", self.remote,
                 "+refs/heads/%s:refs/remotes/%s/%s" % (self.base, self.remote, self.base)], check=False)
        if p.returncode != 0:
            info("fetch failed in %s; using the last known %s" % (root, self.base_ref()))

    def plan_text(self):
        root = self.repo_root(self.primary)
        self.fetch(root)
        p = run(["git", "-C", root, "show", "%s:%s" % (self.base_ref(), self.cfg["plan"]["file"])], check=False)
        if p.returncode == 0:
            return p.stdout
        local = os.path.join(root, self.cfg["plan"]["file"])
        if os.path.isfile(local):
            info("%s not on %s; reading the local copy" % (self.cfg["plan"]["file"], self.base_ref()))
            return open(local, encoding="utf-8").read()
        die("plan file %s not found on %s or locally" % (self.cfg["plan"]["file"], self.base_ref()))


# ---------------------------------------------------------------- plan parsing

HEADING = re.compile(r"^(?:\*\*(?P<b>[^*]+)\*\*(?P<brest>.*)|#{2,4}\s+(?P<h>.+))$")


def split_row(line):
    cells = line.strip().strip("|").split("|")
    return [c.strip() for c in cells]


def parse_plan(text, pcfg, repos, primary):
    """Markdown tables under bold or ## headings. Returns a list of task dicts."""
    tasks, phase, header = [], None, None
    want = {k: [a.lower() for a in v] for k, v in pcfg["columns"].items()}

    for line in text.splitlines():
        s = line.strip()
        h = HEADING.match(s)
        if h and not s.startswith("|"):
            title = (h.group("b") or h.group("h") or "").strip()
            rest = h.group("brest") or ""
            m = re.match(r"^([A-Za-z][A-Za-z0-9.]*)\s*:\s*(.*)$", title)
            pid = m.group(1) if m else title.split()[0] if title else "?"
            cap = re.search(pcfg["cap"], rest + " " + title, re.I) if pcfg.get("cap") else None
            phase = {
                "id": pid, "name": title, "repo": None,
                "manual": bool(re.search(pcfg["manual_phases"], (title + " " + rest).lower())) if pcfg.get("manual_phases") else False,
                "cap": int(cap.group(1)) if cap else None,
            }
            for name, r in repos.items():
                for marker in r.get("markers", []):
                    if marker and marker in rest:
                        phase["repo"] = name
            header = None
            continue
        if not s.startswith("|"):
            header = None  # any non-table line ends the table
            continue
        cells = split_row(s)
        if all(re.fullmatch(r":?-{2,}:?", c) for c in cells if c):
            continue
        lower = [c.lower() for c in cells]
        if header is None and any(c in want["id"] for c in lower):
            header = {}
            for key, aliases in want.items():
                for i, c in enumerate(lower):
                    if c in aliases:
                        header[key] = i
                        break
            continue
        if header is None or "id" not in header:
            continue
        get = lambda k: cells[header[k]] if k in header and header[k] < len(cells) else ""  # noqa: E731
        tid = get("id").strip("`* ")
        if not tid or not re.match(r"^[A-Za-z][A-Za-z0-9.]*$", tid):
            continue
        row = {k: get(k) for k in want}
        row["id"] = tid
        row["phase"] = phase or {"id": "-", "name": "-", "repo": None, "manual": False, "cap": None}
        repo = row["phase"]["repo"] or primary
        for name, r in repos.items():
            for marker in r.get("row_markers", []):
                if re.search(marker, row["task"] + " " + row["done_when"]):
                    repo = name
        row["repo"] = repo
        tasks.append(row)
    return tasks


RANGE = re.compile(r"^(?P<p1>.*?)(?P<n1>\d+)(?P<s1>[a-z]?)\s*[–—-]\s*(?P<p2>.*?)(?P<n2>\d+)(?P<s2>[a-z]?)$")


def expand_deps(deps):
    ids, gates = [], []
    if deps.strip() in ("", "—", "-", "–", "none", "n/a"):
        return ids, gates
    for tok in re.split(r"[,;+]| and ", deps):
        tok = tok.strip().strip("`*").strip()
        if not tok:
            continue
        m = RANGE.match(tok)
        if m and (m.group("p2") in ("", m.group("p1"))) and re.match(r"^[A-Za-z]", m.group("p1") or "x"):
            p, n1, n2, s1, s2 = m.group("p1"), int(m.group("n1")), int(m.group("n2")), m.group("s1"), m.group("s2")
            if s1 and s2 and n1 == n2:
                ids += ["%s%d%s" % (p, n1, chr(c)) for c in range(ord(s1), ord(s2) + 1)]
                continue
            if not s1 and not s2 and n2 >= n1 and n2 - n1 < 50:
                ids += ["%s%d" % (p, n) for n in range(n1, n2 + 1)]
                continue
        if re.fullmatch(r"[A-Za-z][A-Za-z0-9.]*\d[A-Za-z0-9.]*", tok):
            ids.append(tok)
        else:
            gates.append(tok)
    return ids, gates


def classify(t, by_id, pcfg, proj):
    done = re.compile(pcfg["done"], re.I)
    if done.search(t["status"]):
        return "done", t["status"]
    st = proj.state(t["id"]).get("status", "")
    if st in ACTIVE:
        return st, "in progress (phase.py status)"
    if st == "merged":
        return "merged", "landed; plan should say done"
    if t["status"]:
        return "partial", t["status"]
    if t["phase"]["manual"]:
        return "manual", "phase %s is not for subagents" % t["phase"]["id"]
    owner = (t.get("owner") or "").strip().strip("`").lower()
    if not any(owner == a.lower() or (a and owner.startswith(a.lower())) for a in pcfg["agent_owners"]):
        return "manual", "owner " + t["owner"]
    for marker in pcfg["manual_markers"]:
        if marker and marker in t["task"]:
            return "manual", "marked %s" % marker
    ids, gates = expand_deps(t["deps"])
    unknown = [i for i in ids if i not in by_id]
    if unknown:
        return "manual", "unknown dependency " + ",".join(unknown)
    waiting = [i for i in ids if not done.search(by_id[i]["status"])]
    if waiting:
        return "blocked", "waits on " + ",".join(waiting)
    if gates:
        return "manual", "gated on: " + ", ".join(gates)
    return "ready", "deps done" if ids else "no deps"


def load_plan(proj):
    tasks = parse_plan(proj.plan_text(), proj.cfg["plan"], proj.repos, proj.primary)
    if not tasks:
        die("no task rows found in %s (check plan.columns in phase.json)" % proj.cfg["plan"]["file"])
    return tasks, {t["id"]: t for t in tasks}


# ---------------------------------------------------------------- worktrees

def ensure_excludes(proj, root, repo):
    common = git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    ex = os.path.join(common, "info", "exclude")
    os.makedirs(os.path.dirname(ex), exist_ok=True)
    have = open(ex).read().splitlines() if os.path.exists(ex) else []
    wcfg = proj.rcfg(repo, "worktree")
    need = [wcfg["dir"].rstrip("/") + "/", REPORT] + list(wcfg["exclude"])
    add = [p for p in need if p not in have]
    if add:
        with open(ex, "a") as f:
            f.write("\n".join(add) + "\n")


def alloc_slot(proj):
    used = set()
    for st in proj.states():
        if st.get("status") not in ("merged", "removed") and st.get("slot"):
            used.add(int(st["slot"]))
    avoid = proj.cfg["slots"].get("avoid")
    if avoid:
        today = datetime.date.today().strftime("%Y_%m_%d")
        root = proj.repo_root(avoid.get("repo", proj.primary))
        names = git(root, "ls-tree", "--name-only", proj.base_ref(), avoid["path"].rstrip("/") + "/", check=False)
        rx = re.compile(proj.fmt(avoid["regex"], {"date": today}))
        for n in names.splitlines():
            m = rx.search(os.path.basename(n))
            if m:
                used.add(int(m.group(1)))
    hi = max(used) if used else 9
    if 10 <= hi + 1 <= 99:
        return hi + 1
    for n in range(10, 100):
        if n not in used:
            return n
    die("no free slot 10-99")


def hook_env(proj, c, action):
    env = dict(os.environ)
    env.update({"PHASE_ID": c["id"], "PHASE_TASK": c["ID"], "PHASE_WT": c["wt"], "PHASE_MAIN": c["main"],
                "PHASE_PORT": str(c["port"]), "PHASE_SLOT": str(c["slot"]), "PHASE_REPO": c["repo"],
                "PHASE_ACTION": action, "PHASE_BASE": proj.base_ref()})
    return env


def run_hooks(proj, c, cmds, action, cwd):
    for cmd in cmds:
        shown = proj.fmt(cmd, c)
        p = run(shown, cwd=cwd, shell=True, check=False, env=hook_env(proj, c, action))
        if p.returncode != 0:
            die("%s hook failed in %s:\n  %s\n%s" % (action, cwd, shown, (p.stderr or p.stdout).strip()[-3000:]))


def clone_dir(src, dst):
    if os.path.exists(dst) or not os.path.exists(src):
        return
    if sys.platform == "darwin" and run(["cp", "-c", "-R", src, dst], check=False).returncode == 0:
        return
    run(["cp", "-R", src, dst])


def prepare_wt(proj, repo, wt, c, action):
    """Copy/clone/link, env file with overrides, setup hooks. Idempotent."""
    w = proj.rcfg(repo, "worktree")
    main = proj.repo_root(repo)
    for rel in w["clone"]:
        clone_dir(os.path.join(main, rel), os.path.join(wt, rel))
    for pattern in w["copy"]:
        for src in sorted(glob.glob(os.path.join(main, pattern))):
            dst = os.path.join(wt, os.path.relpath(src, main))
            if not os.path.exists(dst):
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                shutil.copy2(src, dst)
    for rel in w["link"]:
        src, dst = os.path.join(main, rel), os.path.join(wt, rel)
        if os.path.exists(src) and not os.path.lexists(dst):
            os.symlink(src, dst)
    if w["env_file"]:
        env_path = os.path.join(wt, w["env_file"])
        if not os.path.exists(env_path):
            src = os.path.join(main, w["env_file"])
            if not os.path.exists(src) and w["env_fallback"]:
                src = os.path.join(main, w["env_fallback"])
            if os.path.exists(src):
                shutil.copy2(src, env_path)
            else:
                info("WARN: no %s in %s (and no env_fallback)" % (w["env_file"], main))
        if os.path.exists(env_path):
            for k, v in w["env"].items():
                set_env(env_path, k, proj.fmt(v, c))
    run_hooks(proj, c, w["setup"], action, wt)


def ensure_int(proj, repo):
    root = proj.repo_root(repo)
    wt = proj.int_wt(repo)
    ensure_excludes(proj, root, repo)
    proj.fetch(root)
    git(root, "worktree", "prune")
    if not os.path.isdir(wt):
        git(root, "worktree", "add", "-q", "--detach", wt, proj.base_ref())
    if git(wt, "status", "--porcelain"):
        die("integration worktree %s has changes (a merge in progress?). Finish it with land, or: %s abort"
            % (wt, proj.script))
    git(wt, "checkout", "-q", "--detach", proj.base_ref())
    c = proj.ctx(INTEGRATION, repo)
    c.update({"wt": wt, "id": "integration", "ID": "integration", "port": proj.cfg["slots"]["port_base"] - 1})
    prepare_wt(proj, repo, wt, c, "integration")
    return wt


# ---------------------------------------------------------------- gate pieces

def changed(wt, base, status_filter=None):
    args = ["diff", "--name-status", "--no-renames", base, "HEAD"]
    out = []
    for line in git(wt, *args).splitlines():
        if not line.strip():
            continue
        st, path = line.split("\t", 1)
        if status_filter is None or st[0] in status_filter:
            out.append((st[0], path))
    return out


def added_lines(wt, base, globs=None, exclude=None):
    out, f, ln = [], None, 0
    diff = git(wt, "diff", "-U0", "--no-color", base, "HEAD")
    for line in diff.splitlines():
        if line.startswith("+++ "):
            f = line[6:] if line.startswith("+++ b/") else None
            continue
        if line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            ln = int(m.group(1)) if m else 0
            continue
        if line.startswith("+") and f:
            if (not globs or glob_any(f, globs)) and not glob_any(f, exclude or []):
                out.append((f, ln, line[1:]))
            ln += 1
    return out


def test_commands(proj, repo, paths):
    g = proj.rcfg(repo, "gate")
    cmds = list(g["tests"])
    for cond in g["conditional"]:
        if any(re.search(cond["when"], p) for p in paths):
            cmds += cond["run"]
    return cmds


def run_tests(proj, repo, wt, c, cmds, log):
    """Run test commands in wt; returns (ok, summary)."""
    with open(log, "w") as fh:
        for cmd in cmds:
            shown = proj.fmt(cmd, c)
            fh.write("$ %s\n" % shown)
            fh.flush()
            p = subprocess.run(shown, cwd=wt, shell=True, executable="/bin/bash", stdout=fh, stderr=subprocess.STDOUT,
                               env=hook_env(proj, c, "test"))
            if p.returncode != 0:
                return False, "`%s` failed (exit %d); tail of %s:\n%s" % (shown, p.returncode, log, tail(log, 25))
    return True, "%d command(s) green (log: %s)" % (len(cmds), log)


def tail(path, n):
    lines = open(path, errors="replace").read().splitlines()
    return "\n".join("        " + l for l in lines[-n:])


# ---------------------------------------------------------------- commands

def cmd_init(proj_path, args):
    tpl = json.load(open(os.path.join(SKILL_DIR, "template.json")))
    print(json.dumps(tpl, indent=2, ensure_ascii=False))


def cmd_doctor(proj, args):
    bad = []

    def ok(m):
        print("ok    " + m)

    def no(m):
        print("FAIL  " + m)
        bad.append(m)

    def warn(m):
        print("warn  " + m)

    ok("project %s (config %s)" % (proj.main, os.path.relpath(proj.config_path, proj.main)))
    for name in proj.repos or {proj.primary: {}}:
        try:
            root = proj.repo_root(name)
        except Fail as e:
            (no if name == proj.primary else warn)(str(e))
            continue
        ok("repo %s: %s" % (name, root))
        if proj.remote:
            if git_ok(root, "ls-remote", "-q", "--exit-code", proj.remote, "refs/heads/" + proj.base):
                ok("  %s reachable" % proj.base_ref())
            else:
                no("  cannot reach %s in %s" % (proj.base_ref(), root))
        elif not git_ok(root, "rev-parse", "-q", "--verify", "refs/heads/" + proj.base):
            no("  no local branch %s (remote is null, so base is local); create it: git -C %s branch %s"
               % (proj.base, root, proj.base))
        w = proj.rcfg(name, "worktree")
        if w["env_file"] and not os.path.exists(os.path.join(root, w["env_file"])):
            (warn if w["env_fallback"] else no)("  no %s in %s%s" % (
                w["env_file"], root, " (worktrees fall back to %s)" % w["env_fallback"] if w["env_fallback"] else ""))
        for rel in w["clone"]:
            if not os.path.exists(os.path.join(root, rel)):
                warn("  %s missing in the main checkout; worktree setup must install it" % rel)
    try:
        tasks, _ = load_plan(proj)
        ok("plan %s: %d tasks" % (proj.cfg["plan"]["file"], len(tasks)))
    except Fail as e:
        no(str(e))
    for tool in proj.cfg["doctor"]["require"]:
        tool = proj.fmt(tool, proj.vars())
        (ok if shutil.which(tool) or os.access(tool, os.X_OK) else no)("tool %s" % tool)
    for chk in proj.cfg["doctor"]["checks"]:
        cmd = proj.fmt(chk["run"] if isinstance(chk, dict) else chk, proj.ctx("doctor"))
        label = chk.get("name", cmd) if isinstance(chk, dict) else cmd
        p = run(cmd, cwd=proj.main, shell=True, check=False)
        (ok if p.returncode == 0 else no)("check %s%s" % (label, "" if p.returncode == 0 else ": " + (p.stderr or p.stdout).strip()[-200:]))
    if any(proj.rcfg(r, "deploy") for r in proj.repos or [proj.primary]):
        (ok if shutil.which("gh") and run(["gh", "auth", "status"], check=False).returncode == 0 else no)("gh authenticated (deploy-wait)")
    sm = proj.cfg.get("smoke") or {}
    ba = sm.get("basic_auth")
    if ba:
        pf = os.path.expanduser(ba.get("password_file", ""))
        (ok if os.path.isfile(pf) else warn)("smoke basic-auth password file %s" % pf)
    return 1 if bad else 0


def cmd_ready(proj, args):
    tasks, by_id = load_plan(proj)
    scope = args.scope
    rows = []
    for t in tasks:
        if scope and "all" not in scope and t["id"] not in scope and t["phase"]["id"] not in scope:
            continue
        state, detail = classify(t, by_id, proj.cfg["plan"], proj)
        if state == "done" and not scope:
            continue
        flags = []
        if t.get("parallel", "").strip().lower() in proj.cfg["plan"]["serial_values"]:
            flags.append("serial")
        if state == "ready" and t["phase"]["cap"]:
            flags.append("phase cap %d" % t["phase"]["cap"])
        title = re.sub(r"\s+", " ", t["task"])
        rows.append([t["id"], t["phase"]["id"], t["repo"], state, "; ".join([detail] + flags), title[:70]])
    print_table(["TASK", "PHASE", "REPO", "STATE", "DETAIL", "TITLE"], rows)


def print_table(head, rows):
    rows = [[str(c) for c in r] for r in rows]
    widths = [max(len(r[i]) for r in [head] + rows) for i in range(len(head))]
    for r in [head] + rows:
        print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip())


def find_task(proj, task):
    tasks, by_id = load_plan(proj)
    if task in by_id:
        return by_id[task]
    lower = {k.lower(): v for k, v in by_id.items()}
    return lower.get(task.lower())


def cmd_add(proj, args):
    task = args.task
    if norm_id(task) == norm_id(INTEGRATION) or norm_id(task) == "integration":
        die("reserved id")
    row = find_task(proj, task)
    if row:
        task = row["id"]
    else:
        info("WARN: %s is not in the plan; adding it anyway (ad-hoc task)" % task)
    repo = args.repo or proj.state(task).get("repo") or (row["repo"] if row else proj.primary)
    root = proj.repo_root(repo)
    w = proj.rcfg(repo, "worktree")
    wt = os.path.join(root, w["dir"], norm_id(task))
    branch = "phase/" + norm_id(task)
    ensure_excludes(proj, root, repo)
    proj.fetch(root)
    git(root, "worktree", "prune")
    if os.path.isdir(wt):
        info("reusing " + wt)
    elif git_ok(root, "show-ref", "--verify", "-q", "refs/heads/" + branch):
        git(root, "worktree", "add", "-q", wt, branch)
        info("resumed existing branch " + branch)
    else:
        git(root, "worktree", "add", "-q", "--no-track", "-b", branch, wt, proj.base_ref())
    st = proj.state(task)
    if st.get("status") in (None, "", "removed", "merged"):
        if os.path.exists(proj.sfile(task)):
            os.replace(proj.sfile(task), proj.sfile(task) + ".old")
        st = proj.save(task, status="running", started=now())
    slot = st.get("slot") or alloc_slot(proj)
    proj.save(task, task=task, repo=repo, branch=branch, worktree=wt, slot=slot,
              port=proj.cfg["slots"]["port_base"] + int(slot), date=datetime.date.today().strftime("%Y_%m_%d"),
              base=st.get("base") or git(wt, "merge-base", proj.base_ref(), "HEAD"))
    c = proj.ctx(task, repo)
    prepare_wt(proj, repo, wt, c, "add")
    print("worktree: %s (branch %s from %s @ %s)" % (wt, branch, proj.base_ref(), proj.state(task)["base"][:7]))
    print("brief:    %s brief %s" % (proj.script, task))


def cmd_brief(proj, args):
    task = args.task
    row = find_task(proj, task)
    st = proj.state(row["id"] if row else task)
    if not st.get("worktree"):
        die("no worktree for %s; run: %s add %s" % (task, proj.script, task))
    task = st["task"]
    c = proj.ctx(task)
    row = row or {"id": task, "task": "(ad-hoc task, not in the plan)", "spec": "", "done_when": "", "deps": "",
                  "phase": {"id": "-", "name": "-"}}
    c.update({k: row.get(k, "") for k in ("task", "spec", "done_when", "deps")})
    b = proj.rcfg(c["repo"], "brief")
    lines = [
        "Task %s%s: %s" % (task, (" of " + proj.cfg["project"]) if proj.cfg["project"] else "", row["task"]),
        "Phase: %s. Repo: %s." % (row["phase"]["name"], c["repo"]),
        "",
        "Worktree: %s" % c["wt"],
        "Branch: phase/%s, cut from %s @ %s. Work only in the worktree." % (c["id"], proj.base_ref(), st.get("base", "")[:7]),
        "Spec: %s" % proj.fmt(b["spec"], c),
    ]
    if b["read"]:
        lines.append("Read first: %s" % ", ".join(proj.fmt(r, c) for r in b["read"]))
    lines.append("Done when: %s" % (proj.fmt(b["done_when"], c).strip() or "every acceptance point in the spec holds"))
    lines += [proj.fmt(e, c) for e in b["extra"]]
    if b["rules"]:
        lines += ["", "Project rules:"] + ["- " + proj.fmt(r, c) for r in b["rules"]]
    lines += [
        "",
        "Gate: %s check %s   (must end with RESULT: PASS before you report)" % (proj.script, task),
        "Sync: %s sync %s    (when the gate says you are behind, or the orchestrator says staging moved)" % (proj.script, task),
        "Report: %s/%s" % (c["wt"], REPORT),
        "Context from other tasks: none",
    ]
    print("\n".join(lines))
    if args.inline_rules:
        candidates = [os.path.join(SKILL_DIR, "agents", "phase-implementer.md"),
                      os.path.join(SKILL_DIR, "..", "..", "agents", "phase-implementer.md")]
        found = [c for c in candidates if os.path.isfile(c)]
        if not found:
            die("phase-implementer.md not found next to the skill (looked in %s)" % ", ".join(candidates))
        body = open(found[0]).read()
        print("\nStanding rules:\n" + re.sub(r"(?s)^---.*?---\s*", "", body))


def cmd_review_brief(proj, args):
    st = proj.state(args.task)
    if not st:
        die("unknown task " + args.task)
    task = st["task"]
    row = find_task(proj, task) or {"spec": "", "done_when": "", "task": ""}
    c = proj.ctx(task)
    c.update({k: row.get(k, "") for k in ("task", "spec", "done_when")})
    b = proj.rcfg(c["repo"], "brief")
    checklist = proj.rcfg(c["repo"], "review")["checklist"]
    lines = [
        "Review task %s%s: %s" % (task, (" of " + proj.cfg["project"]) if proj.cfg["project"] else "", row["task"]),
        "Worktree: %s (branch phase/%s; diff base: git -C %s merge-base %s HEAD)" % (c["wt"], c["id"], c["wt"], proj.base_ref()),
        "Spec: %s" % proj.fmt(b["spec"], c),
    ]
    if b["read"]:
        lines.append("Project rules and decisions: %s" % ", ".join(proj.fmt(r, c) for r in b["read"]))
    lines.append("Done when: %s" % proj.fmt(b["done_when"], c))
    lines.append("Why review is required: %s" % st.get("review", "requested"))
    if checklist or b["rules"]:
        lines += ["", "Project invariants to check:"] + ["- " + proj.fmt(x, c) for x in checklist + b["rules"]]
    lines.append("Implementer's report (read it last): %s/%s" % (c["wt"], REPORT))
    print("\n".join(lines))


def cmd_note(proj, args):
    kv = {}
    for pair in args.pairs:
        if "=" not in pair:
            die("expected key=value, got " + pair)
        k, v = pair.split("=", 1)
        kv[k] = v
    if not proj.state(args.task):
        die("unknown task %s (add it first)" % args.task)
    proj.save(args.task, **kv)


def cmd_status(proj, args):
    rows = []
    for st in proj.states():
        if st.get("status") in ("merged", "removed") and not args.all:
            continue
        task = st.get("task", "?")
        repo = st.get("repo", proj.primary)
        ahead = behind = tree = last = "-"
        tip = ""
        try:
            root = proj.repo_root(repo)
        except Fail:
            root = None
        br = "phase/" + norm_id(task)
        if root and git_ok(root, "show-ref", "-q", "--verify", "refs/heads/" + br):
            ahead = git(root, "rev-list", "--count", "%s..%s" % (proj.base_ref(), br))
            behind = git(root, "rev-list", "--count", "%s..%s" % (br, proj.base_ref()))
            tip = git(root, "rev-parse", br)
            last = git(root, "log", "-1", "--format=%cr: %s", br)[:50]
        wt = st.get("worktree")
        if wt and os.path.isdir(wt):
            tree = "dirty" if git(wt, "status", "--porcelain") else "clean"
        gate = st.get("check", "") or "-"
        if gate.startswith("pass:"):
            gate = "pass" if not tip or gate[5:] == tip else "stale"
        rows.append([task, repo, st.get("status", "-"), (st.get("agent") or "-")[:14], ahead, behind, tree, gate,
                     (st.get("review") or "-").split(" ")[0], last])
    print_table(["TASK", "REPO", "STATUS", "AGENT", "AHEAD", "BEHIND", "TREE", "GATE", "REVIEW", "LAST COMMIT"], rows)
    known = {norm_id(s.get("task", "")) for s in proj.states()}
    for repo in proj.repos or {proj.primary: {}}:
        try:
            root = proj.repo_root(repo)
        except Fail:
            continue
        for br in git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads/phase/*").split():
            if br[6:] not in known:
                print("orphan branch in %s: %s (no state; inspect, then '%s add <ID> --repo %s' to adopt)"
                      % (repo, br, proj.script, repo))
        iw = proj.int_wt(repo)
        if os.path.isdir(iw) and git(iw, "status", "--porcelain"):
            print("integration (%s): merge in progress at %s" % (repo, iw))


def cmd_overlap(proj, args):
    owners = {}
    for st in proj.states():
        if st.get("status") not in ACTIVE:
            continue
        repo = st.get("repo", proj.primary)
        try:
            root = proj.repo_root(repo)
        except Fail:
            continue
        br = "phase/" + norm_id(st["task"])
        if not git_ok(root, "show-ref", "-q", "--verify", "refs/heads/" + br):
            continue
        mb = git(root, "merge-base", proj.base_ref(), br)
        for p in git(root, "diff", "--name-only", mb, br).splitlines():
            owners.setdefault("%s:%s" % (repo, p), []).append(st["task"])
        for p in git(root, "diff", "--name-only", mb, proj.base_ref()).splitlines():
            owners.setdefault("%s:%s" % (repo, p), []).append("%s(new)" % proj.base)
    rows = [[k, ", ".join(sorted(set(v)))] for k, v in sorted(owners.items())
            if len(set(v)) > 1 and any(not x.endswith("(new)") for x in v)]
    if rows:
        print_table(["FILE", "TOUCHED BY"], rows)
    else:
        print("no overlaps")


def cmd_sync(proj, args):
    task = proj.state(args.task).get("task") or die("unknown task " + args.task)
    repo = proj.task_repo(task)
    wt = proj.wt(task)
    if git(wt, "status", "--porcelain"):
        die("commit or stash in %s first (sync rebases)" % wt)
    proj.fetch(proj.repo_root(repo))
    if git(wt, "rev-list", "--count", "HEAD..%s" % proj.base_ref()) == "0":
        print("up to date with " + proj.base_ref())
        return 0
    old = git(wt, "rev-parse", "HEAD")
    if not git_ok(wt, "rebase", "-q", proj.base_ref()):
        print("CONFLICT rebasing phase/%s onto %s:" % (norm_id(task), proj.base_ref()))
        for f in git(wt, "diff", "--name-only", "--diff-filter=U").splitlines():
            print("  " + f)
        if args.keep:
            print("left in progress: resolve, git add, git rebase --continue (in %s), then check" % wt)
        else:
            git(wt, "rebase", "--abort")
            print("rebase aborted; branch unchanged. To resolve: %s sync %s --keep" % (proj.script, task))
        return 2
    proj.save(task, check="", base=git(wt, "rev-parse", proj.base_ref()))
    if git(wt, "diff", "--name-only", old, "HEAD"):
        run_hooks(proj, proj.ctx(task), proj.rcfg(repo, "worktree")["refresh"], "refresh", wt)
    print("rebased onto %s @ %s; run the gate again" % (proj.base_ref(), git(wt, "rev-parse", "--short", proj.base_ref())))
    return 0


def cmd_check(proj, args):
    st = proj.state(args.task)
    if not st:
        die("unknown task %s (add it first)" % args.task)
    task, repo = st["task"], st.get("repo", proj.primary)
    wt = st["worktree"]
    if not os.path.isdir(wt):
        die("no worktree " + wt)
    g = proj.rcfg(repo, "gate")
    c = proj.ctx(task)
    fails, warns, review = [0], [0], set()

    def P(m):
        print("ok    " + m)

    def F(m, lines=None):
        print("FAIL  " + m)
        for l in lines or []:
            print("        " + l)
        fails[0] += 1

    def W(m, lines=None):
        print("warn  " + m)
        for l in lines or []:
            print("        " + l)
        warns[0] += 1

    proj.fetch(proj.repo_root(repo))
    base = git(wt, "merge-base", proj.base_ref(), "HEAD")
    ahead = int(git(wt, "rev-list", "--count", "%s..HEAD" % proj.base_ref()))
    behind = int(git(wt, "rev-list", "--count", "HEAD..%s" % proj.base_ref()))
    dirty = git(wt, "status", "--porcelain")
    P("tree clean") if not dirty else F("uncommitted or untracked files (commit or delete them):", dirty.splitlines())
    P("%d commit(s) on phase/%s" % (ahead, norm_id(task))) if ahead else F("no commits on phase/%s" % norm_id(task))
    if behind:
        W("%d commit(s) behind %s: run '%s sync %s', then check again" % (behind, proj.base_ref(), proj.script, task))
    else:
        P("based on the current " + proj.base_ref())

    files = changed(wt, base)
    paths = [p for _, p in files]
    owned = list(g["owned"]) + [proj.cfg["plan"]["file"]] + ([proj.cfg["land"]["progress_file"]] if proj.cfg["land"]["progress_file"] else [])
    bad = []
    for st_, p in files:
        if st_ != "D" and glob_any(p, g["forbid"]) and not glob_any(p, g["forbid_allow"]):
            bad.append("must not be committed: " + p)
        if glob_any(p, owned) and repo == proj.primary:
            bad.append("%s is the orchestrator's: git checkout %s -- %s" % (p, base[:9], p))
        if st_ != "A" and glob_any(p, g["immutable"]):
            bad.append("existing file under an immutable path changed (%s): %s; add a new file instead" % (st_, p))
    for b_ in bad:
        F(b_)
    if not bad:
        P("no forbidden, owned or immutable files touched")

    for rule in g["rules"]:
        hits = [h for h in added_lines(wt, base, rule.get("paths"), rule.get("exclude"))
                if re.search(rule["regex"], h[2])]
        msg = rule.get("message", rule.get("name", rule["regex"]))
        lines = ["%s:%d: %s" % (f, n, t.strip()[:140]) for f, n, t in hits[:20]]
        if hits:
            (F if rule.get("level", "fail") == "fail" else W)(msg, lines)
        elif rule.get("level", "fail") == "fail":
            P("rule ok: " + rule.get("name", msg))

    hits = [h for h in added_lines(wt, base, None, g["secret_exclude"]) if SECRETS.search(h[2])]
    F("secret-looking values:", ["%s:%d" % (f, n) for f, n, _ in hits[:20]]) if hits else P("no secrets in added lines")

    for pf in g["per_file"]:
        errs = []
        for st_, p in files:
            if st_ in "AM" and glob_any(p, [pf["glob"]]):
                cmd = proj.fmt(pf["run"], dict(c, file=shlex.quote(p)))
                r = run(cmd, cwd=wt, shell=True, check=False)
                if r.returncode != 0:
                    errs.append("%s: %s" % (p, (r.stdout + r.stderr).strip().splitlines()[-1:] or ["failed"])[0][:160])
        name = pf.get("name", pf["run"])
        F(name, errs) if errs else P(name)

    for trig in proj.rcfg(repo, "gate")["review"]["triggers"]:
        if any(re.search(trig["paths"], p) for p in paths):
            review.add(trig["name"])
    churn = 0
    for line in git(wt, "diff", "--numstat", base, "HEAD").splitlines():
        a, d = line.split("\t")[:2]
        churn += (int(a) if a.isdigit() else 0) + (int(d) if d.isdigit() else 0)
    if churn > g["review"]["lines"]:
        review.add("size:%d" % churn)
    need = ("required (%s)" % " ".join(sorted(review))) if review else "optional"
    P("diff: %d files, %d lines changed; review %s" % (len(files), churn, need))

    if not args.quick:
        cmds = test_commands(proj, repo, paths)
        if cmds:
            okk, summary = run_tests(proj, repo, wt, c, cmds, os.path.join(proj.state_dir, norm_id(task) + ".check.log"))
            P(summary) if okk else F(summary)
        else:
            W("no gate.tests configured")
        report = os.path.join(wt, REPORT)
        if os.path.exists(report) and os.path.getsize(report) > 0:
            P("report present")
        else:
            W("no %s yet" % report)

    if fails[0] == 0:
        if not args.quick:
            proj.save(task, check="pass:" + git(wt, "rev-parse", "HEAD"), review=need)
        print("RESULT: PASS (%d warning(s)); review %s" % (warns[0], need))
        return 0
    proj.save(task, check="fail")
    print("RESULT: FAIL (%d failure(s), %d warning(s))" % (fails[0], warns[0]))
    return 1


def cmd_merge(proj, args):
    st = proj.state(args.task)
    if not st:
        die("unknown task " + args.task)
    task, repo = st["task"], st.get("repo", proj.primary)
    if st.get("status") == "merged":
        die(task + " is already merged")
    root = proj.repo_root(repo)
    br = "phase/" + norm_id(task)
    tip = git(root, "rev-parse", br)
    if st.get("check") != "pass:" + tip:
        die("the gate has not passed on the tip of %s (%s). Run: %s check %s" % (br, tip[:7], proj.script, task))
    iw = ensure_int(proj, repo)
    if repo != proj.primary:
        ensure_int(proj, proj.primary)
    if not git_ok(iw, "merge", "--squash", br):
        print("CONFLICT squashing %s onto %s:" % (br, proj.base_ref()))
        for f in git(iw, "diff", "--name-only", "--diff-filter=U").splitlines():
            print("  " + f)
        git(iw, "reset", "-q", "--hard", proj.base_ref())
        print("integration reset. Resolve on the task branch: %s sync %s --keep (or send it back), check, merge again"
              % (proj.script, task))
        return 2
    c = proj.ctx(task)
    c.update({"wt": iw, "id": "integration", "port": proj.cfg["slots"]["port_base"] - 1})
    run_hooks(proj, c, proj.rcfg(repo, "worktree")["refresh"], "refresh", iw)
    paths = git(iw, "diff", "--cached", "--name-only").splitlines()
    okk, summary = run_tests(proj, repo, iw, c, test_commands(proj, repo, paths),
                             os.path.join(proj.state_dir, norm_id(task) + ".merge.log"))
    if not okk:
        git(iw, "reset", "-q", "--hard", proj.base_ref())
        print("FAIL  full checks after the squash onto the current %s: %s" % (proj.base_ref(), summary))
        print("The task was green alone, so it collides with something landed since it was cut: sync, fix, check, merge")
        return 1
    proj.save(task, status="merging", merge_onto=git(iw, "rev-parse", "HEAD"))
    pf = proj.cfg["land"]["progress_file"]
    piw = proj.int_wt(proj.primary)
    print("ok    squash of %s staged on %s @ %s; %s" % (br, proj.base_ref(), git(iw, "rev-parse", "--short", "HEAD"), summary))
    if pf:
        print("next: edit %s (task status, done log, open items and deploy steps from the report)" % os.path.join(piw, pf))
        if repo != proj.primary:
            print("      write {sha} where the %s commit goes; land fills it in" % repo)
    print('then: %s land %s "%s: <what>" (multi-line message; include the attribution trailer)' % (proj.script, task, task))
    return 0


def push(proj, d, repo, c):
    """Push HEAD of an integration worktree to base. Rebases over a moved base and re-runs the checks."""
    if not proj.remote:
        # Local-only base: fast-forward the base branch wherever it is checked out, else move the ref.
        sha = git(d, "rev-parse", "HEAD")
        holder = None
        for block in git(d, "worktree", "list", "--porcelain").split("\n\n"):
            if "branch refs/heads/%s" % proj.base in block:
                holder = block.splitlines()[0].split(" ", 1)[1]
        if holder:
            if git(holder, "status", "--porcelain", "--untracked-files=no"):
                die("%s is checked out in %s with local changes; commit or stash them, then land again" % (proj.base, holder))
            git(holder, "merge", "-q", "--ff-only", sha)
        else:
            git(d, "update-ref", "refs/heads/" + proj.base, sha, git(d, "rev-parse", "HEAD~1"))
        return sha
    url = git(d, "remote", "get-url", proj.remote)
    target = proj.remote
    changed_paths = git(d, "diff", "--name-only", "HEAD~1", "HEAD").splitlines()
    if url.startswith("https://github.com/") and any(glob_any(p, proj.cfg["land"]["ssh_push_when"]) for p in changed_paths):
        target = "git@github.com:" + url[len("https://github.com/"):]
        info("workflow files changed: pushing over SSH (%s)" % target)
    for attempt in range(3):
        if git_ok(d, "push", "-q", target, "HEAD:refs/heads/" + proj.base):
            proj.fetch(proj.repo_root(repo))
            return git(d, "rev-parse", "HEAD")
        proj.fetch(proj.repo_root(repo))
        if not git_ok(d, "rebase", "-q", proj.base_ref()):
            git(d, "rebase", "--abort", check=False)
            die("%s moved and the rebase conflicts; resolve by hand in %s" % (proj.base_ref(), d))
        info("%s moved; rebased, re-running the checks" % proj.base_ref())
        okk, summary = run_tests(proj, repo, d, c, test_commands(proj, repo, git(d, "diff", "--name-only", "HEAD~1", "HEAD").splitlines()),
                                 os.path.join(proj.state_dir, "push.log"))
        if not okk:
            die("checks red after rebasing onto the new %s; nothing pushed: %s" % (proj.base_ref(), summary))
    die("push failed 3 times; the commit is still in " + d)


def worktree_edits(d):
    """Paths changed in the working tree relative to the index, untracked files included."""
    out = []
    for line in run(["git", "-C", d, "status", "--porcelain", "--untracked-files=all"]).stdout.splitlines():
        if len(line) > 3 and line[1] != " ":
            out.append(line[3:].split(" -> ")[-1].strip('"'))
    return out


def commit(d, msg):
    git(d, "add", "-A")
    p = subprocess.run(["git", "-C", d, "commit", "-q", "-F", "-"], input=msg, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0:
        die("commit failed in %s: %s" % (d, p.stderr.strip()))


def cmd_land(proj, args):
    st = proj.state(args.task)
    if not st:
        die("unknown task " + args.task)
    task, repo = st["task"], st.get("repo", proj.primary)
    if st.get("status") != "merging":
        die("%s has no staged merge; run: %s merge %s" % (task, proj.script, task))
    iw, piw = proj.int_wt(repo), proj.int_wt(proj.primary)
    if git(iw, "rev-parse", "HEAD") != st.get("merge_onto"):
        die("integration HEAD moved since merge; run merge again")
    land = proj.cfg["land"]
    pf = land["progress_file"]
    if pf and land["require_progress"] and git_ok(piw, "diff", "--quiet", "HEAD", "--", pf):
        die("%s is unchanged in %s: update it first (same commit as the work)" % (pf, piw))
    allowed = land["allow_after_merge"] + ([pf] if pf else [])
    c = proj.ctx(task)
    c.update({"wt": iw, "id": "integration"})
    if repo == proj.primary:
        extra = [p for p in worktree_edits(iw) if not glob_any(p, allowed)]
        if extra:
            die("files changed after merge's checks ran (untested): %s. Fix on the task branch, or abort and merge again" % ", ".join(extra))
        commit(iw, args.message)
        sha = push(proj, iw, repo, c)
        other = None
    else:
        extra = [p for p in worktree_edits(piw) + git(piw, "diff", "--cached", "--name-only").splitlines()
                 if not glob_any(p, allowed)]
        if extra:
            die("primary integration has changes outside %s: %s" % (allowed, ", ".join(extra)))
        if worktree_edits(iw):
            die("%s integration has edits after the checks ran: %s" % (repo, ", ".join(worktree_edits(iw))))
        commit(iw, args.message)
        other = push(proj, iw, repo, c)
        if pf:
            path = os.path.join(piw, pf)
            text = open(path, encoding="utf-8").read().replace("{sha}", other[:7])
            open(path, "w", encoding="utf-8").write(text)
        lines = args.message.splitlines()
        subject = "%s: progress (%s %s)" % (task, repo, other[:7])
        commit(piw, "\n".join([subject] + lines[1:]))
        pc = proj.ctx(task, proj.primary)
        pc.update({"wt": piw, "id": "integration"})
        sha = push(proj, piw, proj.primary, pc)
    wt = st.get("worktree")
    if wt and os.path.exists(os.path.join(wt, REPORT)):
        shutil.copy2(os.path.join(wt, REPORT), os.path.join(proj.state_dir, norm_id(task) + ".report.md"))
    proj.save(task, status="merged", commit=sha, other_commit=other or "", merged_at=now())
    print("landed %s: %s %s%s on %s" % (task, proj.primary, sha[:7], (", %s %s" % (repo, other[:7])) if other else "", proj.base))
    nxt = []
    if proj.rcfg(repo, "deploy") or proj.rcfg(proj.primary, "deploy"):
        nxt.append("%s deploy-wait %s (in the background)" % (proj.script, sha))
    if proj.cfg.get("smoke"):
        nxt.append("%s smoke %s" % (proj.script, task))
    nxt.append("%s remove %s" % (proj.script, task))
    print("next: " + ", then ".join(nxt))
    return 0


def cmd_abort(proj, args):
    for repo in proj.repos or {proj.primary: {}}:
        try:
            iw = proj.int_wt(repo)
        except Fail:
            continue
        if not os.path.isdir(iw):
            continue
        git(iw, "merge", "--abort", check=False)
        git(iw, "rebase", "--abort", check=False)
        git(iw, "reset", "-q", "--hard", proj.base_ref())
        git(iw, "clean", "-qfd")
        print("reset %s to %s" % (iw, proj.base_ref()))
    for st in proj.states():
        if st.get("status") == "merging":
            proj.save(st["task"], status="review")
            print("%s back to review" % st["task"])


def gh_json(args):
    p = run(["gh"] + args, check=False)
    if p.returncode != 0:
        die("gh %s: %s" % (" ".join(args), p.stderr.strip()))
    return json.loads(p.stdout or "null")


def cmd_deploy_wait(proj, args):
    repo = args.repo or proj.primary
    d = proj.rcfg(repo, "deploy") or die("no deploy configured for repo " + repo)
    root = proj.repo_root(repo)
    proj.fetch(root)
    sha = args.sha or git(root, "rev-parse", proj.base_ref())
    sha = git(root, "rev-parse", sha)
    url = git(root, "remote", "get-url", proj.remote)
    slug = re.sub(r"^(git@github\.com:|https://github\.com/)", "", url)
    slug = re.sub(r"\.git$", "", slug)
    wf = d["github_workflow"]
    run_id = None
    for _ in range(36):
        rows = gh_json(["run", "list", "-R", slug, "-w", wf, "-b", proj.base, "-c", sha, "-L", "1", "--json", "databaseId"])
        if rows:
            run_id = rows[0]["databaseId"]
            break
        time.sleep(5)
    if not run_id:
        die("no %s run for %s after 3 minutes" % (wf, sha[:7]))
    while True:
        run(["gh", "run", "watch", str(run_id), "-R", slug, "--interval", "10"], check=False)
        concl = gh_json(["run", "view", str(run_id), "-R", slug, "--json", "conclusion"])["conclusion"]
        if concl != "cancelled":
            break
        # Concurrency groups replace a pending run with the newest one; follow a later run that contains sha.
        nxt = None
        for r in gh_json(["run", "list", "-R", slug, "-w", wf, "-b", proj.base, "-L", "10", "--json", "databaseId,headSha"]):
            if r["databaseId"] != run_id:
                git(root, "fetch", "-q", proj.remote, r["headSha"], check=False)
                if git_ok(root, "merge-base", "--is-ancestor", sha, r["headSha"]):
                    nxt = r["databaseId"]
                    break
        if not nxt:
            die("run %s was cancelled and no later run contains %s; re-run the workflow" % (run_id, sha[:7]))
        info("run %s cancelled by a newer push; following run %s" % (run_id, nxt))
        run_id = nxt
    if concl != "success":
        print("DEPLOY FAILED (%s): %s" % (concl, gh_json(["run", "view", str(run_id), "-R", slug, "--json", "url"])["url"]))
        return 1
    msg = "deployed %s (run %s)" % (sha[:7], run_id)
    if d.get("health_url"):
        code = http(d["health_url"], "GET", None)
        msg += "; %s -> %s" % (d["health_url"], code)
        if str(code) != str(d.get("health_status", 200)):
            print(msg)
            return 1
    print(msg)
    return 0


def http(url, method, auth):
    req = urllib.request.Request(url, method=method, headers={"Accept": "application/json", "User-Agent": "phase-smoke"})
    if auth:
        req.add_header("Authorization", "Basic " + base64.b64encode(auth.encode()).decode())
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code
    except Exception as e:  # noqa: BLE001
        return "error: %s" % e


def cmd_smoke(proj, args):
    sm = proj.cfg.get("smoke") or die("no smoke config (smoke.base_url) in phase.json")
    st = proj.state(args.task)
    task = st.get("task", args.task)
    rep = os.path.join(proj.state_dir, norm_id(task) + ".report.md")
    if not os.path.exists(rep):
        rep = os.path.join(st.get("worktree", ""), REPORT)
    if not os.path.exists(rep):
        die("no report for " + task)
    text = open(rep, encoding="utf-8").read()
    m = re.search(r"(?ms)^## Smoke\s*$(.*?)(?=^## |\Z)", text)
    lines = m.group(1).splitlines() if m else []
    ba = sm.get("basic_auth")
    auth = None
    if ba and os.path.isfile(os.path.expanduser(ba.get("password_file", ""))):
        auth = "%s:%s" % (ba["user"], open(os.path.expanduser(ba["password_file"])).read().strip())
    n = fails = 0
    for line in lines:
        mm = re.search(r"\b(GET|POST|PUT|PATCH|DELETE|HEAD)\s+(/[^\s`)]*)", line)
        if not mm:
            continue
        meth, path = mm.group(1), mm.group(2)
        exp = re.search(r"(?<!\d)([1-5]\d\d)(?!\d)", line[mm.end():])
        if not exp:
            print("skip  %s %s (no expected status)" % (meth, path))
            continue
        use_auth = None
        if ba and not re.search(ba.get("skip_paths", r"^$"), path):
            if not auth:
                print("skip  %s %s (needs basic auth: no %s)" % (meth, path, ba.get("password_file")))
                continue
            use_auth = auth
        n += 1
        code = http(sm["base_url"].rstrip("/") + path, meth, use_auth)
        if str(code) == exp.group(1):
            print("ok    %s %s -> %s" % (meth, path, code))
        else:
            print("FAIL  %s %s -> %s, expected %s" % (meth, path, code, exp.group(1)))
            fails += 1
    print("smoke: %d checked, %d failed" % (n, fails))
    return 1 if fails else 0


def cmd_remove(proj, args):
    st = proj.state(args.task)
    if not st:
        die("unknown task " + args.task)
    task, repo = st["task"], st.get("repo", proj.primary)
    root = proj.repo_root(repo)
    br = "phase/" + norm_id(task)
    wt = st.get("worktree") or proj.wt(task)
    if st.get("status") != "merged" and not args.force and git_ok(root, "show-ref", "-q", "--verify", "refs/heads/" + br) \
            and git(root, "rev-list", "--count", "%s..%s" % (proj.base_ref(), br)) != "0":
        die("%s has unmerged commits (status %s). Use --force to drop them" % (br, st.get("status")))
    rep = os.path.join(wt, REPORT)
    keep = os.path.join(proj.state_dir, norm_id(task) + ".report.md")
    if os.path.exists(rep) and not os.path.exists(keep):
        shutil.copy2(rep, keep)
    c = proj.ctx(task)
    if os.path.isdir(wt):
        try:
            run_hooks(proj, c, proj.rcfg(repo, "worktree")["teardown"], "remove", wt)
        except Fail as e:
            info("WARN: teardown: %s" % e)
    git(root, "worktree", "remove", "--force", wt, check=False)
    if os.path.isdir(wt):
        shutil.rmtree(wt)
    git(root, "worktree", "prune")
    git(root, "branch", "-D", br, check=False)
    if st.get("status") != "merged":
        proj.save(task, status="removed")
    print("removed " + wt)


HELP = """phase.py [--project DIR] <command> [args]   (task ids as in the plan; case does not matter)

Plan
  init                        print a starter .claude/phase.json
  doctor                      check repos, base branch, env files, plan, tools, project checks, gh
  ready [SCOPE ...]           task states from the plan on the base branch: ready, blocked, manual, partial, running
                              SCOPE: phase ids, task ids, or all
  brief <ID> [--inline-rules] implementer prompt (after add)
  review-brief <ID>           reviewer prompt
Work
  add <ID> [--repo NAME]      worktree + branch phase/<id> from the base, env, slot/port, setup hooks; resumes
  note <ID> key=value ...     record agent=<agent id>, status=review, ...
  status [--all]              every task: status, agent, ahead/behind, tree, gate, review need, last commit
  overlap                     files touched by more than one active task, or by the base since a task was cut
  sync <ID> [--keep]          rebase the task onto the base (aborts on conflict unless --keep), refresh hooks
  check <ID> [--quick]        the gate: forbidden/owned/immutable files, rules, secrets, per-file checks, tests
Land (orchestrator only, one task at a time)
  merge <ID>                  squash onto a fresh base in <worktrees>/_integration and run the checks
  land <ID> "<message>"       commit with the progress edit and push (secondary repo: its commit, then a
                              primary progress commit with {sha} filled in)
  abort                       drop a staged merge
  deploy-wait [SHA] [--repo]  follow the GitHub Actions deploy run for SHA (also through cancelled runs)
  smoke <ID>                  run the "## Smoke" lines of the task's report against smoke.base_url
  remove <ID> [--force]       teardown hooks, worktree, branch; refuses unmerged work without --force
"""


def main(argv):
    import argparse

    ap = argparse.ArgumentParser(prog="phase.py", add_help=False)
    ap.add_argument("--project")
    ap.add_argument("command", nargs="?", default="help")
    ap.add_argument("rest", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    cmd = a.command
    if cmd in ("help", "-h", "--help"):
        print(HELP)
        return 0
    sub = argparse.ArgumentParser(prog="phase.py " + cmd)
    if cmd in ("brief", "review-brief", "add", "note", "sync", "check", "merge", "land", "smoke", "remove"):
        sub.add_argument("task")
    if cmd == "ready":
        sub.add_argument("scope", nargs="*")
    if cmd == "brief":
        sub.add_argument("--inline-rules", action="store_true")
    if cmd == "add":
        sub.add_argument("repo_pos", nargs="?")
        sub.add_argument("--repo")
    if cmd == "note":
        sub.add_argument("pairs", nargs="+")
    if cmd == "status":
        sub.add_argument("--all", action="store_true")
    if cmd == "sync":
        sub.add_argument("--keep", action="store_true")
    if cmd == "check":
        sub.add_argument("--quick", action="store_true")
    if cmd == "land":
        sub.add_argument("message")
    if cmd == "deploy-wait":
        sub.add_argument("sha", nargs="?")
        sub.add_argument("--repo")
    if cmd == "remove":
        sub.add_argument("--force", action="store_true")
    args = sub.parse_args(a.rest)
    if cmd == "add" and getattr(args, "repo_pos", None) and not args.repo:
        args.repo = args.repo_pos
    if cmd == "init":
        cmd_init(a.project, args)
        return 0
    table = {
        "doctor": cmd_doctor, "ready": cmd_ready, "brief": cmd_brief, "review-brief": cmd_review_brief,
        "add": cmd_add, "note": cmd_note, "status": cmd_status, "overlap": cmd_overlap, "sync": cmd_sync,
        "check": cmd_check, "merge": cmd_merge, "land": cmd_land, "abort": cmd_abort,
        "deploy-wait": cmd_deploy_wait, "smoke": cmd_smoke, "remove": cmd_remove,
    }
    if cmd not in table:
        print("unknown command '%s'\n\n%s" % (cmd, HELP), file=sys.stderr)
        return 2
    proj = Project(a.project)
    return table[cmd](proj, args) or 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Fail as e:
        print("phase: %s" % e, file=sys.stderr)
        sys.exit(1)
