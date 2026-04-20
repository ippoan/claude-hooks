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

# git checkout -b xxx main (ローカル main から新規ブランチ作成) のみブロック
# 理由: ローカル main は古い可能性があるため origin/main を使うべき
if echo "$COMMAND" | grep -qE 'git (checkout|switch)\s+-b\s+\S+\s+main\b'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "ローカル main から新規ブランチを切るのは禁止です (古い可能性あり)。origin/main を使ってください: git worktree add -b <branch> .claude/worktrees/<name> origin/main"
    }
  }'
  exit 0
fi

# 素の git checkout main / git switch main は許可 (dev 起動時など)
exit 0