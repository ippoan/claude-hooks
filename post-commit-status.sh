#!/bin/bash
input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# git commit コマンドかチェック
if echo "$command" | grep -q "git commit"; then
  cwd=$(echo "$input" | jq -r '.cwd')
  status=$(cd "$cwd" && git status --short 2>/dev/null)

  if [ -n "$status" ]; then
    # jq で安全に JSON 生成（特殊文字を自動エスケープ）
    jq -n --arg ctx "【git status (未コミット)】
$status" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }'
  fi
fi
exit 0
