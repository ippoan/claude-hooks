#!/bin/bash
# PreToolUse hook: pr-push.sh 起動時に repo が wt-direct-push allowlist に登録済みなら
# block して /wt-direct-push に誘導する。
#
# 背景:
#   ippoan/github-mcp-server-rs#28 で /pr-push を使った結果、PR merge 待ちの間に
#   /tag-release patch が走って古い main HEAD から release が build され、PR の changes
#   (relay 実装) が release から漏れる事故が発生。
#
#   direct-push allowlist 対象 repo (branch protection 無し / auto-merge 未設定) は
#   /wt-direct-push で fast-forward 直 push する方が事故も少なく速い。
#
# Detection:
#   - tool_input.command に `pr-push.sh` を含む
#   - tool_input.command (subshell や `&&` 連結を含む) を sourcing せず簡易 cwd 推定:
#     - command が `cd /path/to/repo &&` 形式なら cd 先を使う
#     - そうでなければ環境変数 PWD (= Bash tool の最終 cwd) を使う
#   - cwd の git remote から owner/name を取り出し allowlist 照合
#
# Allowlist source:
#   $HOME/.claude/skills/wt-direct-push/config/direct-push-ok.txt
#   (1 行 1 repo "owner/name", `#` でコメント, 空行 OK)

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# pr-push.sh 起動でなければ何もしない
if ! echo "$COMMAND" | grep -qE 'pr-push/scripts/pr-push\.sh|/pr-push '; then
  exit 0
fi

# allowlist file が無ければ skip (機能無効と同じ)
ALLOWLIST="$HOME/.claude/skills/wt-direct-push/config/direct-push-ok.txt"
[ -f "$ALLOWLIST" ] || exit 0

# cwd 推定:
# - "cd /abs/path && ..." or "cd /abs/path; ..." なら cd 先
# - それ以外は現在の PWD (Bash tool が tracking している cwd)
TARGET_CWD=""
# `cd /abs/path && ...` から /abs/path を抜く。grep が no-match でも fail させない。
CD_PATH=$(echo "$COMMAND" | grep -oE '^cd\s+["'\'']?[^&;"'\'' ]+' 2>/dev/null | head -1 | sed -E 's/^cd\s+["'\'']?//' || true)
if [ -n "$CD_PATH" ]; then
  TARGET_CWD="$CD_PATH"
elif [ -n "${PWD:-}" ]; then
  TARGET_CWD="$PWD"
fi
[ -n "$TARGET_CWD" ] || exit 0
[ -d "$TARGET_CWD" ] || exit 0

# git remote 取得 (失敗したら skip — non-git dir で pr-push が呼ばれるのは元々エラー)
REMOTE_URL=$(git -C "$TARGET_CWD" remote get-url origin 2>/dev/null || echo "")
[ -n "$REMOTE_URL" ] || exit 0

# owner/name 抽出: 対応 URL 形式
#   https://github.com/owner/name(.git)?
#   git@github.com:owner/name(.git)?
#   ssh://git@github.com/owner/name(.git)?
OWNER_NAME=$(echo "$REMOTE_URL" \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|^ssh://git@[^/]+/||; s|\.git$||')
# OWNER_NAME = "owner/name" 形式を期待
if ! echo "$OWNER_NAME" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
  exit 0
fi

# allowlist 照合 (コメント行・空行を除去)
if grep -vE '^\s*(#|$)' "$ALLOWLIST" | grep -qxF "$OWNER_NAME"; then
  jq -n --arg repo "$OWNER_NAME" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ($repo + " は wt-direct-push allowlist に登録済 (branch protection 無し / auto-merge 未設定)。\n/pr-push ではなく /wt-direct-push でコミット済み変更を main に fast-forward 直 push してください。\n\n背景: PR を作っても auto-merge 無しで塩漬けになり、その間に tag-release が古い main から build → release から changes が漏れる事故が起きます (ippoan/github-mcp-server-rs#28 参照)。\n\nどうしても PR にしたい正当な理由がある場合は、明示的にユーザに確認してから本 hook を bypass する方法を相談してください。")
    }
  }'
  exit 0
fi

exit 0
