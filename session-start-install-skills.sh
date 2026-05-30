#!/usr/bin/env bash
# SessionStart hook: ensure yhonda-ohishi/{claude-skills,claude-hooks} and
# anthropics/skills are checked out under ~/.claude/sources and symlink
# discovered skill dirs into ~/.claude/skills/<name> so they are picked up
# as user-level skills.
#
# Why anthropics/skills is cloned locally:
#   Claude Code on Web (Cowork) runs in ephemeral containers and does NOT
#   mount UI-installed Anthropic skills (skill-creator / mcp-builder /
#   canvas-design / etc.) into the container. See anthropics/claude-code
#   issues #31542, #26254, #50669. Cloning the public anthropics/skills
#   repo here is the only reliable way to make those skills available
#   inside each session.
#
# Conflict policy: yhonda-ohishi/claude-skills wins over anthropics/skills
#   when both define a skill with the same name (yhonda is processed first,
#   anthropic is only linked into slots that are still empty).
#
# Network policy — `CLAUDE_HOOKS_INSTALL_NETWORK`:
#   - `off` (recommended for CCoW): never invoke git. Only re-link skills.
#     This is what install.sh registers, so the Setup script owns clone duty
#     and the per-session hook becomes a zero-network re-symlink pass.
#   - `auto` (default for local dev): clone only when sources/* is missing;
#     never pull. Existing checkouts are trusted.
#   - `force` (legacy TTL behaviour): clone if missing + `pull --ff-only`
#     at most once per `CLAUDE_HOOKS_INSTALL_TTL` seconds. Use when you
#     want every-session refresh on a machine with stable network.
#
# stdin:  SessionStart hook input JSON (ignored)
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SOURCES_DIR="${CLAUDE_DIR}/sources"
SKILLS_DIR="${CLAUDE_DIR}/skills"
MARKER_DIR="${CLAUDE_DIR}/.install-skills-marker"
TTL_SECONDS="${CLAUDE_HOOKS_INSTALL_TTL:-3600}"
NETWORK_POLICY="${CLAUDE_HOOKS_INSTALL_NETWORK:-auto}"

SKILLS_REPO_URL="${CLAUDE_HOOKS_SKILLS_URL:-https://github.com/yhonda-ohishi/claude-skills.git}"
HOOKS_REPO_URL="${CLAUDE_HOOKS_HOOKS_URL:-https://github.com/ippoan/claude-hooks.git}"
ANTHROPIC_SKILLS_REPO_URL="${CLAUDE_HOOKS_ANTHROPIC_SKILLS_URL:-https://github.com/anthropics/skills.git}"

log_lines=()
log() { log_lines+=("$1"); }

mkdir -p "$SOURCES_DIR" "$SKILLS_DIR" "$MARKER_DIR"

# `force` mode honours the TTL marker; `auto` / `off` ignore it (no pulls).
marker="${MARKER_DIR}/last-run"
fresh=0
if [[ "$NETWORK_POLICY" == "force" && -f "$marker" ]]; then
  now=$(date +%s)
  last=$(cat "$marker" 2>/dev/null || echo 0)
  if (( now - last < TTL_SECONDS )); then
    fresh=1
  fi
fi

sync_repo() {
  local name="$1" url="$2"
  local dir="${SOURCES_DIR}/${name}"
  if [[ -d "${dir}/.git" ]]; then
    if [[ "$NETWORK_POLICY" == "force" && $fresh -eq 0 ]]; then
      if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        log "pulled ${name}"
      else
        log "pull failed for ${name} (kept existing checkout)"
      fi
    fi
    # auto/off: existing checkout is trusted, no network touch.
  else
    if [[ "$NETWORK_POLICY" == "off" ]]; then
      log "missing ${name} (network=off — run install.sh to repair)"
      return 1
    fi
    if git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null; then
      log "cloned ${name}"
    else
      log "clone failed for ${name} (${url})"
      return 1
    fi
  fi
}

sync_repo "claude-skills" "$SKILLS_REPO_URL"           || true
sync_repo "claude-hooks"  "$HOOKS_REPO_URL"            || true
sync_repo "anthropic-skills" "$ANTHROPIC_SKILLS_REPO_URL" || true

# Symlink every SKILL.md dir into ~/.claude/skills/<name>.
#   yhonda-ohishi/claude-skills — scanned first (wins on name conflicts)
#   anthropics/skills           — only fills empty slots; never overwrites
#
# For each source, we re-link existing symlinks to track upstream moves and
# create new symlinks for previously unseen skills. Non-symlink targets are
# skipped (user-managed by hand).
linked=0
skipped_conflict=0

# args: <source-dir> <allow-relink: 1|0>
#   allow-relink=1 → re-point existing symlinks (used for yhonda, which owns
#   the slot). allow-relink=0 → only create when slot is empty (used for
#   anthropic, so user's overrides are never clobbered).
link_skills_from() {
  local source_dir="$1" allow_relink="$2"
  [[ -d "$source_dir" ]] || return 0
  while IFS= read -r -d '' skill_md; do
    local skill_dir skill_name target
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    target="${SKILLS_DIR}/${skill_name}"
    if [[ -L "$target" ]]; then
      if (( allow_relink == 1 )); then
        ln -sfn "$skill_dir" "$target"
        linked=$((linked + 1))
      fi
    elif [[ ! -e "$target" ]]; then
      ln -s "$skill_dir" "$target"
      linked=$((linked + 1))
    else
      skipped_conflict=$((skipped_conflict + 1))
    fi
  done < <(find "$source_dir" \
              \( -path "${source_dir}/.git" -prune \) -o \
              -name SKILL.md -print0 2>/dev/null)
}

link_skills_from "${SOURCES_DIR}/claude-skills"    1
link_skills_from "${SOURCES_DIR}/anthropic-skills" 0

[[ "$NETWORK_POLICY" == "force" ]] && date +%s > "$marker" 2>/dev/null || true

ctx_lines=()
ctx_lines+=("claude-skills / claude-hooks installer (SessionStart, network=${NETWORK_POLICY}):")
if (( fresh == 1 )); then
  ctx_lines+=("- fresh within TTL (${TTL_SECONDS}s) — skipped pull")
fi
for line in "${log_lines[@]}"; do
  ctx_lines+=("- ${line}")
done
ctx_lines+=("- skills linked: ${linked} into ${SKILLS_DIR}")
if (( skipped_conflict > 0 )); then
  ctx_lines+=("- skipped ${skipped_conflict} non-symlink target(s) under ${SKILLS_DIR} (already managed manually)")
fi
ctx_lines+=("- hooks checkout: ${SOURCES_DIR}/claude-hooks")

context=$(printf '%s\n' "${ctx_lines[@]}")

jq -n --arg context "$context" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
