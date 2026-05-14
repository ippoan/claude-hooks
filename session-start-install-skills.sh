#!/usr/bin/env bash
# SessionStart hook: ensure yhonda-ohishi/{claude-skills,claude-hooks} are
# checked out under ~/.claude/sources and symlink discovered skill dirs into
# ~/.claude/skills/<name> so they are picked up as user-level skills.
#
# Idempotent: shallow clones the repos on first run; on subsequent runs runs
# `git pull --ff-only` at most once per TTL window (default 1h). The pull is
# best-effort — network / auth failures do not block the session.
#
# stdin:  SessionStart hook input JSON (ignored)
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON
set -euo pipefail

CLAUDE_DIR="${HOME}/.claude"
SOURCES_DIR="${CLAUDE_DIR}/sources"
SKILLS_DIR="${CLAUDE_DIR}/skills"
MARKER_DIR="${CLAUDE_DIR}/.install-skills-marker"
TTL_SECONDS="${CLAUDE_HOOKS_INSTALL_TTL:-3600}"

SKILLS_REPO_URL="${CLAUDE_HOOKS_SKILLS_URL:-https://github.com/yhonda-ohishi/claude-skills.git}"
HOOKS_REPO_URL="${CLAUDE_HOOKS_HOOKS_URL:-https://github.com/yhonda-ohishi/claude-hooks.git}"

log_lines=()
log() { log_lines+=("$1"); }

mkdir -p "$SOURCES_DIR" "$SKILLS_DIR" "$MARKER_DIR"

# fresh? skip network calls until TTL elapses.
marker="${MARKER_DIR}/last-run"
fresh=0
if [[ -f "$marker" ]]; then
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
    if (( fresh == 0 )); then
      if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        log "pulled ${name}"
      else
        log "pull failed for ${name} (kept existing checkout)"
      fi
    fi
  else
    if git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null; then
      log "cloned ${name}"
    else
      log "clone failed for ${name} (${url})"
      return 1
    fi
  fi
}

sync_repo "claude-skills" "$SKILLS_REPO_URL" || true
sync_repo "claude-hooks"  "$HOOKS_REPO_URL"  || true

# Symlink every SKILL.md dir under claude-skills into ~/.claude/skills/<name>.
# Sources scanned: top-level (<name>/SKILL.md) and the canonical project path
# (.claude/skills/<name>/SKILL.md).
linked=0
skipped_conflict=0
if [[ -d "${SOURCES_DIR}/claude-skills" ]]; then
  while IFS= read -r -d '' skill_md; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    target="${SKILLS_DIR}/${skill_name}"
    if [[ -L "$target" ]]; then
      ln -sfn "$skill_dir" "$target"
      linked=$((linked + 1))
    elif [[ ! -e "$target" ]]; then
      ln -s "$skill_dir" "$target"
      linked=$((linked + 1))
    else
      skipped_conflict=$((skipped_conflict + 1))
    fi
  done < <(find "${SOURCES_DIR}/claude-skills" \
              \( -path "${SOURCES_DIR}/claude-skills/.git" -prune \) -o \
              -name SKILL.md -print0 2>/dev/null)
fi

date +%s > "$marker" 2>/dev/null || true

ctx_lines=()
ctx_lines+=("claude-skills / claude-hooks installer (SessionStart):")
if (( fresh == 1 )); then
  ctx_lines+=("- fresh within TTL (${TTL_SECONDS}s) — skipped network sync")
fi
for line in "${log_lines[@]}"; do
  ctx_lines+=("- ${line}")
done
ctx_lines+=("- skills linked: ${linked} into ${SKILLS_DIR}")
if (( skipped_conflict > 0 )); then
  ctx_lines+=("- skipped ${skipped_conflict} non-symlink target(s) under ${SKILLS_DIR} (already managed manually)")
fi
ctx_lines+=("- hooks checkout: ${SOURCES_DIR}/claude-hooks (register in ~/.claude/settings.json manually)")

context=$(printf '%s\n' "${ctx_lines[@]}")

jq -n --arg context "$context" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
