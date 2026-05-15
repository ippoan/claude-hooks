#!/usr/bin/env bash
# UserPromptSubmit hook — issue #8 / cc-relay#50 A 案: tail the WSS probe
# log, extract any new `kind:"event"` frames received since last prompt,
# de-dup by `delivery_id` (also against the server-side queue drain), and
# inject them into the current turn as `<cc-relay-event …>` envelopes.
#
# Pairs with session-start-cc-relay-wss.sh which launches the probe and
# seeds the cursor.
#
# State files (all under ~/.cc-relay/):
#   probe.cursor          byte offset into probe log of last read
#   seen-deliveries.json  { "<delivery_id>": <unix_ts_seen>, ... } 24h TTL
#
# Frame shape (per cc-relay agent-mcp/src/probe.rs + auth-worker push_event):
#   { "received_at_ms": <int>,
#     "frame": { "kind":"event", "v":1,
#                "delivery_id":"…", "event_type":"…",
#                "owner":"…", "repo":"…", "issue_number": N,
#                "received_at":"…", "payload": { … } } }
#
# Non-event frames (hello, _probe_connected, _probe_ping, _probe_pong,
# _probe_close, req/resp/notif) are skipped silently — they're diagnostics,
# not user-visible signal.
#
# Output: when ≥1 new event is found, prints
#   { hookSpecificOutput: { hookEventName: "UserPromptSubmit",
#                           additionalContext: "<envelopes>" } }
# Otherwise exits 0 with no output. Never blocks the prompt.
set -euo pipefail

LOG_DIR="${HOME}/.cc-relay"
PROBE_LOG="${CC_RELAY_PROBE_LOG:-/tmp/cc-relay-probe-e2e.jsonl}"
CURSOR_FILE="${LOG_DIR}/probe.cursor"
SEEN_FILE="${LOG_DIR}/seen-deliveries.json"
SEEN_TTL_SECS="${CC_RELAY_SEEN_TTL_SECS:-86400}"  # 24h

# Drain stdin (hook input) so the caller doesn't see SIGPIPE.
cat >/dev/null 2>&1 || true

# Nothing to do if the probe never wrote anything.
[[ -f "$PROBE_LOG" ]] || exit 0

mkdir -p "$LOG_DIR"

# Resolve cursor (byte offset). Missing or invalid → start from EOF so we
# don't replay the entire pre-session log on the first prompt; the
# session-start hook seeds this to EOF specifically to avoid that.
CURSOR=0
if [[ -f "$CURSOR_FILE" ]]; then
  CURSOR="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
  case "$CURSOR" in
    ''|*[!0-9]*) CURSOR=0 ;;
  esac
fi

SIZE="$(stat -c %s "$PROBE_LOG" 2>/dev/null || echo 0)"

# Log truncated/rotated under us? Reset to start.
if (( CURSOR > SIZE )); then
  CURSOR=0
fi

if (( CURSOR >= SIZE )); then
  exit 0  # No new bytes.
fi

# Read only the new tail. dd with skip+bs=1 is portable and avoids loading
# the whole file. Cap at 4 MB per prompt to bound cost; if a huge backlog
# accumulates, we advance the cursor anyway so subsequent prompts catch up.
MAX_READ=$((4 * 1024 * 1024))
TO_READ=$(( SIZE - CURSOR ))
if (( TO_READ > MAX_READ )); then
  TO_READ=$MAX_READ
fi

# Write the slice to a temp file. Command substitution would strip the
# trailing newline from the slice, which then makes `read -r LINE` skip the
# last line; reading from a real file via < $SLICE sidesteps that.
SLICE="$(mktemp)"
trap 'rm -f "$SLICE"' EXIT
tail -c +$((CURSOR + 1)) "$PROBE_LOG" 2>/dev/null | head -c "$TO_READ" > "$SLICE"

# Advance cursor only up to the last newline boundary in the slice — a
# partial line at the tail will be re-read next prompt. awk over each record
# adds length($0)+1 for the \n; this is exact whenever the slice ends
# precisely at a newline (the common case — probe always writes \n).
SAFE_BYTES="$(awk '
  BEGIN { last_nl = 0; pos = 0 }
  { pos += length($0) + 1; last_nl = pos }
  END { print last_nl }
' "$SLICE")"
if [[ -z "$SAFE_BYTES" || "$SAFE_BYTES" == "0" ]]; then
  exit 0
fi

NEW_CURSOR=$(( CURSOR + SAFE_BYTES ))

# Load seen-deliveries (init to {} if missing/corrupt).
if [[ -f "$SEEN_FILE" ]] && jq -e 'type=="object"' "$SEEN_FILE" >/dev/null 2>&1; then
  SEEN_JSON="$(cat "$SEEN_FILE")"
else
  SEEN_JSON='{}'
fi

NOW_TS="$(date +%s)"
CUTOFF_TS=$(( NOW_TS - SEEN_TTL_SECS ))

# Prune expired entries.
SEEN_JSON="$(jq --argjson cutoff "$CUTOFF_TS" \
  'with_entries(select(.value > $cutoff))' <<<"$SEEN_JSON")"

# Extract event frames from the new slice. One line per JSON object.
# - skip non-event frames (kind != "event")
# - skip frames already in seen
# - record each new delivery_id with NOW_TS
# - emit `<cc-relay-event …>` envelopes in receive order
ENVELOPES=""
NEW_COUNT=0

while IFS= read -r LINE; do
  [[ -z "$LINE" ]] && continue

  # Extract delivery_id + event_type + owner/repo/issue + payload (compact).
  PARSED="$(jq -cr '
    . as $line
    | (.frame // {}) as $f
    | if ($f.kind // "") == "event" then
        {
          delivery_id: ($f.delivery_id // null),
          event_type:  ($f.event_type  // "unknown"),
          owner:       ($f.owner       // null),
          repo:        ($f.repo        // null),
          issue_number:($f.issue_number// null),
          received_at: ($f.received_at // null),
          payload:     ($f.payload     // null)
        }
      else empty end
  ' <<<"$LINE" 2>/dev/null || true)"

  [[ -z "$PARSED" ]] && continue

  DID="$(jq -r '.delivery_id // empty' <<<"$PARSED")"
  if [[ -z "$DID" ]]; then
    # Event with no delivery_id: emit but tag clearly. Don't add to seen.
    DID="_no_delivery_id_"
  else
    # De-dup.
    if jq -e --arg k "$DID" 'has($k)' <<<"$SEEN_JSON" >/dev/null; then
      continue
    fi
    SEEN_JSON="$(jq --arg k "$DID" --argjson t "$NOW_TS" \
      '. + {($k): $t}' <<<"$SEEN_JSON")"
  fi

  # Build envelope. Inline a compact JSON of the payload; the model can
  # introspect it directly. event_type / owner / repo / issue go on the
  # opening tag so they're scannable.
  ATTRS="$(jq -r '
    "delivery_id=\"" + (.delivery_id // "_no_delivery_id_") + "\""
    + " event_type=\"" + (.event_type // "unknown") + "\""
    + (if .owner then " owner=\"" + .owner + "\"" else "" end)
    + (if .repo  then " repo=\""  + .repo  + "\"" else "" end)
    + (if .issue_number then " issue_number=\"" + (.issue_number|tostring) + "\"" else "" end)
    + (if .received_at then " received_at=\"" + .received_at + "\"" else "" end)
  ' <<<"$PARSED")"
  PAYLOAD_JSON="$(jq -c '.payload' <<<"$PARSED")"

  ENVELOPE=$'<cc-relay-event '"$ATTRS"$' source="wss-probe">\n'"$PAYLOAD_JSON"$'\n</cc-relay-event>\n'
  ENVELOPES+="$ENVELOPE"
  NEW_COUNT=$((NEW_COUNT + 1))
done < <(head -c "$SAFE_BYTES" "$SLICE")

# Persist cursor and seen even if no new events emerged (so non-event frames
# don't get reprocessed). Atomic write via temp file.
TMP_CURSOR="$(mktemp "${CURSOR_FILE}.XXXXXX")"
printf '%s\n' "$NEW_CURSOR" > "$TMP_CURSOR"
mv -f "$TMP_CURSOR" "$CURSOR_FILE"

TMP_SEEN="$(mktemp "${SEEN_FILE}.XXXXXX")"
printf '%s\n' "$SEEN_JSON" > "$TMP_SEEN"
mv -f "$TMP_SEEN" "$SEEN_FILE"

if (( NEW_COUNT == 0 )); then
  exit 0
fi

HEADER="cc-relay: ${NEW_COUNT} new event$(if (( NEW_COUNT != 1 )); then echo s; fi) received via WSS /connect probe since last prompt (de-duped against ~/.cc-relay/seen-deliveries.json by delivery_id)."

CTX="${HEADER}"$'\n\n'"${ENVELOPES}"

jq -n --arg ctx "$CTX" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $ctx
  }
}'
