#!/bin/bash
# PreToolUse hook (matcher: mcp__github__create_pull_request)
#
# ippoan/ohishi-exp org の全 repo は ci-dashboard `/ci-matrix` へ workflow shape
# を報告する `ci-shape-report.yml` caller を持つ規約 (Refs ippoan/ci-dashboard#393)。
# ci-dashboard 側は caller 未導入 repo を一覧から silent に除外するだけで気付け
# ないため (= 発覚が issue #393 のロールアウト漏れ調査まで遅延した実例)、PR 作成
# 時点で loud に deny する。
#
# ippoan/ci-workflows#164 で skills-check reusable にも同趣旨の ci-shape-check
# job (CI 側、無条件 fail) を追加済み。本 hook はそれより手前 (ローカル / PR 作成
# 前) で同じ欠落を検知する二重の網。
#
# 判定:
#   owner が ippoan / ohishi-exp のときだけ有効 (yhonda-ohishi 等は対象外)。
#   tool_input.repo からローカル pre-clone (/home/user/<repo>) を引き、
#   tool_input.head ref の中身を `git show` で見て
#     .github/workflows/ci-shape-report.yml
#     .github/workflows/ci-shape-report-self.yml (ci-workflows 自身の別名 caller)
#   のどちらかが存在し、reusable を実際に呼んでいるかを検査する。
#
# 誤 block を避けるため、以下は素通し (allow):
#   - tool が create_pull_request でない / owner・repo・head が空
#   - owner が ippoan/ohishi-exp 以外
#   - title/body に `[no-ci-shape]` (明示 opt-out)
#   - ローカル pre-clone が無い / head ref がローカルに無い (判定不能)
#
# Triggers (settings.json `PreToolUse.matcher`):
#   - "mcp__github__create_pull_request"
set -u

INPUT="$(cat)"
TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0

case "$TOOL" in
  *create_pull_request) ;;
  *) exit 0 ;;
esac

OWNER="$(printf '%s' "$INPUT" | jq -r '.tool_input.owner // ""' 2>/dev/null)"
REPO="$(printf '%s' "$INPUT" | jq -r '.tool_input.repo // ""' 2>/dev/null)"
HEAD="$(printf '%s' "$INPUT" | jq -r '.tool_input.head // ""' 2>/dev/null)"
TITLE="$(printf '%s' "$INPUT" | jq -r '.tool_input.title // ""' 2>/dev/null)"
BODY="$(printf '%s' "$INPUT" | jq -r '.tool_input.body // ""' 2>/dev/null)"

[ -z "$OWNER" ] && exit 0
[ -z "$REPO" ] && exit 0
[ -z "$HEAD" ] && exit 0

case "$OWNER" in
  ippoan|ohishi-exp) ;;
  *) exit 0 ;;
esac

# 明示 opt-out
if printf '%s\n%s' "$TITLE" "$BODY" | grep -qiE '\[no-ci-shape\]'; then
  exit 0
fi

# ローカル pre-clone (CCoW は /home/user/<repo>)。owner 付きで来ても repo 名で引く。
DIR="/home/user/${REPO##*/}"
[ -d "${DIR}/.git" ] || exit 0
cd "$DIR" 2>/dev/null || exit 0

# head branch がローカルに無ければ判定不能 → 通す
git rev-parse --verify --quiet "refs/heads/${HEAD}" >/dev/null 2>&1 || exit 0

REUSABLE_MARK="ippoan/ci-workflows/.github/workflows/ci-shape-report.yml"
FOUND=""
for path in ".github/workflows/ci-shape-report.yml" ".github/workflows/ci-shape-report-self.yml"; do
  content="$(git show "${HEAD}:${path}" 2>/dev/null)" || continue
  if printf '%s' "$content" | grep -qF "$REUSABLE_MARK"; then
    FOUND="$path"
    break
  fi
done

[ -n "$FOUND" ] && exit 0

REASON="❌ PR 作成を中止しました: '${OWNER}/${REPO}' の branch '${HEAD}' に ci-shape-report.yml caller がありません (or reusable を呼んでいません)。

ippoan/ohishi-exp org の全 repo は ci-dashboard \`/ci-matrix\` への workflow shape 報告 caller を持つ規約です (Refs ippoan/ci-dashboard#393)。欠落したままだと ci-dashboard の集計対象から silent に漏れます。

.github/workflows/ci-shape-report.yml に以下を追加してください:

  name: ci-shape-report
  on:
    push:
      branches: [main]
      paths: ['.github/workflows/**']
    pull_request:
      branches: [main]
      paths: ['.github/workflows/**']
  permissions:
    contents: read
  jobs:
    report:
      uses: ippoan/ci-workflows/.github/workflows/ci-shape-report.yml@main
      secrets: inherit

cross-org (ohishi-exp) は secrets: inherit の代わりに:
      secrets:
        RELEASE_WAVE_WEBHOOK_SECRET: \${{ secrets.RELEASE_WAVE_WEBHOOK_SECRET }}

意図的に不要な repo (空 repo 等) は title/body に '[no-ci-shape]' を入れて opt-out できます。"

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
