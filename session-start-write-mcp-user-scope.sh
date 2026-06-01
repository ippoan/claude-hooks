#!/usr/bin/env bash
# SessionStart hook: register Cloudflare Worker-native MCP servers into
# `~/.claude.json` at **user scope**, with the live MCP-JWT inlined into
# the `Authorization` header.
#
# Why
# ===
# ippoan/ref-files-worker#29 added a worker-native `/mcp` Streamable HTTP
# endpoint (`createWorkerMcp`) which exposes the full tool surface —
# including the new `folder_download_url` — directly from the worker, with
# no Rust relay binary in the path. To consume it from Claude Code on the
# Web we just need to add it to `mcpServers` somewhere Claude reads. The
# 2026 best-practice (https://code.claude.com/docs/en/mcp) is **user
# scope** (`~/.claude.json` `.mcpServers.*`) for stable, cross-repo
# servers like a filesystem-shaped service.
#
# The existing `session-start-install-mcp-relay.sh` already obtains an
# MCP-JWT and persists it to
# `~/.config/ref-files-mcp-server-rs/token-{env}.json`. We read that same
# token here, idempotently merge a `ref-files-native` server entry into
# `~/.claude.json`, and chmod 600 the file. The token is inlined (not
# `${VAR}`-expanded at runtime) because Claude Code's expansion of
# headers in user-scope config is undocumented; the file is anyway
# CCoW-container-private and ephemeral, and the token rotates per
# session.
#
# This hook is additive — it does not touch existing `mcpServers`
# entries (cc-relay, github-mcp-server-rs, etc.) and runs after
# `session-start-install-mcp-relay.sh` so the token cache is hydrated.
#
# Failure mode
# ============
# If the token cache is missing or the token is expired we **skip**
# (don't write a broken entry) and emit a diagnostic via
# `additionalContext`. install-mcp-relay's own diagnostic already tells
# the user how to recover; we just stay out of the way.
#
# stdin:  SessionStart hook input JSON (ignored)
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON
set -u

CLAUDE_DIR="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_JSON="${CLAUDE_DIR%/}/.."
CLAUDE_JSON="${HOME}/.claude.json"

emit() {
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$1"
}

# Only run inside Claude Code on the Web — local sessions manage their
# own `~/.claude.json` and we don't want to touch a developer's hand-curated
# user-scope config.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

if [ "${SKIP_WRITE_MCP_USER_SCOPE:-0}" = "1" ]; then
  emit "write-mcp-user-scope: SKIP_WRITE_MCP_USER_SCOPE=1 — skipped"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  emit "write-mcp-user-scope: jq not installed — skipped"
  exit 0
fi

ENV_REF_FILES="${REF_FILES_MCP_ENV:-staging}"
TOKEN_CACHE="${HOME}/.config/ref-files-mcp-server-rs/token-${ENV_REF_FILES}.json"

# Map env → worker origin. Staging and prod share the same hostname today
# (`ref-files.ippoan.org`) but we keep the indirection so future split
# deploys don't need a hook bump.
case "$ENV_REF_FILES" in
  prod|production) WORKER_BASE="https://ref-files.ippoan.org" ;;
  *)               WORKER_BASE="https://ref-files.ippoan.org" ;;
esac

if [ ! -r "$TOKEN_CACHE" ]; then
  emit "write-mcp-user-scope: ref-files token cache absent (${TOKEN_CACHE}) — skipped (install-mcp-relay diagnostic covers recovery)"
  exit 0
fi

ACCESS_TOKEN="$(jq -r '.access_token // empty' "$TOKEN_CACHE" 2>/dev/null)"
EXPIRES_AT="$(jq -r '.expires_at // 0' "$TOKEN_CACHE" 2>/dev/null)"
if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
  emit "write-mcp-user-scope: token cache exists but access_token empty — skipped"
  exit 0
fi
NOW="$(date +%s)"
if [ "$EXPIRES_AT" -gt 0 ] && [ "$EXPIRES_AT" -le "$NOW" ]; then
  emit "write-mcp-user-scope: token expired (exp=$EXPIRES_AT now=$NOW) — skipped, install-mcp-relay should refresh next session"
  exit 0
fi

# Build the server entry. The hook owns this single key; everything else
# in `~/.claude.json` is preserved.
SERVER_KEY="ref-files-native"
mkdir -p "$(dirname "$CLAUDE_JSON")"
[ -f "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

TMP="${CLAUDE_JSON}.tmp.$$"
if ! jq \
    --arg key "$SERVER_KEY" \
    --arg url "${WORKER_BASE}/mcp" \
    --arg auth "Bearer ${ACCESS_TOKEN}" \
    '
      .mcpServers //= {} |
      .mcpServers[$key] = {
        type: "http",
        url: $url,
        headers: { Authorization: $auth }
      }
    ' "$CLAUDE_JSON" > "$TMP" 2>/dev/null; then
  rm -f "$TMP"
  emit "write-mcp-user-scope: jq merge failed on ${CLAUDE_JSON} — skipped"
  exit 0
fi
mv "$TMP" "$CLAUDE_JSON"
chmod 600 "$CLAUDE_JSON" 2>/dev/null || true

TOKEN_SUFFIX="${ACCESS_TOKEN: -8}"
emit "write-mcp-user-scope: ${SERVER_KEY} → ${WORKER_BASE}/mcp (token=…${TOKEN_SUFFIX}, exp=$EXPIRES_AT)"
