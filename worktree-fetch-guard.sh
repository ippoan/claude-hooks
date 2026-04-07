#!/bin/bash
# PreToolUse hook: git worktree add 時に origin/main が最新か確認
# ローカル main が古いと worktree にマージ済みの変更が含まれない
#
# ブロック対象:
#   git worktree add ... main  (ローカル main をベースにした場合)
# 許可:
#   git worktree add ... origin/main (リモート参照)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# git worktree add 以外は通過
if ! echo "$COMMAND" | grep -q 'git worktree add'; then
  exit 0
fi

# origin/main をベースにしている場合は OK
if echo "$COMMAND" | grep -qE 'origin/main'; then
  exit 0
fi

# ローカル main をベースにしている場合
if echo "$COMMAND" | grep -qE '\bmain\b'; then
  # fetch 済みか確認 (ローカル main と origin/main の差分)
  BEHIND=$(cd "$CWD" && git rev-list --count main..origin/main 2>/dev/null)
  if [ -z "$BEHIND" ] || [ "$BEHIND" -gt 0 ]; then
    jq -n --arg behind "${BEHIND:-unknown}" '{
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": ("ローカル main が origin/main より " + $behind + " コミット遅れています。git worktree add -b <branch> <path> origin/main を使うか、先に git fetch origin main を実行してください。")
      }
    }'
    exit 0
  fi
fi

exit 0