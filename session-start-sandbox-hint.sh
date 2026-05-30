#!/usr/bin/env bash
# SessionStart hook: emit Backend + Frontend dev workflow guidance.
# Loaded into context every session (any project) so cross-repo Incus + /wt-quick
# pattern is consistently top-of-mind.
#
# stdin: SessionStart hook input JSON ({source, cwd, ...})
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON
set -euo pipefail

HINT_FILE="${HOME}/.claude/sandbox-workflow-hint.md"

if [[ ! -f "$HINT_FILE" ]]; then
  exit 0
fi

CONTENT="$(cat "$HINT_FILE")"

jq -n \
  --arg context "$CONTENT" \
  '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $context
    }
  }'
