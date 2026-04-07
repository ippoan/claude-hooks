#!/bin/bash
# PreToolUse hook: git checkout/switch で main に移動するのを常にブロック
# worktree を使って新しいブランチを作成するよう強制する
#
# ブロック対象:
#   git checkout main, git checkout -b xxx main, git switch main
# 許可:
#   git checkout -- file (ファイル復元)
#   git checkout main -- path (特定ファイルを main から復元)
#   git checkout -b xxx (main を指定しない、現在ブランチから分岐)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# git checkout / git switch 以外は通過
if ! echo "$COMMAND" | grep -qE 'git (checkout|switch)'; then
  exit 0
fi

# branch protection が設定されていないリポジトリは許可
REPO=$(cd "$CWD" && gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)
if [ -n "$REPO" ]; then
  PROTECTED=$(gh api "repos/$REPO/branches/main" --jq '.protected' 2>/dev/null)
  if [ "$PROTECTED" != "true" ]; then
    exit 0
  fi
fi

# git checkout -- file (ファイル復元) は許可
if echo "$COMMAND" | grep -qE 'git checkout\s+--\s'; then
  exit 0
fi

# git checkout main -- path (特定ファイルを main から復元) は許可
if echo "$COMMAND" | grep -qE 'git checkout\s+(main|origin/\S+)\s+--\s'; then
  exit 0
fi

# git checkout main / git switch main を検出 → 常にブロック
if echo "$COMMAND" | grep -qE 'git (checkout|switch)\s+(-b\s+\S+\s+)?main'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "git checkout main は禁止です。新しいブランチが必要な場合は git worktree add -b <branch> .claude/worktrees/<name> main を使ってください。"
    }
  }'
  exit 0
fi

exit 0