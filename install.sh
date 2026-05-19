#!/usr/bin/env bash
# One-shot installer for yhonda-ohishi/{claude-hooks,claude-skills}.
#
# Usage (CCoW Setup script — paste the next line into the env's Setup script
# field; runs ONCE per container, has full proxy network reach):
#
#   curl -fsSL https://raw.githubusercontent.com/yhonda-ohishi/claude-hooks/main/install.sh | bash
#
# Local dev:
#
#   bash install.sh
#
# What it does:
#   1. Clones (or `git pull --ff-only` if already present) both repos under
#      ~/.claude/sources/{claude-hooks,claude-skills}.
#   2. Symlinks every `SKILL.md` directory found under claude-skills into
#      ~/.claude/skills/<name> so user-level skills auto-pick-up.
#   3. Registers `session-start-install-skills.sh` in
#      ~/.claude/settings.json with `CLAUDE_HOOKS_INSTALL_NETWORK=off`
#      so each SessionStart only re-symlinks (no proxy calls / no 502 risk).
#      Idempotent: re-runs replace the existing entry instead of duplicating.
#
# Network policy in CCoW:
#   - install.sh (= Setup script): proxy reach, clones everything.
#   - SessionStart hook: zero network. If `~/.claude/sources/*` were wiped
#     somehow, the hook logs it but does not try to re-fetch — re-run the
#     Setup script to repair.
#
# Opt-out env vars:
#   CLAUDE_HOOKS_SKIP_SETTINGS=1   # don't touch ~/.claude/settings.json
#   CLAUDE_HOOKS_HOOKS_URL=...     # private fork
#   CLAUDE_HOOKS_SKILLS_URL=...
#
# Idempotent. Safe to re-run. Exits 0 on partial network failure (keeps any
# existing checkouts).
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
SOURCES_DIR="${CLAUDE_DIR}/sources"
SKILLS_DIR="${CLAUDE_DIR}/skills"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

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

# Register the SessionStart hook in ~/.claude/settings.json (offline mode).
# Skipped when CLAUDE_HOOKS_SKIP_SETTINGS=1, or when jq is unavailable.
register_session_hook() {
  [[ "${CLAUDE_HOOKS_SKIP_SETTINGS:-0}" == "1" ]] && {
    echo "  ⊘ skipped settings.json (CLAUDE_HOOKS_SKIP_SETTINGS=1)"
    return 0
  }
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not installed — leaving ${SETTINGS_FILE} untouched" >&2
    return 0
  fi
  [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"
  # Idempotent merge: ensure SessionStart contains exactly one entry whose
  # `command` points at our hook. Other SessionStart hooks are preserved.
  local cmd='$HOME/.claude/sources/claude-hooks/session-start-install-skills.sh'
  local tmp="${SETTINGS_FILE}.tmp.$$"
  jq --arg cmd "$cmd" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    # drop any prior entry that targets our hook (so re-runs replace, not stack)
    .hooks.SessionStart |= map(
      select((.hooks // []) | map(.command) | index($cmd) | not)
    ) |
    .hooks.SessionStart += [{
      hooks: [{
        type: "command",
        command: $cmd,
        timeout: 5000,
        env: { CLAUDE_HOOKS_INSTALL_NETWORK: "off" }
      }]
    }]
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  echo "  ✓ registered SessionStart hook in ${SETTINGS_FILE} (network=off)"
}
register_session_hook

echo ""
echo "Done. SessionStart hook will run offline on every session and re-link"
echo "skills from ${SOURCES_DIR}/. To repair after a container rebuild,"
echo "re-run this installer from the Setup script."
