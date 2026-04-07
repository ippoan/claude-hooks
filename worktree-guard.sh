#!/bin/bash
# PreToolUse hook: git worktree remove が安全に実行されるようガードする
# 問題: cwd が worktree 内だと remove 後に getcwd が失敗しセッション切断される
# 対策: cwd が .claude/worktrees/ 内ならブロック。それ以外は許可。

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# git worktree remove 以外は通過
if ! echo "$COMMAND" | grep -q 'git worktree remove'; then
  exit 0
fi

# cwd が worktree 内ならブロック
if echo "$CWD" | grep -q '\.claude/worktrees/'; then
  jq -n --arg cwd "$CWD" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("cwd が " + $cwd + " です。worktree 外に cd してから git worktree remove を実行してください")
    }
  }'
  exit 0
fi

# コマンド内で worktree に cd してから remove していないか確認
if echo "$COMMAND" | grep -q 'cd.*\.claude/worktrees/'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "worktree 内に cd してから remove しないでください。cd なしで git worktree remove を実行してください"
    }
  }'
  exit 0
fi

# それ以外は許可
exit 0