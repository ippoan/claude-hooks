#!/bin/bash
# PreToolUse hook: wrangler deploy を Claude から直接実行するのをブロック
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

if echo "$COMMAND" | grep -qP 'wrangler deploy(?!ments)'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "wrangler deploy は Claude から直接実行できません。ユーザーが手動で実行してください。"
    }
  }'
  exit 0
fi

exit 0
