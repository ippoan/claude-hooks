#!/bin/bash
input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command')
cwd=$(echo "$input" | jq -r '.cwd')

# git commit コマンドかチェック
if echo "$command" | grep -q "git commit"; then
  status=$(cd "$cwd" && git status --short 2>/dev/null)

  if [ -n "$status" ]; then
    jq -n --arg ctx "【git status (未コミット)】
$status" '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }'
  fi
fi

# git status コマンドかチェック → 全リポジトリの状態を返す
if echo "$command" | grep -q "git status"; then
  settings="$cwd/.vscode/settings.json"
  if [ -f "$settings" ]; then
    result=""
    for repo in $(jq -r '.["git.scanRepositories"][]' "$settings" 2>/dev/null); do
      link="$cwd/$repo"
      real=$(readlink -f "$link" 2>/dev/null || true)
      if [ -d "$real/.git" ]; then
        branch=$(git -C "$real" branch --show-current 2>/dev/null)
        status=$(git -C "$real" status --short 2>/dev/null)
        if [ -n "$status" ]; then
          result="${result}[$repo] ($branch) changes:
$status
"
        else
          result="${result}[$repo] ($branch) clean
"
        fi
      fi
    done
    if [ -n "$result" ]; then
      jq -n --arg ctx "【関連リポジトリ git status】
$result" '{
        hookSpecificOutput: {
          hookEventName: "PostToolUse",
          additionalContext: $ctx
        }
      }'
    fi
  fi
fi
exit 0
