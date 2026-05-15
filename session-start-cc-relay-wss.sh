#!/usr/bin/env bash
# SessionStart hook — issue #8 / cc-relay#50 A 案: launch the WSS /connect
# probe in the background and instruct Claude to drain the server-side queue
# (ADR-006) for any active subscriptions on resume.
#
# Reference architecture (issue #8):
#
#   CCoW container resume
#     ├── probe (rust-mcp-agent probe) — background, WSS /connect, appends
#     │     `event` frames to /tmp/cc-relay-probe-e2e.jsonl
#     │       → consumed by user-prompt-submit-cc-relay-events.sh
#     └── additionalContext → asks Claude to call
#             mcp__cc_relay__list_watched_issues + get_pending_events
#         for any subscribed issues, so events queued during hibernation
#         (auth-worker DO, drop-oldest cap 500) are not lost.
#
# Both probe log and `get_pending_events` deliver the same event by design
# (auth-worker `handlePushEvent` fans out to both paths — see ADR-004/006).
# De-dup is by `delivery_id`, persisted in ~/.cc-relay/seen-deliveries.json
# with a 24h TTL. The user-prompt-submit hook updates that file; this hook
# only reads it (to decide whether to mention the drain at all).
#
# Inputs:
#   stdin  : SessionStart hook input JSON
#   ~/.cc-relay/token           : MCP JWT (written by `rust-mcp-agent auth`)
#   ~/.cc-relay/probe.pid       : PID of running probe (this hook writes it)
#   /tmp/cc-relay-probe-e2e.jsonl : probe log
#
# Outputs:
#   stdout : { hookSpecificOutput: { hookEventName, additionalContext } }
#            JSON when the probe is running OR a drain hint is warranted.
#            Empty / `exit 0` otherwise.
#   stderr : diagnostics (mirrored to ~/.cc-relay/probe-hook.log)
#
# Failure modes documented in README (section "cc-relay WSS hook failure modes").
set -euo pipefail

LOG_DIR="${HOME}/.cc-relay"
HOOK_LOG="${LOG_DIR}/probe-hook.log"
mkdir -p "$LOG_DIR"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$HOOK_LOG"; }

# Local dev → skip. CCoW sets CLAUDE_CODE_REMOTE=true; on dev boxes the user
# usually runs `rust-mcp-agent relay` (broker) directly and does not want a
# second background process scribbling into /tmp.
if [[ "${CLAUDE_CODE_REMOTE:-}" != "true" ]]; then
  exit 0
fi

TOKEN_PATH="${CC_RELAY_TOKEN_PATH:-${HOME}/.cc-relay/token}"
PROBE_LOG="${CC_RELAY_PROBE_LOG:-/tmp/cc-relay-probe-e2e.jsonl}"
PID_FILE="${LOG_DIR}/probe.pid"

# No token → no probe. The drain hint is still useful (Claude can call
# get_pending_events via MCP if the cc-relay MCP server is configured),
# but the live WS path is silently disabled. Issue #8 documents this as
# the "CCoW without token" fallback.
if [[ ! -f "$TOKEN_PATH" ]]; then
  log "no token at $TOKEN_PATH — probe skipped, no drain hint emitted"
  exit 0
fi

# Resolve the binary. Try PATH first (session-start-cc-relay-broker.sh adds
# ~/.cache/cc-relay/bin to PATH via CLAUDE_ENV_FILE, but that env is only
# applied to subsequent shells — not to this hook), then the canonical cache
# location, then bail.
BIN=""
if command -v rust-mcp-agent >/dev/null 2>&1; then
  BIN="$(command -v rust-mcp-agent)"
elif [[ -x "${HOME}/.cache/cc-relay/bin/rust-mcp-agent" ]]; then
  BIN="${HOME}/.cache/cc-relay/bin/rust-mcp-agent"
else
  log "rust-mcp-agent binary not found — probe skipped (run session-start-cc-relay-broker.sh first to fetch it)"
  exit 0
fi

# Resolve owner for the per-user `/u/<owner>/connect` endpoint. Prefer the
# explicit env (set by CC_RELAY_WS_URL or CC_RELAY_GH_LOGIN), fall back to
# the GH_LOGIN that auth-worker writes alongside the token, then to the
# generic `/connect` endpoint (which is what `relay`/`channel` modes use).
WS_URL="${CC_RELAY_WS_URL:-}"
if [[ -z "$WS_URL" ]]; then
  GH_LOGIN="${CC_RELAY_GH_LOGIN:-}"
  if [[ -z "$GH_LOGIN" && -f "${LOG_DIR}/gh_login" ]]; then
    GH_LOGIN="$(cat "${LOG_DIR}/gh_login" 2>/dev/null || true)"
  fi
  if [[ -n "$GH_LOGIN" ]]; then
    WS_URL="wss://mcp-staging.ippoan.org/u/${GH_LOGIN}/connect"
  else
    WS_URL="wss://mcp-staging.ippoan.org/connect"
  fi
fi

# Don't double-start. If the recorded PID is alive AND its argv mentions
# `probe`, skip. Stale PID files (process gone) → relaunch.
already_running=0
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    if grep -q "probe" "/proc/${OLD_PID}/cmdline" 2>/dev/null; then
      already_running=1
      log "probe PID $OLD_PID still alive — not relaunching"
    fi
  fi
fi

if [[ $already_running -eq 0 ]]; then
  # Background launch. nohup + disown so the probe survives the hook exit.
  # All output goes to probe-stderr.log so it doesn't pollute the transcript.
  nohup "$BIN" probe \
    --ws-url "$WS_URL" \
    --token-path "$TOKEN_PATH" \
    --log "$PROBE_LOG" \
    > "${LOG_DIR}/probe-stderr.log" 2>&1 &
  NEW_PID=$!
  disown || true
  echo "$NEW_PID" > "$PID_FILE"
  log "probe launched PID=$NEW_PID ws=$WS_URL log=$PROBE_LOG"
fi

# Initialize cursor at end-of-file the first time the probe runs in a session.
# If the cursor file already exists we leave it; user-prompt-submit hook
# advances it. (Setting cursor to current EOF on fresh start prevents
# re-injecting frames the queue drain will already cover.)
CURSOR_FILE="${LOG_DIR}/probe.cursor"
if [[ ! -f "$CURSOR_FILE" && -f "$PROBE_LOG" ]]; then
  stat -c %s "$PROBE_LOG" > "$CURSOR_FILE" 2>/dev/null || echo 0 > "$CURSOR_FILE"
elif [[ ! -f "$CURSOR_FILE" ]]; then
  echo 0 > "$CURSOR_FILE"
fi

# Drain hint. The hook itself cannot call MCP tools, so it instructs Claude
# to do so. We point at the real tool names (`mcp__cc_relay__*`) so the
# Claude.ai connector resolution lines up — these tools are only available
# when the cc-relay MCP server is configured in the project's mcp-config.
# When it isn't, Claude will see the hint, fail to find the tools, and
# proceed normally; the live probe log path still works.
SEEN_FILE="${LOG_DIR}/seen-deliveries.json"
SEEN_COUNT=0
if [[ -f "$SEEN_FILE" ]]; then
  SEEN_COUNT="$(jq 'length' "$SEEN_FILE" 2>/dev/null || echo 0)"
fi

CONTEXT="cc-relay WSS hook active (issue yhonda-ohishi/claude-hooks#8 / cc-relay#50).

- Probe: ${BIN##*/} probe → ${PROBE_LOG} (PID file: ${PID_FILE})
- WS endpoint: ${WS_URL}
- Live events are injected on next UserPromptSubmit as <cc-relay-event …> envelopes.
- Seen delivery_id cache: ${SEEN_COUNT} entr$(if [[ "$SEEN_COUNT" == "1" ]]; then echo y; else echo ies; fi) (24h TTL, ${SEEN_FILE}).

Drain on session resume:
  If the cc-relay MCP server is configured for this session, immediately call
  mcp__cc_relay__list_watched_issues to enumerate active subscriptions, then
  mcp__cc_relay__get_pending_events to drain the auth-worker DO server-side
  queue (ADR-006). Treat each returned event as if it had just arrived; the
  user-prompt-submit-cc-relay-events.sh hook de-dups against probe-delivered
  copies by delivery_id, so calling both paths is safe.

  The queue is drop-oldest-capped at 500 events per DO; gaps in the
  delivery_id sequence relative to the probe log mean events were dropped
  during a long hibernation. Surface that to the user instead of pretending
  state is complete.

If get_pending_events returns an empty array, nothing was queued during the
hibernation window — no action needed.
"

jq -n --arg ctx "$CONTEXT" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    additionalContext: $ctx
  }
}'
