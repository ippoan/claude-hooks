#!/bin/bash
# PostToolUse hook: git push 後に CI が起動したか確認
#
# なぜ必要か:
#   PR が既に merged/closed だと push しても CI が走らない。
#   変更がデプロイされず気づけない問題を防止。

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# git push コマンドのみ対象
if ! echo "$command" | grep -qP '(^|&& )git push\b'; then
  exit 0
fi

# ブランチ名を取得
BRANCH=$(cd "$cwd" && git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  exit 0
fi

# 少し待ってから CI 起動を確認
sleep 5

# PR の状態を確認
PR_STATE=$(cd "$cwd" && gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)

if [ "$PR_STATE" = "MERGED" ]; then
  jq -n --arg ctx "⚠️ このブランチの PR は既に MERGED です。push した変更に対して CI は走りません。新しいブランチを作成してください。" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
  exit 0
fi

if [ "$PR_STATE" = "CLOSED" ]; then
  jq -n --arg ctx "⚠️ このブランチの PR は CLOSED です。push した変更に対して CI は走りません。" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
  exit 0
fi

# CI run が起動したか確認 (run_id + status を取得)
RUN_INFO=$(cd "$cwd" && gh run list --branch "$BRANCH" --limit 1 --json databaseId,status --jq '.[0] | "\(.databaseId) \(.status)"' 2>/dev/null)
RUN_ID=$(echo "$RUN_INFO" | awk '{print $1}')
RUN_STATUS=$(echo "$RUN_INFO" | awk '{print $2}')

if [ -z "$RUN_ID" ]; then
  jq -n --arg ctx "⚠️ push 後に CI run が検出されません。workflow trigger を確認してください。" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
  exit 0
fi

# CI が進行中/待機中なら watch 指示を含める
if [ "$RUN_STATUS" = "in_progress" ] || [ "$RUN_STATUS" = "queued" ] || [ "$RUN_STATUS" = "waiting" ]; then
  jq -n --arg ctx "✓ CI 起動確認: $RUN_STATUS (branch: $BRANCH, PR: $PR_STATE, run: $RUN_ID)
→ バックグラウンドで \`gh run watch $RUN_ID --exit-status\` を実行して CI 完了を監視してください (run_in_background: true)。" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
else
  jq -n --arg ctx "✓ CI 確認: $RUN_STATUS (branch: $BRANCH, PR: $PR_STATE, run: $RUN_ID)" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
fi
exit 0