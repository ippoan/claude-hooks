#!/bin/bash
# PreToolUse hook: `git push` が CCoW local proxy 経由でない remote を叩こうとした
# ときに、proxy が 502 / git 自体が credential 不足で fail する前に deny し、
# agent に「pre-clone を使え or scope を確認しろ」と差し戻す guard。
#
# 背景:
#   CCoW 環境は MCP scope 内の repo を `/home/user/<name>/` に pre-clone し、
#   credential 付き proxy remote (`http://local_proxy@127.0.0.1:NNNN/git/<owner>/<repo>`)
#   を origin に焼く。Agent が誤って `git clone https://github.com/...` で別途
#   clone し、そこから push しようとすると 2 通りで fail:
#
#     1. remote URL が plain HTTPS (= proxy 経由でない)
#        → `fatal: could not read Username for 'https://github.com'`
#     2. remote URL が proxy 経由だが repo が proxy allowlist (= MCP scope) 外
#        → `remote: Proxy error: repository not authorized` / HTTP 502
#
#   どちらも事前 detect 可能なので、push 試行段階で止めて agent に修復路を渡す。
#
# Detection:
#   - tool_input.command が `git push` を含む
#   - cwd 推定 (`cd /abs/path && ...` prefix → cd 先、無ければ $PWD)
#   - `git -C <cwd> remote get-url origin` で remote URL 取得
#   - URL pattern が `local_proxy@127.0.0.1:` を含むか
#     - 含まない → mode 1 確定で deny
#     - 含む → mode 2 の可能性あるが proxy allowlist は container 内から読めないので
#              pass through (push が走って proxy 側で fail させる = error message が
#              明確、ここで先回り deny すると false positive 増える)
#
# Pass-through cases (NOT blocked):
#   - `git push` 含まない command (fast-path)
#   - cwd が非 git directory (remote get-url が fail → そのまま push が普通に fail する)
#   - origin remote 自体が無い repo (新規 init 直後など) → push 側が error 出す
#   - remote URL が `local_proxy@127.0.0.1:*` を含む (= proxy 経由、scope 内想定)
#
# Trigger: PreToolUse with matcher "Bash".

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Fast-path: command doesn't contain `git push` at all.
if ! echo "$COMMAND" | grep -qE '(^|[[:space:]&;|(])git[[:space:]]+push\b'; then
  exit 0
fi

# cwd 推定:
#   - `cd /abs/path && git push ...` → /abs/path
#   - 単体 `git push` → $PWD (Bash tool tracking cwd)
TARGET_CWD=""
CD_PATH=$(echo "$COMMAND" | grep -oE '^cd\s+["'\'']?[^&;"'\'' ]+' 2>/dev/null | head -1 | sed -E 's/^cd\s+["'\'']?//' || true)
if [ -n "$CD_PATH" ]; then
  TARGET_CWD="$CD_PATH"
elif [ -n "${PWD:-}" ]; then
  TARGET_CWD="$PWD"
fi
[ -n "$TARGET_CWD" ] || exit 0
[ -d "$TARGET_CWD" ] || exit 0

# git remote 取得 (失敗 = 非 git dir or origin 未設定 → pass-through、git push 側が error 出す)
REMOTE_URL=$(git -C "$TARGET_CWD" remote get-url origin 2>/dev/null || echo "")
[ -n "$REMOTE_URL" ] || exit 0

# proxy URL 判定: `local_proxy@127.0.0.1:<port>` を含むなら scope 内想定
if echo "$REMOTE_URL" | grep -q 'local_proxy@127\.0\.0\.1:'; then
  # mode 2 (proxy 経由だが allowlist 外) は container 内から判断できないので
  # pass through。proxy 側の 502 error message のほうが原因明確。
  exit 0
fi

# ─── ここまで来たら mode 1 確定: plain HTTPS or その他 non-proxy remote ───────

# owner/name 抽出 (suggestion message 用):
#   https://github.com/owner/name(.git)?
#   git@github.com:owner/name(.git)?
#   ssh://git@github.com/owner/name(.git)?
OWNER_NAME=$(echo "$REMOTE_URL" \
  | sed -E 's|^https?://[^/]+/||; s|^git@[^:]+:||; s|^ssh://git@[^/]+/||; s|\.git$||' \
  | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || echo "")

REPO_NAME=""
if [ -n "$OWNER_NAME" ]; then
  REPO_NAME=$(echo "$OWNER_NAME" | awk -F/ '{print $2}')
fi

# pre-clone 候補:
#   1. /home/user/<repo_name>/      (top-level pre-clone)
#   2. /home/user/<repo_name>/.git/ 確認で proxy URL が焼かれているか
PRE_CLONE_DIR=""
PRE_CLONE_HAS_PROXY=""
if [ -n "$REPO_NAME" ] && [ -d "/home/user/${REPO_NAME}/.git" ]; then
  PRE_CLONE_DIR="/home/user/${REPO_NAME}"
  PRE_REMOTE=$(git -C "$PRE_CLONE_DIR" remote get-url origin 2>/dev/null || echo "")
  if echo "$PRE_REMOTE" | grep -q 'local_proxy@127\.0\.0\.1:'; then
    PRE_CLONE_HAS_PROXY="yes"
  fi
fi

# Deny message を組み立て。reason に応じて 3 path 提示:
#   A) pre-clone がある & proxy URL 焼かれている → cd して再 push
#   B) pre-clone は無いが repo 名は分かる → user 確認 (scope 追加 or open-multirepo)
#   C) URL parse 失敗等 → 一般的な note
REASON=""
if [ "$PRE_CLONE_HAS_PROXY" = "yes" ]; then
  REASON=$(cat <<EOF
\`git push\` を試行した cwd ($TARGET_CWD) の origin URL は CCoW local proxy 経由ではありません:

  $REMOTE_URL

このまま push すると \`fatal: could not read Username for 'https://github.com'\` で fail します。

✓ 同じ repo の credential 付き pre-clone が存在します: $PRE_CLONE_DIR

修復:
  cd $PRE_CLONE_DIR
  # branch / commit を pre-clone 側に持って行く (cherry-pick or rebase)
  git push -u origin <branch>

現在の $TARGET_CWD はそのままだと push できないので捨てて pre-clone 側で作業してください。
EOF
)
elif [ -n "$OWNER_NAME" ]; then
  REASON=$(cat <<EOF
\`git push\` を試行した cwd ($TARGET_CWD) の origin URL は CCoW local proxy 経由ではありません:

  $REMOTE_URL

このまま push すると \`fatal: could not read Username for 'https://github.com'\` で fail します。

$OWNER_NAME に対応する pre-clone が /home/user/${REPO_NAME}/ には無いため、この repo はおそらく **本 session の MCP scope 外** です。

⚠ AskUserQuestion で user に確認してから次の手を選んでください:
  1. user が scope を追加できる → 新規 session 起動 (open-multirepo skill) して MCP scope に含めた状態で再開
  2. 同 owner の他 repo の monorepo に統合済みかも (例: ref-files-mcp-server-rs は ippoan/mcp-relay-rs/binaries/ 配下に移動済) — 別 path を探す
  3. 該当 PR を user 自身に手動で投げてもらう

local clone を消して別 session に handover するのが普通の修復路です。
EOF
)
else
  REASON=$(cat <<EOF
\`git push\` を試行した cwd ($TARGET_CWD) の origin URL は CCoW local proxy 経由ではありません:

  $REMOTE_URL

このまま push すると credential 不足で fail します。URL 形式が認識できないため自動 suggestion はできません。

⚠ AskUserQuestion で user に確認してから次の手を判断してください (scope 追加 or 別 session or 手動 push)。
EOF
)
fi

jq -n --arg reason "$REASON" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": $reason
  }
}'
exit 0
