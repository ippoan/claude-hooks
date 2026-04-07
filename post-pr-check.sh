#!/bin/bash
# PostToolUse hook: gh pr create 後に conflict + CI 起動を自動チェック
# settings.json の PostToolUse に登録して使う

# stdin から tool result を読む
INPUT=$(cat)

# gh pr create の出力かチェック (PR URL が含まれる)
PR_URL=$(echo "$INPUT" | grep -oP 'https://github\.com/[^/]+/[^/]+/pull/\d+' | head -1)
if [ -z "$PR_URL" ]; then
  exit 0
fi

# repo と PR number を抽出
REPO=$(echo "$PR_URL" | grep -oP '[^/]+/[^/]+(?=/pull)')
PR_NUM=$(echo "$PR_URL" | grep -oP '\d+$')

sleep 3  # GitHub API に反映されるまで少し待つ

# 0. Branch protection 自動登録 → protected-repos.txt
PROTECTED=$(gh api "repos/$REPO/branches/main" --jq '.protected' 2>/dev/null)
if [ "$PROTECTED" = "true" ]; then
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$REPO_ROOT" ]; then
    CONF="$HOME/.claude/protected-repos.txt"
    touch "$CONF"
    grep -qxF "$REPO_ROOT" "$CONF" || echo "$REPO_ROOT" >> "$CONF"
  fi
fi

# 1. Conflict チェック
MERGEABLE=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null)
if [ "$MERGEABLE" = "CONFLICTING" ]; then
  echo "⚠️ PR #$PR_NUM has merge conflicts. Rebase needed before CI can run."
  exit 0
fi

# 2. CI 起動チェック
sleep 5
RUNS=$(gh run list --repo "$REPO" --branch "$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null)" --limit 1 --json status,createdAt --jq '.[0].status' 2>/dev/null)
if [ -z "$RUNS" ]; then
  echo "⚠️ PR #$PR_NUM: No CI run detected. Check workflow triggers."
fi

exit 0