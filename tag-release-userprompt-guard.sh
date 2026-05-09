#!/bin/bash
# PreToolUse hook: /tag-release skill / tag-release.sh / `git tag v*` を
# Claude が autonomous に呼ぶのをブロック。
# 直近のユーザー prompt に `/tag-release` slash command が含まれている時のみ通す。
#
# 違反例:
#   - ユーザー指示なしに Claude が「Step 4 で /tag-release patch」と判断して呼ぶ
#   - PR merge 後の流れで Claude が自動で git tag + push する
#
# 通過例:
#   - ユーザーが入力欄に `/tag-release patch` を打ったあと、Claude が同じ ターン内で実行
#   - ユーザーが「/tag-release minor」と書いた直後の処理

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""')

# --- 1. tag-release を呼ぶ操作かどうか判定 ---
INVOKES=false
case "$TOOL_NAME" in
  Bash)
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    # tag-release.sh スクリプト直接呼び
    if echo "$CMD" | grep -qE 'tag-release\.sh\b'; then
      INVOKES=true
    fi
    # git tag -a v1.2.3 形式 (新規セマンティックバージョン tag)
    if echo "$CMD" | grep -qE 'git tag (-[afsm][^ ]* )*v[0-9]+\.[0-9]+\.[0-9]+'; then
      INVOKES=true
    fi
    # git push origin v* (tag push)
    if echo "$CMD" | grep -qE 'git push [^ ]+ v[0-9]+\.[0-9]+\.[0-9]+'; then
      INVOKES=true
    fi
    ;;
  Skill)
    SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // ""')
    if [[ "$SKILL" == "tag-release" ]]; then
      INVOKES=true
    fi
    ;;
esac

if [[ "$INVOKES" != "true" ]]; then
  exit 0
fi

# --- 2. 直近ユーザー prompt に /tag-release が含まれてるか確認 ---
ALLOW=false
if [[ -n "$TRANSCRIPT_PATH" && -f "$TRANSCRIPT_PATH" ]]; then
  # 最後の user 型エントリを取得 (tool_result も user 型なので最後の "本物" を探す)
  # 安全側: 直近 5 件の user 型から /tag-release 出現を見る
  RECENT_USER_TEXT=$(jq -rc '
    select(.type == "user")
    | .message.content
    | if type == "string" then .
      elif type == "array" then [.[] | .text // ""] | join(" ")
      else ""
      end
  ' "$TRANSCRIPT_PATH" 2>/dev/null | tail -5 | tr '\n' ' ' || echo "")

  # 1) スラッシュコマンド (/tag-release) または
  # 2) <command-name>tag-release</command-name> (UI 経由 inject)
  if echo "$RECENT_USER_TEXT" | grep -qE '(^|[^a-zA-Z0-9_-])/tag-release([^a-zA-Z0-9_-]|$)'; then
    ALLOW=true
  elif echo "$RECENT_USER_TEXT" | grep -qE '<command-name>tag-release</command-name>'; then
    ALLOW=true
  fi
fi

if [[ "$ALLOW" == "true" ]]; then
  exit 0
fi

# --- 3. block ---
jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "tag-release は ユーザーが直接 `/tag-release` を入力した時のみ実行できます。Claude が自発的に判断して打つのは禁止 (本番デプロイ事故防止)。タグを打ちたい場合はユーザーに「/tag-release patch を実行してください」と依頼してください。"
  }
}'
exit 0
