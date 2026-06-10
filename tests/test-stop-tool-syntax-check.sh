#!/bin/bash
# Stdin-pipe test runner for stop-tool-syntax-check.sh.
#
# Stop hook なので判定軸は:
#   「decision:block を出した = 検出」 / 「何も出さない = clean」。
#
# Works locally (run from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# Requires: python3 in PATH (hook 本体が使う)。
#
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/stop-tool-syntax-check.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable: $HOOK" >&2
  exit 99
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not installed" >&2
  exit 99
fi

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# $1 = test name, $2 = expect ("block"|"clean"), $3 = assistant text
run_case() {
  local name="$1" expect="$2" text="$3"
  local jsonl="$TMP/t.jsonl" input="$TMP/in.json"
  python3 - "$jsonl" "$text" <<'PY'
import sys, json
path, text = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps({"type": "assistant",
                        "message": {"content": [{"type": "text", "text": text}]}}) + "\n")
PY
  printf '%s' "{\"transcript_path\":\"$jsonl\",\"stop_hook_active\":false}" > "$input"
  local out
  out="$(cat "$input" | "$HOOK")"
  local got="clean"
  printf '%s' "$out" | grep -q '"decision":"block"' && got="block"
  if [[ "$got" == "$expect" ]]; then
    echo "  ok: $name ($got)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name — expected $expect, got $got" >&2
    FAIL=$((FAIL + 1))
  fi
}

# malformed tool calls (text-leaked) → block
run_case "invoke-name"      block 'やります。<invoke name="Bash"><parameter name="command">ls</parameter></invoke>'
run_case "function_calls"   block '<function_calls><invoke name="Read"></invoke></function_calls>'
run_case "antml-leaked"     block '実行します<invoke name="Bash">'
run_case "closing-tag"      block 'text </invoke> more'

# clean assistant text → no block
run_case "plain-japanese"   clean 'issue を 10 件起票しました。コードは未変更です。'
run_case "code-mention"     clean 'Bash ツールで `ls` を実行します。'
run_case "angle-brackets"   clean 'if a < b && c > d then ...'

# stop_hook_active guard: malformed but already blocked once → must NOT re-block
{
  jsonl="$TMP/g.jsonl"
  python3 - "$jsonl" '<invoke name="Bash">' <<'PY'
import sys, json
path, text = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps({"type": "assistant",
                        "message": {"content": [{"type": "text", "text": text}]}}) + "\n")
PY
  out="$(printf '%s' "{\"transcript_path\":\"$jsonl\",\"stop_hook_active\":true}" | "$HOOK")"
  if printf '%s' "$out" | grep -q '"decision":"block"'; then
    echo "  FAIL: stop_hook_active-guard — re-blocked (infinite loop risk)" >&2
    FAIL=$((FAIL + 1))
  else
    echo "  ok: stop_hook_active-guard (no re-block)"
    PASS=$((PASS + 1))
  fi
}

echo "stop-tool-syntax-check: $PASS passed, $FAIL failed"
exit "$FAIL"
