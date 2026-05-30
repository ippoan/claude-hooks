#!/bin/bash
# PreToolUse hook: worktree / branch 作成コマンドの命名規則を機械的に検証する。
#
# 規約 (yhonda-ohishi/claude-skills#3):
#   形式: <issue-number>-<type>-<short-description>
#   type: feat | fix | refactor | infra (env で上書き可)
#   例: 123-fix-onedrive-token / 145-feat-line-works-webhook
#
# 検出する command (anchor 必須):
#   - git worktree add ... [-b] <branch>
#   - git checkout -b <branch>
#   - git switch -c <branch>
#
# 検証:
#   1. branch 名 regex (形式)
#   2. 先頭の <issue-number> が origin repo に実在する issue (closed 含む) — gh issue view
#
# 環境変数:
#   CLAUDE_HOOKS_BRANCH_TYPES   (CSV, default: feat,fix,refactor,infra)
#   CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1   (gh 障害時 / オフライン時の skip)
#
# 方針: fail-closed strict — gh 失敗 (network / 未認証 / repo 不在) は deny。
#       明示的に skip するには CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1 を export。
#
# 違反例 (deny):
#   git worktree add -b fix/onedrive ...        # issue 番号無し
#   git checkout -b 999999-feat-x               # issue 不在
#   git switch -c 1-typo-foo                    # type 不正
#
# 通過例 (allow):
#   git worktree add -b 2-feat-x .claude/worktrees/x origin/master  # 実在 issue
#   git commit -m "ref to git checkout -b 1-feat-x"                  # anchor 効果

set -euo pipefail

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')

# Bash 以外は通過
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // "."')

# --- anchor: 行頭 or shell separator 直後の command 開始位置だけ match ---
# (引数内文字列 / commit message を誤検出しないため、tag-release-userprompt-guard 同等)
ANCHOR='(^|[;&|][[:space:]]*)'

TYPES_CSV="${CLAUDE_HOOKS_BRANCH_TYPES:-feat,fix,refactor,infra}"
TYPES_ALT=$(echo "$TYPES_CSV" | tr ',' '|')
BRANCH_RE="^[0-9]+-(${TYPES_ALT})-[a-z0-9-]+$"

# --- 1. 対象 command から branch 名を抽出 ---
BRANCH=""
if echo "$CMD" | grep -qE "${ANCHOR}git[[:space:]]+worktree[[:space:]]+add\b"; then
  # -b <name> 指定があればそれを使う、なければ最後の引数 (attaching existing branch)
  if echo "$CMD" | grep -qE -- '-b[[:space:]]+[^ ]+'; then
    BRANCH=$(echo "$CMD" | grep -oE -- '-b[[:space:]]+[^ ]+' | head -1 | awk '{print $2}')
  else
    BRANCH=$(echo "$CMD" | awk '{print $NF}')
  fi
elif echo "$CMD" | grep -qE "${ANCHOR}git[[:space:]]+checkout[[:space:]]+-b\b"; then
  BRANCH=$(echo "$CMD" | sed -nE 's/.*checkout[[:space:]]+-b[[:space:]]+([^ ]+).*/\1/p')
elif echo "$CMD" | grep -qE "${ANCHOR}git[[:space:]]+switch[[:space:]]+-c\b"; then
  BRANCH=$(echo "$CMD" | sed -nE 's/.*switch[[:space:]]+-c[[:space:]]+([^ ]+).*/\1/p')
else
  # 対象外コマンド
  exit 0
fi

# 抽出失敗 (パース困難 / 想定外の形式) は他 hook の挙動を尊重して通す
if [[ -z "$BRANCH" ]]; then
  exit 0
fi

deny() {
  local reason="$1"
  jq -n --arg b "$BRANCH" --arg r "$reason" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": ("branch 名 " + $b + " : " + $r)
    }
  }'
  exit 0
}

# --- 2. 検証 1: 形式 (regex) ---
if ! [[ "$BRANCH" =~ $BRANCH_RE ]]; then
  deny "形式違反です。<issue-number>-<type>-<short-description> (type: ${TYPES_CSV}, short-description: [a-z0-9-]+)"
fi

# --- 3. 検証 2: issue 実在 (fail-closed) ---
if [[ "${CLAUDE_HOOKS_SKIP_ISSUE_CHECK:-0}" != "1" ]]; then
  ISSUE_NUM="${BRANCH%%-*}"

  # cwd の git remote から owner/repo を引く (HTTPS / SSH 両対応)
  REMOTE_URL=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
  REPO=$(echo "$REMOTE_URL" | sed -E 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?/?$#\2#')

  if [[ -z "$REPO" || "$REPO" == "$REMOTE_URL" ]]; then
    deny "origin remote が解決できません (cwd=${CWD}, url=${REMOTE_URL})。CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1 で回避可"
  fi

  if ! gh issue view "$ISSUE_NUM" --repo "$REPO" --json number >/dev/null 2>&1; then
    deny "#${ISSUE_NUM} が ${REPO} に実在しません (closed 含む / または gh API 失敗)。network 障害なら CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1 を export してから再実行してください"
  fi
fi

exit 0
