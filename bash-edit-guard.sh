#!/bin/bash
# PreToolUse hook (Bash): sed -i 等でソースファイルを書き換えるコマンドをブロック
# worktree-edit-guard.sh と同じ保護リポジトリ・例外パターンを使用
# protected-repos.txt に登録されたリポジトリのメインワークツリーのみブロック

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""')

[ "$TOOL" != "Bash" ] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

# sed -i を含まないならスルー (最も一般的なケースのみ)
echo "$CMD" | grep -qE '\bsed\s+-[^[:space:]]*i\b' || exit 0

# sed -i コマンドからターゲットファイルを抽出
# sed -i 's/xxx/yyy/' file1 file2 ... → 最後のクォートされていない引数群がファイル
# 簡易実装: sed コマンド部分を抽出して最後の引数をファイルとみなす
TARGET_FILE=$(echo "$CMD" | sed -n "s/.*\bsed\s\+-[^ ]*i[^ ]*\s\+\('[^']*'\|\"[^\"]*\"\)\s\+//p" | awk '{print $NF}')

# フォールバック: sed -i の後ろの最後の引数
if [ -z "$TARGET_FILE" ]; then
  TARGET_FILE=$(echo "$CMD" | grep -oP '\bsed\s+-\S*i\S*\s+\S+\s+\K\S+$')
fi

[ -z "$TARGET_FILE" ] && exit 0

# パイプやリダイレクトの残骸を除去
TARGET_FILE=$(echo "$TARGET_FILE" | sed 's/[;&|].*$//')
[ -z "$TARGET_FILE" ] && exit 0

# cwd を考慮して絶対パスに変換
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
if [[ "$TARGET_FILE" != /* ]]; then
  TARGET_FILE="${CWD:-.}/$TARGET_FILE"
fi
TARGET_FILE=$(realpath -m "$TARGET_FILE" 2>/dev/null || echo "$TARGET_FILE")

# protected-repos.txt を読む
CONF="$HOME/.claude/protected-repos.txt"
[ -f "$CONF" ] || exit 0

MATCHED_REPO=""
while IFS= read -r repo_root; do
  [ -z "$repo_root" ] && continue
  if [[ "$TARGET_FILE" == "$repo_root/"* || "$TARGET_FILE" == "$repo_root" ]]; then
    MATCHED_REPO="$repo_root"
    break
  fi
done < "$CONF"

# 保護リポジトリに該当しない → 許可
[ -z "$MATCHED_REPO" ] && exit 0

# worktree 内 → 許可
if [[ "$TARGET_FILE" == *"/.claude/worktrees/"* ]]; then
  exit 0
fi

# 例外パターン判定
REL_PATH="${TARGET_FILE#$MATCHED_REPO/}"

case "$REL_PATH" in
  CLAUDE.md) exit 0 ;;
  .claude/*) exit 0 ;;
  .gitignore) exit 0 ;;
  docs/*) exit 0 ;;
  *.md) [[ "$REL_PATH" != */* ]] && exit 0 ;;
  coverage_100.toml) exit 0 ;;
  .github/*) exit 0 ;;
esac

# ブロック
jq -n --arg path "$TARGET_FILE" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("Bash (sed -i 等) でのソースファイル編集は禁止です。worktree で Edit ツールを使ってください:\n  git worktree add -b <branch> .claude/worktrees/<name> origin/main\n対象パス: " + $path)
  }
}'
exit 0
