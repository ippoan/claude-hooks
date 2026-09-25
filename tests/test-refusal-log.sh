#!/bin/bash
# refusal-log.sh のテスト。jq 実装と python3 実装の両方で回す。
#   bash tests/test-refusal-log.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/.claude/hooks/refusal-log.sh"
FIX="$ROOT/tests/fixtures/refusal-log"
PASS=0
FAIL=0

ok() { echo "  ok: $1"; PASS=$((PASS + 1)); }
ng() { echo "  FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# run <fixture> → 生成された行を $OUT に入れる。exit 0 と stdout 空もここで検査する
run() {
  local name="$1" rc stdout
  rm -rf "$TMP/proj"
  mkdir -p "$TMP/proj"
  stdout="$(CLAUDE_PROJECT_DIR="$TMP/proj" "$HOOK" <"$FIX/$name.json")"
  rc=$?
  [ "$rc" -eq 0 ] || ng "$MODE/$name: exit $rc"
  [ -z "$stdout" ] || ng "$MODE/$name: stdout not empty: $stdout"
  OUT="$(cat "$TMP/proj/.claude/logs/refusal.jsonl" 2>/dev/null)"
}

# expect <fixture> <python 式 (r が記録行)>
expect() {
  run "$1"
  if [ "$(printf '%s\n' "$OUT" | wc -l)" -ne 1 ] || [ -z "$OUT" ]; then
    ng "$MODE/$1: expected exactly 1 line, got: $OUT"
    return
  fi
  if printf '%s' "$OUT" | python3 -c "
import json, sys
r = json.loads(sys.stdin.read())
assert r['session_id'] == 'sess-1' and r['cwd'] == '/work/repo', r
assert r['transcript_path'].endswith('sess-1.jsonl'), r
assert r['ts'].endswith('Z'), r
assert $2, r
"; then ok "$MODE/$1"; else ng "$MODE/$1: $OUT"; fi
}

expect_none() {
  run "$1"
  if [ -z "$OUT" ]; then ok "$MODE/$1 (not recorded)"; else ng "$MODE/$1: recorded: $OUT"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for MODE in jq python; do
  if [ "$MODE" = jq ]; then
    command -v jq >/dev/null || { echo "  skip: jq not installed"; continue; }
    unset REFUSAL_LOG_NO_JQ
  else
    export REFUSAL_LOG_NO_JQ=1
  fi
  echo "[$MODE]"

  expect user-prompt-submit \
    "r['event'] == 'UserPromptSubmit' and r['prompt'].startswith('Write a function') and 'truncated' not in r"
  expect user-prompt-submit-long \
    "len(r['prompt']) == 4000 and r['prompt'].startswith('あ') and r['truncated'] is True"
  expect post-model-switch-auto \
    "r['event'] == 'PostModelSwitch' and r['source'] == 'auto' and r['model'] == 'claude-opus-4-8' and r['from_model'] == 'claude-opus-5-5' and 'prompt' not in r"
  expect_none post-model-switch-user
  expect stop-failure-cant-help "r['event'] == 'StopFailure' and \"can't help\" in r['message']"
  expect stop-failure-safeguards "'safeguards flagged' in r['message']"
  expect stop-failure-usage-policy "'Usage Policy' in r['message']"
  expect stop-failure-safety-measures "'safety measures that flagged' in r['message']"
  expect_none stop-failure-rate-limit

  # 壊れた入力・空入力でも exit 0 / stdout 空 / 記録なし
  for bad in '' 'not json' '[1,2]'; do
    rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
    stdout="$(printf '%s' "$bad" | CLAUDE_PROJECT_DIR="$TMP/proj" "$HOOK")"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$stdout" ] && [ ! -s "$TMP/proj/.claude/logs/refusal.jsonl" ]; then
      ok "$MODE/bad-input '$bad'"
    else ng "$MODE/bad-input '$bad': rc=$rc stdout=$stdout"; fi
  done
done
unset REFUSAL_LOG_NO_JQ
MODE=misc
echo "[misc]"

# 書き込めない出力先でも exit 0 / stdout 空
stdout="$(CLAUDE_PROJECT_DIR=/proc/nonexistent "$HOOK" <"$FIX/user-prompt-submit.json")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$stdout" ]; then ok "unwritable log dir"; else ng "unwritable log dir: rc=$rc"; fi

# debug: stdin を丸ごと残す (記録対象外のイベントでも)
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
REFUSAL_LOG_DEBUG=1 CLAUDE_PROJECT_DIR="$TMP/proj" "$HOOK" <"$FIX/stop-failure-rate-limit.json"
if python3 -c "import json,sys; d=json.loads(open(sys.argv[1]).readline()); assert d['error']=='rate_limit'" \
  "$TMP/proj/.claude/logs/refusal-debug.jsonl" 2>/dev/null; then ok "debug dump"; else ng "debug dump"; fi

# POST: ローカルの受け口にローカルと同じ JSON と Bearer が届く
PORT_FILE="$TMP/port"; RECV="$TMP/recv.json"
python3 - "$PORT_FILE" "$RECV" <<'PY' &
import http.server, json, sys
port_file, recv = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        json.dump({"auth": self.headers.get("Authorization"), "ctype": self.headers.get("Content-Type"),
                   "body": json.loads(body)}, open(recv, "w"))
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(s.server_address[1]))
s.handle_request()
PY
SRV=$!
for _ in $(seq 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
REFUSAL_LOG_URL="http://127.0.0.1:$(cat "$PORT_FILE")/log" REFUSAL_LOG_TOKEN=secret-tok \
  CLAUDE_PROJECT_DIR="$TMP/proj" "$HOOK" <"$FIX/stop-failure-safeguards.json"
for _ in $(seq 50); do [ -s "$RECV" ] && break; sleep 0.1; done
if python3 - "$RECV" "$TMP/proj/.claude/logs/refusal.jsonl" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); line = json.loads(open(sys.argv[2]).read())
assert r["auth"] == "Bearer secret-tok", r
assert r["ctype"] == "application/json", r
assert r["body"] == line, (r, line)
PY
then ok "POST with bearer"; else ng "POST with bearer"; fi
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

# POST 先が死んでいても hook は待たずに返る
start=$(date +%s%N)
rm -rf "$TMP/proj"; mkdir -p "$TMP/proj"
REFUSAL_LOG_URL="http://10.255.255.1:9/log" CLAUDE_PROJECT_DIR="$TMP/proj" "$HOOK" <"$FIX/stop-failure-safeguards.json"; rc=$?
ms=$(( ($(date +%s%N) - start) / 1000000 ))
if [ "$rc" -eq 0 ] && [ "$ms" -lt 1000 ]; then ok "unreachable URL returns in ${ms}ms"; else ng "unreachable URL: rc=$rc ${ms}ms"; fi

echo "refusal-log: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
