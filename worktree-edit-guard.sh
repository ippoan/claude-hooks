#!/bin/bash
# PreToolUse hook: Write/Edit で保護リポジトリのメインワークツリー編集をブロック
# worktree (.claude/worktrees/) 内の編集は許可
# CLAUDE.md, .claude/*, docs/*, .gitignore 等のメタファイルは例外
#
# protected-repos.txt に登録されたリポジトリのみ対象
# GitHub API 呼び出しなし (高速)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# file_path が空なら通過
[ -z "$FILE_PATH" ] && exit 0

# realpath で正規化 (シンボリックリンク対策)
FILE_PATH=$(realpath -m "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# protected-repos.txt を読む
CONF="$HOME/.claude/protected-repos.txt"
[ -f "$CONF" ] || exit 0

MATCHED_REPO=""
while IFS= read -r repo_root; do
  [ -z "$repo_root" ] && continue
  # file_path がこのリポジトリ配下か判定
  if [[ "$FILE_PATH" == "$repo_root/"* || "$FILE_PATH" == "$repo_root" ]]; then
    MATCHED_REPO="$repo_root"
    break
  fi
done < "$CONF"

# 保護リポジトリに該当しない → 許可
[ -z "$MATCHED_REPO" ] && exit 0

# worktree 内 (.claude/worktrees/) → 許可
if [[ "$FILE_PATH" == *"/.claude/worktrees/"* ]]; then
  exit 0
fi

# 例外パターン判定 (メインワークツリーでも編集可)
REL_PATH="${FILE_PATH#$MATCHED_REPO/}"

case "$REL_PATH" in
  # CLAUDE.md (ルート)
  CLAUDE.md) exit 0 ;;
  # .claude/ 配下すべて (plans, memory, hooks, skills, settings)
  .claude/*) exit 0 ;;
  # .gitignore
  .gitignore) exit 0 ;;
  # docs/ 配下
  docs/*) exit 0 ;;
  # ルート直下の .md ファイル (README, CHANGELOG 等)
  *.md) [[ "$REL_PATH" != */* ]] && exit 0 ;;
  # coverage_100.toml (CI 設定)
  coverage_100.toml) exit 0 ;;
  # .github/ 配下 (CI ワークフロー等)
  .github/*) exit 0 ;;
esac

# .gitignore で無視されるファイルは編集許可 (mail/, spec/ などの作業用ローカル領域)
if (cd "$MATCHED_REPO" && git check-ignore -q "$REL_PATH" 2>/dev/null); then
  exit 0
fi

# ブロック
jq -n --arg path "$FILE_PATH" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("メインワークツリーのソースファイル編集は禁止です。worktree で作業してください:\n  git fetch origin main\n  git worktree add -b <branch> .claude/worktrees/<name> origin/main\n対象パス: " + $path)
  }
}'
exit 0
