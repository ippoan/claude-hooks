#!/bin/bash
# PreToolUse hook: gh pr create を直接実行させず /pr-push スキルを使わせる

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# gh pr create を検出
if echo "$COMMAND" | grep -qE 'gh\s+pr\s+create'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "gh pr create を直接実行しないでください。/pr-push スキルを使ってください。"
    }
  }'
  exit 0
fi

exit 0