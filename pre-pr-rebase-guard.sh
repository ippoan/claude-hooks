#!/bin/bash
# PreToolUse hook: `mcp__github__create_pull_request` で、head branch が
# origin/<base> より遅れている (out-of-date) 場合に PR 作成を deny する。
#
# 解決すべき事故パターン:
#   post-push-rebase-check.sh は `git push` 後の **非ブロッキング** 警告
#   ("origin/main より N commit 遅れています") だが、agent がそれを無視して
#   create_pull_request を呼び、GitHub 上で
#   "This branch is out-of-date with the base branch" な PR を作ってしまう
#   (= base が進んだ後の新 PR で頻発)。ここで PR 作成自体を block して
#   rebase を強制する blocking guard。
#
# 判定:
#   tool_input.{repo,head,base} を取り、ローカル pre-clone /home/user/<repo>
#   で head ref が origin/<base> の子孫か (= base を取り込み済みか) を確認。
#   取り込んでいない = behind なら deny。
#   誤 block を避けるため、以下は素通し (allow):
#     - tool が create_pull_request でない / repo・head が空
#     - ローカル pre-clone が無い / head ref がローカルに無い
#     - origin の fetch に失敗 (オフライン等)
#
# 出力:
#   behind: hookSpecificOutput.permissionDecision = "deny" + 理由 (rebase 手順)
#   それ以外: 何も出さず exit 0 (allow)
#
# Triggers (settings.json `PreToolUse.matcher`):
#   - "mcp__github__create_pull_request"
set -u

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"

# create_pull_request 系以外は素通し (matcher で絞っているが二重に確認)
case "$TOOL" in
  *create_pull_request) ;;
  *) exit 0 ;;
esac

REPO="$(printf '%s' "$INPUT" | jq -r '.tool_input.repo // ""')"
HEAD="$(printf '%s' "$INPUT" | jq -r '.tool_input.head // ""')"
BASE="$(printf '%s' "$INPUT" | jq -r '.tool_input.base // "main"')"
[ -z "$BASE" ] && BASE="main"

# repo / head が取れなければ判定不能 → 通す
[ -z "$REPO" ] && exit 0
[ -z "$HEAD" ] && exit 0

# ローカル pre-clone (CCoW は /home/user/<repo>)。owner 付きで来ても repo 名で引く。
DIR="/home/user/${REPO##*/}"
[ -d "${DIR}/.git" ] || exit 0
cd "$DIR" 2>/dev/null || exit 0

# head branch がローカルに無ければ判定不能 → 通す
git rev-parse --verify --quiet "refs/heads/${HEAD}" >/dev/null 2>&1 || exit 0

# base を fetch。失敗 (オフライン等) は誤 block を避けて通す。
git fetch origin "$BASE" --quiet 2>/dev/null || exit 0

# origin/<base> が head の祖先なら up-to-date → 通す
if git merge-base --is-ancestor "origin/${BASE}" "$HEAD" 2>/dev/null; then
  exit 0
fi

BEHIND=$(git rev-list --count "${HEAD}..origin/${BASE}" 2>/dev/null || echo "?")

REASON="❌ PR 作成を中止しました: branch '${HEAD}' は origin/${BASE} より ${BEHIND} commit 遅れています。このまま PR を作ると GitHub で 'This branch is out-of-date with the base branch' になります。

先に base を取り込んでください (cwd: ${DIR}):
  git fetch origin ${BASE}
  git rebase origin/${BASE}
  # PR ごとに branch を作り直す運用 (squash merge で branch 削除される repo) なら:
  #   git reset --hard origin/${BASE} && git cherry-pick <new-commit-shas>
  git push --force-with-lease
その後あらためて create_pull_request を実行してください。"

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
