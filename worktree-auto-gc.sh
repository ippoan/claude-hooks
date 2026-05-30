#!/bin/bash
# PreToolUse: git worktree add 前にマージ済みworktreeを自動GC
# gh pr list で各ブランチのPR状態を確認し、MERGED/CLOSED なら削除

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# git worktree add 以外は通過
echo "$COMMAND" | grep -q 'git worktree add' || exit 0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
WT_DIR="$REPO_ROOT/.claude/worktrees"
[ -d "$WT_DIR" ] || exit 0

cd "$REPO_ROOT" || exit 0
CLEANED=0

for wt in "$WT_DIR"/*/; do
  [ -d "$wt" ] || continue
  BRANCH=$(git -C "$wt" branch --show-current 2>/dev/null)
  [ -z "$BRANCH" ] && continue

  # マージ済みPRがあれば削除
  MERGED=$(gh pr list --head "$BRANCH" --state merged --json number --jq 'length' 2>/dev/null)
  if [ "$MERGED" -gt 0 ] 2>/dev/null; then
    git worktree remove "$wt" --force 2>/dev/null
    git branch -d "$BRANCH" 2>/dev/null
    CLEANED=$((CLEANED + 1))
    continue
  fi

  # クローズ済み (マージなし) も削除
  CLOSED=$(gh pr list --head "$BRANCH" --state closed --json number --jq 'length' 2>/dev/null)
  if [ "$CLOSED" -gt 0 ] 2>/dev/null; then
    git worktree remove "$wt" --force 2>/dev/null
    git branch -D "$BRANCH" 2>/dev/null
    CLEANED=$((CLEANED + 1))
  fi
done

if [ "$CLEANED" -gt 0 ]; then
  jq -n --arg msg "Auto-GC: ${CLEANED} 件のマージ済み worktree を削除しました" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $msg
    }
  }'
fi

# 元の git worktree add は許可
exit 0
