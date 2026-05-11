#!/usr/bin/env bash
# PreToolUse hook: ブロック frontend worktree で直接 npm run dev / npx nuxt dev / wrangler dev を起動するのを禁止。
#
# Why: worktree の .env が本番 URL (NUXT_PUBLIC_API_BASE) を持っているため、
# 直接起動すると API 呼び出しが本番 Cloud Run / 本番 R2 に向かい、データ事故を起こす。
# 必ず ~/js/.dev-proxy/up-wt.sh --quick --auth-skip <id> --incus-backend <p> 経由で起動すること。
#
# Triggers when:
#   - Bash tool is invoked
#   - command contains `npm run dev`, `npx nuxt dev`, `nuxt dev`, `pnpm dev`,
#     `bun run dev`, `wrangler dev` AND
#   - cwd or referenced path is under `.claude/worktrees/`
#
# Permits:
#   - Calls via `up-wt.sh` / `down-wt.sh`
#   - Same commands run from main worktree (= no `.claude/worktrees/` in path)

set -u

# Hook input is JSON on stdin: { tool_name, tool_input: { command, ... } }
input="$(cat)"
tool=$(printf '%s' "$input" | jq -r '.tool_name // ""')
[ "$tool" = "Bash" ] || { exit 0; }

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')

# 早期 escape: up-wt.sh / down-wt.sh / dev-proxy 経由は無条件許可
if printf '%s' "$cmd" | grep -qE 'up-wt\.sh|down-wt\.sh|\.dev-proxy/'; then
    exit 0
fi

# 検出: dev サーバ起動コマンド
if ! printf '%s' "$cmd" | grep -qE '(^|[^a-zA-Z0-9_-])(npm run dev|npx nuxt dev|nuxt dev|pnpm dev|pnpm run dev|bun run dev|bun dev|wrangler dev)([^a-zA-Z0-9_-]|$)'; then
    exit 0
fi

# worktree 配下 (cwd または cmd 内にパス参照) かチェック
cwd=$(pwd 2>/dev/null || printf '')
in_worktree=0
case "$cwd" in
    *.claude/worktrees/*) in_worktree=1 ;;
esac
if printf '%s' "$cmd" | grep -q '\.claude/worktrees/'; then
    in_worktree=1
fi

if [ "$in_worktree" -eq 0 ]; then
    exit 0
fi

# ブロック
cat >&2 <<'EOF'
[hook: no-direct-frontend-dev] BLOCKED
worktree 配下で `npm run dev` / `npx nuxt dev` / `wrangler dev` を直接起動するのは禁止です。
理由: .env の NUXT_PUBLIC_API_BASE=本番URL が読まれて、本番 Cloud Run / 本番 R2 に書き込みが
飛ぶ事故が発生します (frontend は本番デプロイ済みの URL を default で持っているため)。

正しい起動方法:
  bash ~/js/.dev-proxy/up-wt.sh --quick \
    --auth-skip <tenant_id> \
    --incus-backend <project> \
    <project> <wt-name>

このコマンドが NUXT_PUBLIC_API_BASE=http://127.0.0.1:<incus_port> + STAGING_TENANT_ID を
inject して起動します。

詳細: ~/.claude/projects/-home-yhonda-rust-rust-alc-api/memory/feedback_no_direct_nuxt_dev.md
EOF
exit 2
