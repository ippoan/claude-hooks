#!/usr/bin/env bash
# Tests for user-prompt-submit-cc-relay-events.sh (and basic session-start
# wiring). Synthesises a probe JSONL log, runs the hook with HOME/CC_RELAY_*
# overrides, and asserts the additionalContext output.
#
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="${REPO_ROOT}/user-prompt-submit-cc-relay-events.sh"
SS_HOOK="${REPO_ROOT}/session-start-cc-relay-wss.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable: $HOOK" >&2
  exit 99
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required" >&2
  exit 99
fi

PASS=0
FAIL=0

setup_env() {
  TMP="$(mktemp -d)"
  export HOME="$TMP"
  export CC_RELAY_PROBE_LOG="${TMP}/probe.jsonl"
  mkdir -p "${TMP}/.cc-relay"
  # cursor starts at 0 → read whole log
  echo 0 > "${TMP}/.cc-relay/probe.cursor"
}

teardown_env() {
  rm -rf "$TMP"
}

emit_event() {
  # $1 delivery_id, $2 event_type, $3 owner, $4 repo, $5 issue_number, $6 payload-extra (JSON)
  local did="$1" et="$2" o="$3" r="$4" iss="$5"
  local extra="${6:-}"
  [[ -z "$extra" ]] && extra='{}'
  jq -cn \
    --arg did "$did" --arg et "$et" --arg o "$o" --arg r "$r" \
    --argjson iss "$iss" --argjson extra "$extra" '
    {
      received_at_ms: 1700000000000,
      frame: {
        kind: "event",
        v: 1,
        delivery_id: $did,
        event_type: $et,
        owner: $o,
        repo: $r,
        issue_number: $iss,
        received_at: "2026-05-15T16:00:00Z",
        payload: ({action:"created",issue:{number:$iss}} + $extra)
      }
    }'
}

emit_non_event() {
  jq -cn '{received_at_ms: 1700000000000, kind:"_probe_ping", len: 4}'
}

assert_contains() {
  local name="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    echo "ok  - $name"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name"
    echo "  haystack: $haystack"
    echo "  expected substring: $needle"
  fi
}

# Pull additionalContext out of a hook's JSON output and substring-match it.
# This sidesteps the `\"` JSON-escaping that breaks naive substring tests.
assert_ctx_contains() {
  local name="$1" out="$2" needle="$3"
  local ctx
  ctx="$(jq -r '.hookSpecificOutput.additionalContext // ""' <<<"$out" 2>/dev/null || true)"
  assert_contains "$name" "$ctx" "$needle"
}

assert_empty() {
  local name="$1" out="$2"
  if [[ -z "$out" ]]; then
    PASS=$((PASS + 1))
    echo "ok  - $name (empty)"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL - $name (expected empty, got: $out)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────
# T1: single event → envelope emitted
# ─────────────────────────────────────────────────────────────────────────
setup_env
emit_event "deliv-001" "issue_comment.created" "ippoan" "cc-relay" 50 '{}' \
  > "$CC_RELAY_PROBE_LOG"
OUT="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_ctx_contains "T1 envelope contains delivery_id" "$OUT" 'delivery_id="deliv-001"'
assert_ctx_contains "T1 envelope contains event_type" "$OUT" 'event_type="issue_comment.created"'
assert_ctx_contains "T1 envelope contains repo" "$OUT" 'repo="cc-relay"'
assert_ctx_contains "T1 envelope contains issue_number" "$OUT" 'issue_number="50"'
assert_ctx_contains "T1 wraps in cc-relay-event tag" "$OUT" '<cc-relay-event '
assert_ctx_contains "T1 includes header count" "$OUT" '1 new event '
SEEN="$(jq -r 'has("deliv-001")' "${HOME}/.cc-relay/seen-deliveries.json")"
assert_contains "T1 records delivery_id in seen-deliveries" "$SEEN" 'true'
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T2: same delivery_id twice → second pass emits nothing (de-dup)
# ─────────────────────────────────────────────────────────────────────────
setup_env
emit_event "deliv-002" "issues.opened" "ippoan" "cc-relay" 51 '{}' \
  > "$CC_RELAY_PROBE_LOG"
OUT1="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_contains "T2 first pass emits envelope" "$OUT1" 'deliv-002'
# Re-add same event (different received_at_ms, same delivery_id) — should be skipped.
emit_event "deliv-002" "issues.opened" "ippoan" "cc-relay" 51 '{}' \
  >> "$CC_RELAY_PROBE_LOG"
OUT2="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_empty "T2 second pass de-dups by delivery_id" "$OUT2"
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T3: non-event frames skipped silently
# ─────────────────────────────────────────────────────────────────────────
setup_env
emit_non_event > "$CC_RELAY_PROBE_LOG"
emit_non_event >> "$CC_RELAY_PROBE_LOG"
OUT="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_empty "T3 non-event frames produce no output" "$OUT"
# Cursor must still advance past them (next event must not be re-counted as new).
CURSOR_AFTER="$(cat "${HOME}/.cc-relay/probe.cursor")"
SIZE="$(stat -c %s "$CC_RELAY_PROBE_LOG")"
if [[ "$CURSOR_AFTER" == "$SIZE" ]]; then
  PASS=$((PASS + 1))
  echo "ok  - T3 cursor advances past non-event frames"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - T3 cursor=$CURSOR_AFTER size=$SIZE"
fi
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T4: probe log absent → exit 0 silently
# ─────────────────────────────────────────────────────────────────────────
setup_env
rm -f "$CC_RELAY_PROBE_LOG"
OUT="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_empty "T4 missing probe log → silent exit" "$OUT"
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T5: incremental — first pass reads N events, second pass only the new ones
# ─────────────────────────────────────────────────────────────────────────
setup_env
emit_event "deliv-005a" "issues.opened" "ippoan" "cc-relay" 60 '{}' \
  > "$CC_RELAY_PROBE_LOG"
OUT1="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_contains "T5 first pass sees 005a" "$OUT1" 'deliv-005a'
emit_event "deliv-005b" "issue_comment.created" "ippoan" "cc-relay" 60 '{}' \
  >> "$CC_RELAY_PROBE_LOG"
OUT2="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_contains "T5 second pass sees 005b" "$OUT2" 'deliv-005b'
if [[ "$OUT2" != *"deliv-005a"* ]]; then
  PASS=$((PASS + 1))
  echo "ok  - T5 second pass does NOT replay 005a"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - T5 second pass replayed 005a"
fi
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T6: TTL pruning — expired seen entries are dropped
# ─────────────────────────────────────────────────────────────────────────
setup_env
# seed seen with a stale entry (2 days old).
echo "{\"deliv-old\": $(($(date +%s) - 200000))}" > "${HOME}/.cc-relay/seen-deliveries.json"
emit_event "deliv-006" "issues.opened" "ippoan" "cc-relay" 70 '{}' \
  > "$CC_RELAY_PROBE_LOG"
"$HOOK" <<< '{"prompt":"hi"}' >/dev/null 2>&1
HAS_OLD="$(jq 'has("deliv-old")' "${HOME}/.cc-relay/seen-deliveries.json")"
HAS_NEW="$(jq 'has("deliv-006")' "${HOME}/.cc-relay/seen-deliveries.json")"
if [[ "$HAS_OLD" == "false" ]]; then
  PASS=$((PASS + 1))
  echo "ok  - T6 expired seen entry pruned"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - T6 expired seen entry NOT pruned"
fi
if [[ "$HAS_NEW" == "true" ]]; then
  PASS=$((PASS + 1))
  echo "ok  - T6 new seen entry recorded"
else
  FAIL=$((FAIL + 1))
  echo "FAIL - T6 new seen entry missing"
fi
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T7: log truncated under us (cursor > size) → reset to 0, replay everything
# ─────────────────────────────────────────────────────────────────────────
setup_env
emit_event "deliv-007" "issues.opened" "ippoan" "cc-relay" 80 '{}' \
  > "$CC_RELAY_PROBE_LOG"
# force cursor past EOF as if log got truncated
echo 999999 > "${HOME}/.cc-relay/probe.cursor"
OUT="$("$HOOK" <<< '{"prompt":"hi"}' 2>/dev/null)"
assert_contains "T7 cursor reset on truncation" "$OUT" 'deliv-007'
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T8: session-start hook — no token → skip with no output
# ─────────────────────────────────────────────────────────────────────────
setup_env
export CLAUDE_CODE_REMOTE=true
OUT="$("$SS_HOOK" <<< '{}' 2>/dev/null)"
assert_empty "T8 no token → session-start hook silent" "$OUT"
unset CLAUDE_CODE_REMOTE
teardown_env

# ─────────────────────────────────────────────────────────────────────────
# T9: session-start hook — local dev (no CLAUDE_CODE_REMOTE) → skip
# ─────────────────────────────────────────────────────────────────────────
setup_env
unset CLAUDE_CODE_REMOTE || true
touch "${HOME}/.cc-relay/token"
OUT="$("$SS_HOOK" <<< '{}' 2>/dev/null)"
assert_empty "T9 local dev → session-start hook silent" "$OUT"
teardown_env

echo ""
echo "Summary: $PASS passed, $FAIL failed"
exit "$FAIL"
