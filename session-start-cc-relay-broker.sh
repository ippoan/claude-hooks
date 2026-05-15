#!/usr/bin/env bash
# SessionStart hook — ADR-003 Phase C/D smoke-test enabler for ippoan/cc-relay.
#
# Downloads the prebuilt `rust-mcp-agent` musl static binary from the latest
# `ippoan/cc-relay` GitHub Release into `~/.cache/cc-relay/bin/` and, if a
# cached MCP token + broker env vars are present, launches
# `rust-mcp-agent relay` in the background so the next `tools/list` from
# Claude.ai's connector lands on a live host-side broker (Anthropic →
# mcp(-staging).ippoan.org DO → WS → this process → GitHubBroker →
# api.github.com).
#
# Designed to be referenced from any cc-relay clone via:
#
#   {
#     "hooks": {
#       "SessionStart": [{
#         "hooks": [{
#           "type": "command",
#           "command": "$HOME/.claude/sources/claude-hooks/session-start-cc-relay-broker.sh"
#         }]
#       }]
#     }
#   }
#
# Only runs in Claude Code on Web (`CLAUDE_CODE_REMOTE=true`); skips locally
# so we don't touch developer machines on every dev session.
#
# Idempotent: subsequent sessions reuse the cached binary (cheap `curl -I`
# round-trip resolves "latest" -> tag) and skip relay start if a
# `rust-mcp-agent relay` process is already up.
#
# Required for the relay to actually start:
#   - File:  ~/.cc-relay/token       (written by `rust-mcp-agent auth`)
#   - Env:   CC_RELAY_BROKER_REPO    (e.g. ippoan/cc-relay)
#   - Env:   CC_RELAY_BROKER_ISSUE   (broker Issue number)
#   - Env:   CC_RELAY_BROKER_TOKEN   (GitHub PAT or installation token)
#
# Optional env (binary acquisition):
#   - CCR_AGENT_RELEASE_TAG    Pin to a specific tag (default: latest)
#   - CCR_AGENT_BINARY_URL     Full URL override (skips tag resolution)
#   - CCR_AGENT_FORCE_REFRESH  Set non-empty to re-download even if cached
#
# Anything missing → hook prints what's needed and exits 0 (does NOT block
# the session). Logs go to ~/.cc-relay/relay.log; tail it from the session
# if you need to debug a failed connect.
set -euo pipefail

# Local dev: skip entirely. Hook is web-only on purpose.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

# Project root must look like a cc-relay clone. Bail quietly otherwise (a
# user might leave this hook installed globally even when working on
# unrelated repos).
if [[ ! -f "${CLAUDE_PROJECT_DIR:-}/Cargo.toml" ]] \
   || ! grep -q '"crates/agent-cli"' "${CLAUDE_PROJECT_DIR}/Cargo.toml" 2>/dev/null; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

# 1. Fetch the prebuilt binary from GitHub Releases. The musl static target
#    has no system dependencies so it just works inside the sandbox; only
#    network round-trip is needed (~5 MB) instead of a ~2 min cold cargo
#    build.
ASSET="rust-mcp-agent-x86_64-linux-musl"
TAG="${CCR_AGENT_RELEASE_TAG:-latest}"
if [[ -n "${CCR_AGENT_BINARY_URL:-}" ]]; then
  BIN_URL="${CCR_AGENT_BINARY_URL}"
elif [[ "$TAG" == "latest" ]]; then
  BIN_URL="https://github.com/ippoan/cc-relay/releases/latest/download/${ASSET}"
else
  BIN_URL="https://github.com/ippoan/cc-relay/releases/download/${TAG}/${ASSET}"
fi

CACHE_DIR="${HOME}/.cache/cc-relay/bin"
mkdir -p "$CACHE_DIR"
BIN="${CACHE_DIR}/rust-mcp-agent"

if [[ ! -x "$BIN" ]] || [[ -n "${CCR_AGENT_FORCE_REFRESH:-}" ]]; then
  echo "[cc-relay-broker] fetching rust-mcp-agent from $BIN_URL ..." >&2
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  if ! curl -fsSL --retry 3 -o "$TMP/$ASSET" "$BIN_URL"; then
    echo "[cc-relay-broker] failed to download $BIN_URL — relay not started" >&2
    exit 0
  fi
  # Best-effort sha256 verification (skip silently if the .sha256 sibling
  # isn't reachable — some env overrides may point at non-GH mirrors).
  if curl -fsSL --retry 3 -o "$TMP/${ASSET}.sha256" "${BIN_URL}.sha256" 2>/dev/null; then
    if ! (cd "$TMP" && sha256sum -c "${ASSET}.sha256" >/dev/null 2>&1); then
      echo "[cc-relay-broker] sha256 mismatch on $ASSET — relay not started" >&2
      exit 0
    fi
  else
    echo "[cc-relay-broker] no .sha256 sidecar at ${BIN_URL}.sha256 — skipping verify" >&2
  fi
  mv "$TMP/$ASSET" "$BIN"
  chmod +x "$BIN"
  trap - EXIT
  rm -rf "$TMP"
  echo "[cc-relay-broker] rust-mcp-agent cached at $BIN" >&2
fi

# 2. Expose the binary on PATH so the user can just type `rust-mcp-agent ...`
#    in the session shell. CLAUDE_ENV_FILE persists across the session.
if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
  echo "export PATH=\"${CACHE_DIR}:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

LOG_DIR="${HOME}/.cc-relay"
mkdir -p "$LOG_DIR"

# 3. Pre-flight checks. Bail (cleanly) when prerequisites are missing — the
#    user can always start the relay manually after running `auth` and
#    setting the broker env vars.
TOKEN_PATH="${HOME}/.cc-relay/token"
if [[ ! -f "$TOKEN_PATH" ]]; then
  echo "[cc-relay-broker] no MCP token at $TOKEN_PATH — relay not started" >&2
  echo "[cc-relay-broker] run: rust-mcp-agent auth --introspect-secret <SECRET>" >&2
  exit 0
fi

if [[ -z "${CC_RELAY_BROKER_REPO:-}" ]] \
   || [[ -z "${CC_RELAY_BROKER_ISSUE:-}" ]] \
   || [[ -z "${CC_RELAY_BROKER_TOKEN:-}" ]]; then
  echo "[cc-relay-broker] missing CC_RELAY_BROKER_{REPO,ISSUE,TOKEN} env — relay not started" >&2
  exit 0
fi

# 4. Don't double-start.
if pgrep -f "rust-mcp-agent relay" > /dev/null 2>&1; then
  echo "[cc-relay-broker] relay already running (pgrep hit) — skipping start" >&2
  exit 0
fi

# 5. Background launch. nohup + disown so the relay survives the hook exit.
#    Output is fully redirected to relay.log so it does not pollute the agent
#    transcript.
nohup "$BIN" relay > "$LOG_DIR/relay.log" 2>&1 &
disown
echo "[cc-relay-broker] rust-mcp-agent relay launched (PID $!) — logs: $LOG_DIR/relay.log" >&2
