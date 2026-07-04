#!/bin/bash
# PostToolUse hook: `git push` 後、repo が Cloudflare Workers Builds の
# branch preview (push トリガー自動 build) を有効化していれば、その
# preview URL を組み立てて Claude に知らせる。
#
# 背景 (ippoan/secrets-inventory#85 の検討過程で確定した設計):
#   CCoW から front (Nuxt/Cloudflare Workers) の変更をプレビューしたいが、
#   CCoW は wrangler 用の CF API Token を持たない/持たせたくない。
#   Cloudflare 純正の Workers Builds (git 連携 CI/CD) を使えば、CCoW は
#   `git push` するだけで Cloudflare 側が自動 build/deploy し、
#   `<branch>-<worker-name>.<subdomain>.workers.dev` という決定論的な
#   URL で preview URL が生成される (CF トークン不要)。
#
# marker: 対象 repo が Workers Builds を有効化しているかは wrangler
# 設定ファイルに残らない (dashboard 側の GitHub 連携設定のため)。なので
# 明示的な marker コメントを wrangler.toml / wrangler.jsonc に置く運用にする:
#
#   # claude-hooks:workers-builds-preview=enabled   (wrangler.toml)
#   // claude-hooks:workers-builds-preview=enabled  (wrangler.jsonc)
#
# marker が無い repo では何もしない (silent exit)。
#
# 注意:
#   - branch 名の sanitize (lowercase化 + 非英数字を hyphen) は Cloudflare
#     の公開仕様どおりに実装しているが、63文字を超える場合は 4 文字ハッシュが
#     付与される仕様で、そのハッシュアルゴリズムは非公開のため正確な URL を
#     計算できない。63文字超は「dashboard で確認してください」に倒す。
#   - push 直後は Cloudflare 側の build がまだ完了していない可能性がある。
#   - 常に non-blocking (exit code は常に 0)。

WORKERS_DEV_SUBDOMAIN="${WORKERS_DEV_SUBDOMAIN:-m-tama-ramu}"
MARKER='claude-hooks:workers-builds-preview=enabled'

input=$(cat)
command=$(echo "$input" | jq -r '.tool_input.command // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# git push コマンドのみ対象
if ! echo "$command" | grep -qP '(^|&& )git push\b'; then
  exit 0
fi

if [ -z "$cwd" ] || [ ! -d "$cwd" ]; then
  exit 0
fi

# ブランチ名を取得 (main/master への push は preview 対象外)
BRANCH=$(cd "$cwd" && git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  exit 0
fi

# wrangler 設定ファイルを探し、marker があるか確認
WRANGLER_FILE=""
for f in "$cwd/wrangler.toml" "$cwd/wrangler.jsonc" "$cwd/wrangler.json"; do
  if [ -f "$f" ]; then
    WRANGLER_FILE="$f"
    break
  fi
done

if [ -z "$WRANGLER_FILE" ]; then
  exit 0
fi

if ! grep -qF "$MARKER" "$WRANGLER_FILE"; then
  exit 0
fi

# worker 名を取得 (top-level の name フィールド最初の1件。
# [env.staging] 等の named environment 内の name より前にあるのが前提)
if [[ "$WRANGLER_FILE" == *.toml ]]; then
  WORKER_NAME=$(grep -m1 -E '^[[:space:]]*name[[:space:]]*=[[:space:]]*"' "$WRANGLER_FILE" \
    | sed -E 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/')
else
  WORKER_NAME=$(grep -m1 -E '"name"[[:space:]]*:[[:space:]]*"' "$WRANGLER_FILE" \
    | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
fi

if [ -z "$WORKER_NAME" ]; then
  exit 0
fi

# branch 名を Cloudflare の preview alias 仕様どおり sanitize
# (lowercase化 + 非英数字を hyphen に置換、先頭/末尾の hyphen を除去)
SANITIZED_BRANCH=$(echo "$BRANCH" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')

if [ ${#SANITIZED_BRANCH} -gt 63 ]; then
  jq -n --arg ctx "ℹ️ Workers Builds preview: branch 名が63文字を超えるため、Cloudflare が付与するハッシュ付き短縮名を予測できません。実際の preview URL は Cloudflare dashboard (Workers & Pages → $WORKER_NAME → Builds) で確認してください。" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $ctx
    }
  }'
  exit 0
fi

PREVIEW_URL="https://${SANITIZED_BRANCH}-${WORKER_NAME}.${WORKERS_DEV_SUBDOMAIN}.workers.dev"

jq -n --arg ctx "🔗 Workers Builds preview URL (branch: $BRANCH, worker: $WORKER_NAME):
$PREVIEW_URL
(push 直後は Cloudflare 側の build がまだ完了していない場合があります。数十秒〜数分待ってからアクセスしてください)" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
exit 0
