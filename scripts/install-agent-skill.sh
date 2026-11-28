#!/usr/bin/env bash
# Teach AI coding agents (Claude Code) how Node works on this machine:
#   1. symlink skills/node-docker-shims into ~/.claude/skills, so it stays
#      current with `git pull`
#   2. add a one-line pointer to ~/.claude/CLAUDE.md, which every session
#      loads, so agents never assume a host Node install
#
# Usage: scripts/install-agent-skill.sh [--yes | --no-claude-md]
#   --yes           add the CLAUDE.md line without asking
#   --no-claude-md  only link the skill
# Safe to run again: existing links and lines are left as they are.

set -Eeuo pipefail

mode="ask"
case "${1:-}" in
    --yes|-y) mode="yes" ;;
    --no-claude-md) mode="no" ;;
    "") ;;
    *) echo "Usage: $0 [--yes | --no-claude-md]" >&2; exit 2 ;;
esac

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
skill_name="node-docker-shims"
skill_src="$repo_root/skills/$skill_name"
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
skill_dst="$claude_dir/skills/$skill_name"
claude_md="$claude_dir/CLAUDE.md"
pointer="- node, npm, npx, yarn, pnpm and corepack on this machine are Docker shims (secure-node-macos), not a host Node install. Before running or debugging JavaScript tooling, load the \`$skill_name\` skill. Never install Node on the host, use NODE_SHIMS_MODE=local, or set NODE_SHIMS_WRANGLER_YES without asking first."

[[ -f "$skill_src/SKILL.md" ]] || { echo "❌ $skill_src/SKILL.md not found" >&2; exit 1; }

# 1. Skill link
mkdir -p "$claude_dir/skills"
if [[ -L "$skill_dst" ]]; then
    ln -sfn "$skill_src" "$skill_dst"
    echo "✅ Agent skill linked: $skill_dst -> $skill_src"
elif [[ -e "$skill_dst" ]]; then
    echo "⚠️  $skill_dst exists and is not a symlink; left unchanged."
    echo "   Remove it and run this script again to use the repo's version."
else
    ln -s "$skill_src" "$skill_dst"
    echo "✅ Agent skill linked: $skill_dst -> $skill_src"
fi

# 2. CLAUDE.md pointer
if [[ -f "$claude_md" ]] && grep -q "$skill_name" "$claude_md"; then
    echo "✅ $claude_md already points to the $skill_name skill"
    exit 0
fi
[[ "$mode" == "no" ]] && exit 0

if [[ "$mode" == "ask" ]]; then
    if [[ ! -t 0 ]]; then
        echo "💡 To make every Claude Code session aware of the shims, add this line to $claude_md:"
        echo "   $pointer"
        echo "   (or run: $0 --yes)"
        exit 0
    fi
    echo "Add this line to $claude_md so every Claude Code session knows Node runs in Docker?"
    echo "   $pointer"
    printf 'Add it? [Y/n] '
    read -r reply || reply=""
    case "$reply" in
        n|N|no|NO) echo "Skipped. Run $0 --yes to add it later."; exit 0 ;;
    esac
fi

mkdir -p "$claude_dir"
if [[ -s "$claude_md" ]] && [[ -n "$(tail -c 1 "$claude_md")" ]]; then
    printf '\n' >> "$claude_md"
fi
printf '%s\n' "$pointer" >> "$claude_md"
echo "✅ Added the $skill_name pointer to $claude_md"
