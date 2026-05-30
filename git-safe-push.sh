#!/bin/bash
# PreToolUse hook: git commit --amend / git push --force をブロック
#
# なぜダメか:
#   1. PR ブランチで amend → force push すると、CI が古い SHA で走る場合がある
#   2. auto-merge が古い SHA の CI 結果で squash merge し、最新の変更が main に入らない
#   3. 実際に nuxt-notify PR#12 で発生: amend 後の変更 (LINE Login 状態表示) が
#      main に含まれず、staging デプロイも古いコードになった
#
# 対策:
#   amend せず新しいコミットを追加 → 通常の git push
#   squash merge で最終的に1コミットになるので、コミット数を気にする必要なし

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# git commit --amend をブロック
if echo "$COMMAND" | grep -qP 'git commit\b.*--amend'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "git commit --amend は禁止です。新しいコミットを作成してください。amend + force push すると CI が古い SHA で走り、auto-merge で変更が漏れます。squash merge するのでコミット数は気にしないでください。"
    }
  }'
  exit 0
fi

# git push --force / --force-with-lease をブロック
if echo "$COMMAND" | grep -qP 'git push\b.*--(force|force-with-lease)'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "git push --force は禁止です。force push すると CI/auto-merge が古いコミットを参照し、最新の変更が main に入りません。新しいコミットを追加して通常の git push を使ってください。"
    }
  }'
  exit 0
fi

# git push -f をブロック (短縮フラグ)
if echo "$COMMAND" | grep -qP 'git push\b.* -[a-zA-Z]*f'; then
  jq -n '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "git push -f は禁止です。force push すると CI/auto-merge が古いコミットを参照し、最新の変更が main に入りません。新しいコミットを追加して通常の git push を使ってください。"
    }
  }'
  exit 0
fi

exit 0