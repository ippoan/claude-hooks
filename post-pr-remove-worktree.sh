#!/bin/bash
# PostToolUse: PR作成成功時にworktreeを即削除
# コードはリモートブランチにある → ローカルworktreeは不要
# CI失敗時は origin/fix/xxx から新worktreeを作成して復元可能

INPUT=$(cat)
STDOUT=$(echo "$INPUT" | jq -r '.tool_result.stdout // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# PR URL が出力に含まれるか
PR_URL=$(echo "$STDOUT" | grep -oP 'https://github\.com/[^/]+/[^/]+/pull/\d+' | head -1)
[ -z "$PR_URL" ] && exit 0

# CWD が worktree 内か
[[ "$CWD" != */.claude/worktrees/* ]] && exit 0

# worktree ルートとブランチを取得
WT_ROOT=$(echo "$CWD" | sed 's|\(.*\.claude/worktrees/[^/]*\).*|\1|')
BRANCH=$(git -C "$WT_ROOT" branch --show-current 2>/dev/null)
MAIN_ROOT=$(git -C "$WT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')
[ -z "$MAIN_ROOT" ] && exit 0

# メインリポジトリルートからworktree削除
cd "$MAIN_ROOT" 2>/dev/null || exit 0
git worktree remove "$WT_ROOT" --force 2>/dev/null
[ -n "$BRANCH" ] && git branch -d "$BRANCH" 2>/dev/null

jq -n --arg main "$MAIN_ROOT" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("PR 作成済み。worktree を削除しました。cd " + $main + " でメインリポジトリに戻ってください。")
  }
}'
