#!/usr/bin/env bash
# SessionStart hook: warn when memory files have been added since the last
# /memory-prune baseline.
#
# Mechanism:
#   - After /memory-prune completes, it writes `~/.claude/projects/<proj>/memory/.memory-prune-baseline`
#     (`touch` 0-byte file as mtime marker)
#   - This hook scans for *.md files in that dir with mtime > baseline,
#     excluding MEMORY.md itself and handover_*.md (handover is the only
#     category allowed in memory dir per `~/.claude/CLAUDE.md ## Memory routing`)
#   - If any found, inject warning into session context
#
# stdin: SessionStart hook input JSON ({source, cwd, ...})
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON (or nothing if clean)
set -euo pipefail

# Read cwd from hook input (fall back to $PWD)
INPUT="$(cat 2>/dev/null || true)"
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$CWD" ] && CWD="$PWD"

# Derive project's memory dir from cwd (Claude Code convention: /home/x/y → -home-x-y)
PROJ_KEY="$(echo "$CWD" | sed 's|/|-|g')"
MEM_DIR="${HOME}/.claude/projects/${PROJ_KEY}/memory"
BASELINE="${MEM_DIR}/.memory-prune-baseline"

[ -d "$MEM_DIR" ] || exit 0
[ -f "$BASELINE" ] || exit 0

# Find *.md files newer than baseline, excluding MEMORY.md and handover_*.md
# (handover is permitted to accumulate per Memory routing rule)
NEW_FILES="$(find "$MEM_DIR" -maxdepth 1 -name '*.md' -newer "$BASELINE" \
  -not -name 'MEMORY.md' \
  -not -name 'handover_*.md' \
  -printf '%f\n' 2>/dev/null | sort)"

if [ -z "$NEW_FILES" ]; then
  exit 0
fi

COUNT="$(echo "$NEW_FILES" | wc -l)"
FILE_LIST="$(echo "$NEW_FILES" | head -10 | sed 's/^/  - /')"
EXTRA=""
if [ "$COUNT" -gt 10 ]; then
  EXTRA=$'\n  ... ('"$((COUNT - 10))"' more)'
fi

BASELINE_DATE="$(stat -c %y "$BASELINE" 2>/dev/null | cut -d'.' -f1)"

MSG="⚠️ memory-prune baseline (${BASELINE_DATE}) 以降、${COUNT} 件の新規 memory file が追加されています:

${FILE_LIST}${EXTRA}

これらは feedback / reference / project context 等が memory dir に直接書き込まれた状態です。
\`~/.claude/CLAUDE.md\` の \`## Memory routing\` rule に従い、以下のいずれかに分散してください:
  1. Workflow-bound → 既存 skill の SKILL.md
  2. Universal rule → \`~/.claude/CLAUDE.md\`
  3. Project-specific → 該当 repo の CLAUDE.md
  4. Situational → grouped skill (\`secrets.md\` / \`package-publish-debug\` 等)

bloat 化前に \`/memory-prune\` を実行して再分散できます。
分散後は \`touch ${BASELINE}\` で baseline を更新してください (memory-prune skill が自動でやる)。

(handover_*.md は memory に常在許可、本 warning では検出対象外)"

jq -n --arg context "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $context
  }
}'
