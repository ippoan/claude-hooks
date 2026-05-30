#!/bin/bash
# PreToolUse hook: git push 前に PR が既に merged/closed でないか確認
#
# なぜ必要か:
#   auto-merge で PR が閉じられた後に push すると CI が走らない。
#   変更がデプロイされず、main との乖離に気づけない。
#   nuxt-notify PR#13 で実際に発生。

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# git push コマンドのみ対象
if ! echo "$COMMAND" | grep -qP '^(cd .* && )?git push\b'; then
  exit 0
fi

# ブランチ名を取得
BRANCH=$(cd "$CWD" && git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
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

# gh コマンドでリモートの PR 状態を確認
PR_STATE=$(cd "$CWD" && gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)

if [ "$PR_STATE" = "MERGED" ]; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "このブランチの PR は既に MERGED です。push しても CI が走りません。新しいブランチを作成してください。"
    }
  }'
  exit 0
fi

if [ "$PR_STATE" = "CLOSED" ]; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "このブランチの PR は既に CLOSED です。push しても CI が走りません。新しいブランチを作成してください。"
    }
  }'
  exit 0
fi

exit 0