#!/bin/bash
# PreToolUse hook (matcher: mcp__github__create_pull_request)
#
# PR を issue に必ず紐付けさせる guard。ippoan の全 repo は PR ↔ issue を
# `Refs #N` (auto-close を避ける非 closing キーワード) で紐付ける運用。これが
# PR 本文に無いと:
#
#   - GitHub は closing keyword (Closes/Fixes/Resolves) でしか issue↔PR の
#     構造リンク (Development セクション / closingIssuesReferences) を作らない
#     ため、issue 側からその PR を辿れない。
#   - ci-dashboard の release-close 逆引き (tag→Refs) や /issues 追跡から漏れ、
#     「実装は終わってるのに open のまま放置」になる
#     (実例: ippoan/HealthConnectReader #14/#16/#18 — 解決 PR が merge & tag 済
#      なのに close 漏れ、#20/#21/#27 は別番号を Refs したため未紐付け)。
#
# 本 hook は create_pull_request 発火時に title+body を検査し、issue 参照が
# 無ければ deny する。issue を持たない PR は body に `[no-issue]` を入れて
# 明示 opt-out できる。
#
# 失敗時は fail-open (jq 不在 / parse 不能なら allow して PR 作成は止めない)。
set -u

INPUT=$(cat)

command -v jq >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
# matcher は exact だが念のため tool 名で絞る
case "$TOOL" in
  *create_pull_request) ;;
  *) exit 0 ;;
esac

TITLE=$(printf '%s' "$INPUT" | jq -r '.tool_input.title // ""' 2>/dev/null) || exit 0
BODY=$(printf '%s' "$INPUT" | jq -r '.tool_input.body // ""' 2>/dev/null) || exit 0
TEXT="${TITLE}
${BODY}"

# 明示 opt-out: issue を持たない PR
if printf '%s' "$TEXT" | grep -qiE '\[no-?issue\]|no-issue:'; then
  exit 0
fi

# issue 参照: <keyword> [owner/repo]#N  (ci-dashboard issue-prs.ts と同じ語彙)
REF_RE='(refs?|closes?|closed|fix(es|ed)?|resolves?|resolved|related to|part of)[[:space:]:]+([a-z0-9._/-]+)?#[0-9]+'
# 生の issue URL も許容
URL_RE='https?://github\.com/[a-z0-9._/-]+/issues/[0-9]+'

if printf '%s' "$TEXT" | grep -qiE "$REF_RE" \
   || printf '%s' "$TEXT" | grep -qiE "$URL_RE"; then
  exit 0
fi

jq -n '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "この PR は issue に紐付いていません。本文に `Refs #N` (推奨) / `Related to #N` / `Part of #N`、cross-repo なら `Refs owner/repo#N` を入れてください。\n\n理由: ippoan は auto-close を避けるため Closes/Fixes ではなく `Refs #N` で紐付ける運用です。これが無いと issue 側から PR を辿れず、ci-dashboard の release-close 逆引き / /issues 追跡から漏れます (実例: HealthConnectReader #14/#16/#18 の close 漏れ)。\n\nissue を持たない PR (純粋な chore 等) は本文に `[no-issue]` を入れて opt-out できます。"
  }
}'
exit 0
