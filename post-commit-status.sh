#!/bin/bash
input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')

# git commit コマンドかチェック
if echo "$command" | grep -q "git commit"; then
  cwd=$(echo "$input" | jq -r '.cwd')
  status=$(cd "$cwd" && git status --short 2>/dev/null)

  if [ -n "$status" ]; then
    # JSON内の改行をエスケープ
    escaped_status=$(echo "$status" | sed ':a;N;$!ba;s/\n/\\n/g')
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "【git status (未コミット)】\n${escaped_status}"
  }
}
EOF
  fi
fi
exit 0
