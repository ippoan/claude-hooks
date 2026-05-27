#!/bin/bash
# PostToolUse hook: `git push` 後に branch が origin/<default> より遅れていない
# か確認し、遅れていたら additionalContext で Claude に警告を返す。
#
# 解決すべき事故パターン (auth-worker PR #223 で発生):
#   1. branch X から PR #A を立て、merge (squash) される
#   2. main には PR #A の commit が積まれる、branch X には積まれない
#   3. branch X に commit を追加して PR #B を立てる → main 側で conflict
#
# 検出 (post-push の理由):
#   pre-push で block すると force-push の判定や force-with-lease の許容など
#   logic が増える。push 自体は通して直後に状態を確認 → conflict 兆候があれば
#   additionalContext で「次の PR 立てる前に rebase してね」と Claude に通知
#   する non-blocking 設計。
#
# 出力:
#   - hookSpecificOutput.additionalContext に警告メッセージ (Claude が読む)
#   - 終了コードは常に 0 (post-push は非ブロッキング)
#
# Triggers (settings.json `PostToolUse.matcher`):
#   - "Bash" のみ。`git push` 文字列マッチで filter。
set -u

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

# git push を含まないなら skip
if ! printf '%s' "$CMD" | grep -qP '(^|[;&|]\s*|&& |\|\| )git push\b'; then
  exit 0
fi

# git repo 内でなければ skip
cd "$CWD" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0
case "$BRANCH" in
  main|master) exit 0 ;;
esac

# Default branch を解決。origin/HEAD があればそれを使い、無ければ main を仮定。
BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/@@')
[ -z "$BASE" ] && BASE="origin/main"
BASE_SHORT="${BASE#origin/}"

# Fetch 失敗 (オフライン等) は黙って skip
git fetch origin "$BASE_SHORT" --quiet 2>/dev/null || exit 0

# BASE が HEAD の祖先なら up-to-date — 警告不要
if git merge-base --is-ancestor "$BASE" HEAD 2>/dev/null; then
  exit 0
fi

BEHIND=$(git rev-list --count "HEAD..$BASE" 2>/dev/null || echo "?")

# Claude が context に注入されたメッセージを読む
MSG="⚠️ branch '${BRANCH}' は ${BASE} より ${BEHIND} commit 遅れています (= 自分の branch から立てた PR が squash merge されて main に積まれた可能性)。次に PR を立てる前に rebase してください:
  git fetch origin ${BASE_SHORT}
  git rebase ${BASE}
  # または、PR ごとに branch を main 基準に reset する場合:
  #   git reset --hard ${BASE} && git cherry-pick <new-commit-shas>
  git push --force-with-lease
これを怠ると次の PR で main 側 conflict になります。"

jq -n --arg ctx "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
exit 0
