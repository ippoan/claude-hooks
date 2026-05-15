#!/usr/bin/env bash
# One-shot installer for yhonda-ohishi/{claude-hooks,claude-skills}.
#
# Usage (from a fresh sandbox or local dev box):
#
#   curl -fsSL https://raw.githubusercontent.com/yhonda-ohishi/claude-hooks/main/install.sh | bash
#
# Or, if claude-hooks is already cloned locally:
#
#   bash install.sh
#
# What it does:
#   1. Clones (or `git pull --ff-only` if already present) both repos under
#      ~/.claude/sources/{claude-hooks,claude-skills}.
#   2. Symlinks every `SKILL.md` directory found under claude-skills into
#      ~/.claude/skills/<name> so user-level skills auto-pick-up.
#   3. Prints what it did. Does NOT register hooks in ~/.claude/settings.json
#      — that is left to the caller (project-local settings or the global
#      session-start-install-skills.sh meta-hook).
#
# Idempotent. Safe to re-run. Exits 0 on partial network failure (keeps any
# existing checkouts).
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
SOURCES_DIR="${CLAUDE_DIR}/sources"
SKILLS_DIR="${CLAUDE_DIR}/skills"

HOOKS_REPO_URL="${CLAUDE_HOOKS_HOOKS_URL:-https://github.com/yhonda-ohishi/claude-hooks.git}"
SKILLS_REPO_URL="${CLAUDE_HOOKS_SKILLS_URL:-https://github.com/yhonda-ohishi/claude-skills.git}"

mkdir -p "$SOURCES_DIR" "$SKILLS_DIR"

clone_or_pull() {
  local name="$1" url="$2"
  local dir="${SOURCES_DIR}/${name}"
  if [[ -d "${dir}/.git" ]]; then
    if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
      echo "  ↑ pulled ${name}"
    else
      echo "  ⚠ pull failed for ${name} (kept existing checkout)"
    fi
  else
    if git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null; then
      echo "  ✓ cloned ${name}"
    else
      echo "  ⚠ clone failed for ${name} (${url})" >&2
      return 1
    fi
  fi
}

echo "claude-hooks installer:"
clone_or_pull claude-hooks "$HOOKS_REPO_URL" || true
clone_or_pull claude-skills "$SKILLS_REPO_URL" || true

# Symlink every skill dir into ~/.claude/skills.
linked=0
if [[ -d "${SOURCES_DIR}/claude-skills" ]]; then
  while IFS= read -r -d '' skill_md; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    target="${SKILLS_DIR}/${skill_name}"
    if [[ -L "$target" || ! -e "$target" ]]; then
      ln -sfn "$skill_dir" "$target"
      linked=$((linked + 1))
    fi
  done < <(find "${SOURCES_DIR}/claude-skills" \
              \( -path "${SOURCES_DIR}/claude-skills/.git" -prune \) -o \
              -name SKILL.md -print0 2>/dev/null)
fi
echo "  ✓ linked ${linked} skill(s) into ${SKILLS_DIR}"

echo ""
echo "Done. Hooks live under ${SOURCES_DIR}/claude-hooks/ — reference them"
echo "from ~/.claude/settings.json or a project's .claude/settings.json"
echo "via \$HOME/.claude/sources/claude-hooks/<script>.sh."
