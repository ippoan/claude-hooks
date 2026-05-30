#!/bin/bash
# マージ済み worktree を検出・削除するスクリプト
# 手動実行: bash ~/.claude/hooks/worktree-cleanup.sh
#
# リポジトリルートから実行すること

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$REPO_ROOT" ]; then
  echo "Error: git リポジトリ内で実行してください"
  exit 1
fi

WORKTREE_DIR="$REPO_ROOT/.claude/worktrees"
if [ ! -d "$WORKTREE_DIR" ]; then
  echo "worktree ディレクトリなし: $WORKTREE_DIR"
  exit 0
fi

# メインリポジトリルートに移動 (worktree 内から削除すると getcwd 失敗)
cd "$REPO_ROOT" || exit 1

CLEANED=0
SKIPPED=0

for wt_dir in "$WORKTREE_DIR"/*/; do
  [ -d "$wt_dir" ] || continue
  wt_name=$(basename "$wt_dir")

  # worktree のブランチ名を取得
  BRANCH=$(git -C "$wt_dir" branch --show-current 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    echo "SKIP: $wt_name (ブランチ不明)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # PR がマージ済みか確認
  MERGED_COUNT=$(gh pr list --head "$BRANCH" --state merged --json number --jq 'length' 2>/dev/null)
  if [ "$MERGED_COUNT" -gt 0 ] 2>/dev/null; then
    echo "REMOVE: $wt_name (branch: $BRANCH, merged)"
    git worktree remove "$WORKTREE_DIR/$wt_name" --force 2>/dev/null
    git branch -d "$BRANCH" 2>/dev/null
    CLEANED=$((CLEANED + 1))
  else
    # PR がクローズ済み (マージなし) か確認
    CLOSED_COUNT=$(gh pr list --head "$BRANCH" --state closed --json number --jq 'length' 2>/dev/null)
    if [ "$CLOSED_COUNT" -gt 0 ] 2>/dev/null; then
      echo "REMOVE: $wt_name (branch: $BRANCH, closed without merge)"
      git worktree remove "$WORKTREE_DIR/$wt_name" --force 2>/dev/null
      git branch -D "$BRANCH" 2>/dev/null
      CLEANED=$((CLEANED + 1))
    else
      echo "KEEP: $wt_name (branch: $BRANCH)"
      SKIPPED=$((SKIPPED + 1))
    fi
  fi
done

echo ""
echo "結果: ${CLEANED} 件削除, ${SKIPPED} 件残存"
