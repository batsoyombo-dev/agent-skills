#!/usr/bin/env bash
# Install our agent skills into Claude Code by symlinking them from this checkout into ~/.claude.
#
#   ./install.sh                 install (or relink) every skill and agent
#   ./install.sh phase           only the named plugins
#   ./install.sh --update        git pull, then relink and drop links to things that were removed
#   ./install.sh --uninstall     remove every link that points into this checkout (or: --uninstall phase)
#   ./install.sh --list          show what is available and what is installed
#
# New device, one command (the repo is private, so it goes through your GitHub login):
#   gh api repos/batsoyombo-dev/agent-skills/contents/install.sh -H 'Accept: application/vnd.github.raw' | bash
# That clones to ~/.agent-skills (override with AGENT_SKILLS_DIR) and installs from there.
#
# Env: CLAUDE_CONFIG_DIR (default ~/.claude), AGENT_SKILLS_DIR (default ~/.agent-skills, bootstrap only).
# Works with macOS bash 3.2.
set -euo pipefail

REPO_SLUG=batsoyombo-dev/agent-skills
REPO_SSH=git@github.com:$REPO_SLUG.git
CLAUDE_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}

say()  { printf '%s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# ---- bootstrap: piped from curl/gh, or run from outside a checkout ----
src=${BASH_SOURCE[0]:-}
if [ -n "$src" ] && [ -f "$src" ]; then
  ROOT=$(cd -P "$(dirname "$src")" && pwd)
else
  ROOT=""
fi
if [ -z "$ROOT" ] || [ ! -d "$ROOT/plugins" ]; then
  dest=${AGENT_SKILLS_DIR:-$HOME/.agent-skills}
  if [ -d "$dest/.git" ]; then
    say "updating $dest"
    git -C "$dest" pull -q --ff-only
  else
    say "cloning $REPO_SLUG into $dest"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone "$REPO_SLUG" "$dest" -- -q
    else
      git clone -q "$REPO_SSH" "$dest" || die "clone failed: log in with 'gh auth login' or add an SSH key for GitHub"
    fi
  fi
  exec bash "$dest/install.sh" "$@"
fi

# ---- helpers ----
plugins() { for d in "$ROOT"/plugins/*/; do [ -d "$d" ] && basename "$d"; done; }

points_into_repo() { # path -> true when it is a symlink into this checkout
  [ -L "$1" ] || return 1
  case $(readlink "$1") in "$ROOT"/*) return 0 ;; *) return 1 ;; esac
}

link() { # source target
  local s=$1 t=$2
  mkdir -p "$(dirname "$t")"
  if points_into_repo "$t"; then
    [ "$(readlink "$t")" = "$s" ] && { say "  ok      ${t#$CLAUDE_DIR/}"; return; }
    rm "$t"
  elif [ -e "$t" ] || [ -L "$t" ]; then
    # Back up outside skills/ and agents/: Claude Code would load a backup copy as a second skill or agent.
    local bak; bak="$CLAUDE_DIR/agent-skills-backup/$(date +%Y%m%d-%H%M%S)/${t#$CLAUDE_DIR/}"
    mkdir -p "$(dirname "$bak")"
    mv "$t" "$bak"
    warn "moved the existing ${t#$CLAUDE_DIR/} to ${bak#$CLAUDE_DIR/}"
  fi
  ln -s "$s" "$t"
  say "  linked  ${t#$CLAUDE_DIR/} -> ${s#$ROOT/}"
}

check_requires() { # plugin
  local f=$ROOT/plugins/$1/requires tool
  [ -f "$f" ] || return 0
  while IFS= read -r tool; do
    case $tool in ''|'#'*) continue ;; esac
    command -v "$tool" >/dev/null 2>&1 || warn "$1 needs '$tool', which is not on PATH"
  done < "$f"
}

install_plugin() { # plugin
  local p=$1 d s a
  [ -d "$ROOT/plugins/$p" ] || die "no plugin '$p' (available: $(plugins | tr '\n' ' '))"
  say "$p"
  for d in "$ROOT/plugins/$p"/skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    s=${d%/}; link "$s" "$CLAUDE_DIR/skills/$(basename "$s")"
  done
  for a in "$ROOT/plugins/$p"/agents/*.md; do
    [ -f "$a" ] || continue
    link "$a" "$CLAUDE_DIR/agents/$(basename "$a")"
  done
  for s in "$ROOT/plugins/$p"/skills/*/*.py "$ROOT/plugins/$p"/skills/*/*.sh; do
    [ -f "$s" ] && chmod +x "$s"
  done
  check_requires "$p"
}

prune() { # drop links into this checkout whose source is gone
  local t
  for t in "$CLAUDE_DIR"/skills/* "$CLAUDE_DIR"/agents/*; do
    if points_into_repo "$t" && [ ! -e "$t" ]; then rm "$t"; say "  removed stale ${t#$CLAUDE_DIR/}"; fi
  done
}

uninstall() { # [plugin...]
  local t p keep
  for t in "$CLAUDE_DIR"/skills/* "$CLAUDE_DIR"/agents/*; do
    points_into_repo "$t" || continue
    if [ $# -gt 0 ]; then
      keep=1
      for p in "$@"; do case $(readlink "$t") in "$ROOT/plugins/$p/"*) keep=0 ;; esac; done
      [ $keep -eq 1 ] && continue
    fi
    rm "$t"; say "  removed ${t#$CLAUDE_DIR/}"
  done
}

list() {
  local p d a
  for p in $(plugins); do
    say "$p  ($(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/plugins/$p/.claude-plugin/plugin.json" 2>/dev/null | head -1))"
    for d in "$ROOT/plugins/$p"/skills/*/; do
      [ -f "$d/SKILL.md" ] || continue
      points_into_repo "$CLAUDE_DIR/skills/$(basename "$d")" && st=installed || st="not installed"
      say "  skill  $(basename "$d")  [$st]"
    done
    for a in "$ROOT/plugins/$p"/agents/*.md; do
      [ -f "$a" ] || continue
      points_into_repo "$CLAUDE_DIR/agents/$(basename "$a")" && st=installed || st="not installed"
      say "  agent  $(basename "$a" .md)  [$st]"
    done
  done
}

warn_plugin_duplicate() {
  local f=$CLAUDE_DIR/plugins/installed_plugins.json
  if [ -f "$f" ] && grep -q '@agent-skills"' "$f"; then
    warn "these skills are also installed as Claude Code plugins (@agent-skills); keep one install: /plugin uninstall <name>@agent-skills"
  fi
}

# ---- main ----
mode=install
case ${1:-} in
  --update) mode=update; shift ;;
  --uninstall) mode=uninstall; shift ;;
  --list) mode=list; shift ;;
  -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

case $mode in
  list) list ;;
  uninstall) uninstall "$@"; say "done" ;;
  update|install)
    if [ "$mode" = update ]; then
      [ -d "$ROOT/.git" ] && { say "pulling $(git -C "$ROOT" remote get-url origin 2>/dev/null || echo origin)"; git -C "$ROOT" pull -q --ff-only; }
    fi
    say "installing into $CLAUDE_DIR from $ROOT"
    if [ $# -gt 0 ]; then for p in "$@"; do install_plugin "$p"; done; else for p in $(plugins); do install_plugin "$p"; done; fi
    prune
    warn_plugin_duplicate
    say "done. Start a new Claude Code session to load new or changed skills and agents."
    ;;
esac
