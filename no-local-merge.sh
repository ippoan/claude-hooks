#!/bin/bash
# PreToolUse hook: ローカルから gh pr merge を禁止
#
# なぜ必要か:
#   CI 全パス確認前にマージすると壊れたコードが main に入る。
#   auto-merge を使うか、CI 通過を確認してからマージすること。

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# gh pr merge コマンドを検出
if echo "$COMMAND" | grep -qP 'gh pr merge\b'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "ローカルからの gh pr merge は禁止です。auto-merge を使うか、GitHub Web UI からマージしてください。"
    }
  }'
  exit 0
fi

exit 0
