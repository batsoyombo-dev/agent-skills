# agent-skills

Our Claude Code skills and agents, in one place, installable on any machine with one command.

Everything ships as one plugin, `ship`:

| Skill | What it gives you |
|---|---|
| [`scope`](plugins/ship/skills/scope/SKILL.md) | `/ship:scope <brief>`: turns a brief, feature idea or bug report into a validated phased plan (`docs/plans/<id>.md`): tasks with IDs, dependencies, acceptance criteria and verify commands, marked assumptions, and client questions ready to forward. `phase` runs the plan directly. |
| [`phase`](plugins/ship/skills/phase/SKILL.md) | `/ship:phase`: runs a project's plan tasks in parallel. One git worktree, environment and implementer agent per task; a deterministic gate; an independent reviewer; a serial merge queue onto the base branch (squash, full checks, progress file in the same commit, push, deploy watch, smoke). Project-agnostic: each repo describes itself in `.claude/phase.json` ([reference](plugins/ship/skills/phase/reference.md)). Agents: `ship:phase-implementer`, `ship:phase-reviewer`. |

Installed with `install.sh` instead of as a plugin, the same skills are plain `/scope` and `/phase` (agents `phase-implementer`, `phase-reviewer`). Asking in plain words ("scope this brief", "run phase P0") works either way.

## Install

You need `git`, `python3` (for phase), and access to this private repo: a `gh` login or an SSH key on GitHub.

**New machine, one command:**

```bash
gh api repos/batsoyombo-dev/agent-skills/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash
```

This clones the repo to `~/.agent-skills` and symlinks every skill into `~/.claude/skills/` and every agent into `~/.claude/agents/`. Start a new Claude Code session afterwards; skills and agents load at session start.

Without `gh`:

```bash
git clone git@github.com:batsoyombo-dev/agent-skills.git ~/.agent-skills && ~/.agent-skills/install.sh
```

Other commands:

```bash
~/.agent-skills/install.sh --update      # pull, relink, drop links to removed skills
~/.agent-skills/install.sh --list        # what is available and installed
~/.agent-skills/install.sh ship          # only some plugins
~/.agent-skills/install.sh --uninstall   # remove only the links that point into the checkout
```

If a skill or agent of the same name already exists, it is moved to `~/.claude/agent-skills-backup/<time>/`, never deleted. `CLAUDE_CONFIG_DIR` and `AGENT_SKILLS_DIR` override the two locations.

### Or as a Claude Code plugin

The repo is also a plugin marketplace:

```
/plugin marketplace add git@github.com:batsoyombo-dev/agent-skills.git
/plugin install ship@agent-skills
```

Plugins are copied into Claude Code's cache, and their names get the plugin's prefix (`/ship:phase`, `/ship:scope`, agent `ship:phase-implementer`). Update with `/plugin marketplace update agent-skills`. Use one install method per machine, not both: the installer warns when it finds both.

## Use phase in a repo

```bash
~/.claude/skills/phase/phase.py init > .claude/phase.json   # then fill it in, see reference.md
~/.claude/skills/phase/phase.py doctor
~/.claude/skills/phase/phase.py ready
```

Then ask Claude to "run phase P0" (or `/ship:phase P0`; `/phase P0` with `install.sh`). Commit `.claude/phase.json` with the repo.

No plan yet? `/ship:scope <brief>` writes one in `docs/plans/`; point `plan.file` and `land.progress_file` at it.

## Develop

- On your own machine, install from your working copy (`./install.sh` in the clone). The links point at it, so edits are live; start a new Claude Code session to reload a skill.
- Run all tests before pushing: `tests/run.sh`. CI runs them on Linux for every push; the macOS workflow (installer under bash 3.2) runs when `install.sh` changes, or by hand. The phase test builds throwaway repos with local remotes, so nothing reaches GitHub or a server.
- When a plugin changes behaviour, bump `version` in its `.claude-plugin/plugin.json`, so plugin installs pick up the update.

### Add a skill

A new skill usually goes into `ship` (`plugins/ship/skills/<skill>/`, agents in `plugins/ship/agents/`) and is then `/ship:<skill>`. Make a separate plugin only for something unrelated:

```
plugins/<name>/
  .claude-plugin/plugin.json      # name, version, description
  skills/<skill>/SKILL.md         # plus any scripts it runs (make them executable)
  agents/<agent>.md               # optional
  requires                        # optional: tools it needs, one per line (install.sh warns if missing)
tests/<name>/*.sh                 # picked up by tests/run.sh
```

Then add the plugin to `.claude-plugin/marketplace.json` and to the table above. Keep skills project-agnostic: whatever differs between repos belongs in that repo's config, not in the skill.
