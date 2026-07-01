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
# 本 hook は create_pull_request 発火時に検査し、issue 参照が無ければ deny する。
# issue を持たない PR は title/body に `[no-issue]` を入れて明示 opt-out できる。
#
# issue 参照は **PR title** に必須 (body だけでは不可)。理由: squash-merge の
# commit subject は必ず PR title になる。`Refs #N` を body だけに書くと、repo の
# squash 設定次第で commit message から `Refs` が落ち、ci-dashboard の
# tag→Refs 逆引き (tagged commit の message を走査) から漏れて「実装済みなのに
# 紐づかず open 放置」になる (実例: auth-worker #315 = body のみ Refs)。title に
# 入れれば commit subject に必ず載り逆引きが漏れない。
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

# 明示 opt-out: issue を持たない PR (title/body どちらでも可)
if printf '%s\n%s' "$TITLE" "$BODY" | grep -qiE '\[no-?issue\]|no-issue:'; then
  exit 0
fi

# issue 参照: <keyword> [owner/repo]#N  (ci-dashboard issue-prs.ts と同じ語彙)
REF_RE='(refs?|closes?|closed|fix(es|ed)?|resolves?|resolved|related to|part of)[[:space:]:]+([a-z0-9._/-]+)?#[0-9]+'
# 生の issue URL も許容
URL_RE='https?://github\.com/[a-z0-9._/-]+/issues/[0-9]+'

# 参照は **title** に必須 (body だけでは不可)。squash-merge の commit subject に
# 必ず載せて ci-dashboard の tag→Refs 逆引きが漏れないようにするため。
if printf '%s' "$TITLE" | grep -qiE "$REF_RE" \
   || printf '%s' "$TITLE" | grep -qiE "$URL_RE"; then
  exit 0
fi

# body には参照があるが title に無いケースは、原因を具体的に示して deny する。
BODY_HAS_REF=""
if printf '%s' "$BODY" | grep -qiE "$REF_RE" \
   || printf '%s' "$BODY" | grep -qiE "$URL_RE"; then
  BODY_HAS_REF="\n\n※ body には issue 参照がありますが **title** にありません。body だけの \`Refs\` は squash-merge の commit subject に載らず、ci-dashboard の tag→Refs 逆引きから漏れます。title の末尾に \`(Refs #N)\` を足してください。"
fi

jq -n --arg extra "$BODY_HAS_REF" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("この PR は issue に紐付いていません。**PR title** に `Refs #N` (推奨) / `Related to #N` / `Part of #N`、cross-repo なら `Refs owner/repo#N` を入れてください (例: `fix(auth): … (Refs #302)`)。\n\n理由: ippoan は auto-close を避けるため Closes/Fixes ではなく `Refs #N` で紐付ける運用です。GitHub は Closes 系でしか Development リンクを作らないため、紐付けは ci-dashboard の tag→Refs 逆引き (tagged commit の message 走査) が担います。squash-merge の commit subject は必ず PR title になるので、title に Refs を入れないと逆引きから漏れます (実例: auth-worker#315 は body のみ Refs で紐付かず、HealthConnectReader#14/#16/#18 は close 漏れ)。\n\nissue を持たない PR (純粋な chore 等) は title/body に `[no-issue]` を入れて opt-out できます。" + $extra)
  }
}'
exit 0
