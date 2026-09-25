#!/bin/bash
# refusal-log.sh — 安全分類器による拒否 / 自動フォールバックの記録 hook
#
# UserPromptSubmit / PostModelSwitch / StopFailure を 1 本で受け、
# hook_event_name で分岐して JSONL を 1 行追記する。詳細は .claude/hooks/README.md。
#
#   UserPromptSubmit : 全件記録 (後で session_id で突き合わせるため)
#   PostModelSwitch  : source == "auto" のときだけ記録
#   StopFailure      : last_assistant_message が拒否文言に一致するときだけ記録
#                      (error 型に refusal は無いので文言で判定する)
#
# 不変条件: 何が起きても exit 0・stdout は空。
#   UserPromptSubmit / PostModelSwitch の stdout は Claude の context に入る。
#
# env:
#   REFUSAL_LOG_URL      設定時は同じ JSON を POST (background・3 秒・失敗は無視)
#   REFUSAL_LOG_TOKEN    設定時は Authorization: Bearer で付ける
#   REFUSAL_LOG_DEBUG=1  stdin を丸ごと refusal-debug.jsonl に追記する
#   REFUSAL_LOG_FILE     出力先の上書き (既定: $CLAUDE_PROJECT_DIR/.claude/logs/refusal.jsonl)
#   REFUSAL_LOG_NO_JQ=1  jq があっても python3 実装を使う (テスト用)

exec 1>/dev/null 2>/dev/null
trap 'exit 0' EXIT ERR HUP INT TERM
set -u

PROMPT_MAX=4000
# ドキュメント (errors.md) に載っている拒否文言 4 種:
#   "<model> can't help with this. Start a new session to continue"
#   "... which appears to violate our Usage Policy"          (v2.1.219 より前)
#   "<model>'s safeguards flagged this message / session"
#   "<model> has safety measures that flagged this message for a cybersecurity topic"
REFUSAL_RE="can[’']t help with this|safeguards flagged|Usage Policy|safety measures that flagged"

payload="$(cat)" || exit 0
[ -n "$payload" ] || exit 0

base_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
log_file="${REFUSAL_LOG_FILE:-$base_dir/.claude/logs/refusal.jsonl}"
log_dir="$(dirname "$log_file")"
mkdir -p "$log_dir" || exit 0

if [ "${REFUSAL_LOG_DEBUG:-0}" = "1" ]; then
  printf '%s\n' "$payload" | tr -d '\n' >>"$log_dir/refusal-debug.jsonl"
  printf '\n' >>"$log_dir/refusal-debug.jsonl"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

build_with_jq() {
  printf '%s' "$payload" | jq -c \
    --arg ts "$ts" --arg re "$REFUSAL_RE" --argjson max "$PROMPT_MAX" '
    def base: {ts: $ts, event: .hook_event_name, session_id: .session_id};
    def tail: {transcript_path: .transcript_path, cwd: .cwd};
    def compact: with_entries(select(.value != null));
    if .hook_event_name == "UserPromptSubmit" then
      (.prompt // "") as $p
      | base + {prompt: $p[0:$max]}
        + (if ($p | length) > $max then {truncated: true} else {} end)
        + tail | compact
    elif .hook_event_name == "PostModelSwitch" and .source == "auto" then
      base + {model: .to_model, from_model: .from_model, source: .source} + tail | compact
    elif .hook_event_name == "StopFailure"
         and ((.last_assistant_message // "") | test($re)) then
      base + {message: .last_assistant_message, error: .error} + tail | compact
    else empty end'
}

build_with_python() {
  printf '%s' "$payload" | python3 -c '
import json, re, sys
ts, pat, mx = sys.argv[1], sys.argv[2], int(sys.argv[3])
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
ev = d.get("hook_event_name")
rec = {"ts": ts, "event": ev, "session_id": d.get("session_id")}
if ev == "UserPromptSubmit":
    p = d.get("prompt") or ""
    rec["prompt"] = p[:mx]
    if len(p) > mx:
        rec["truncated"] = True
elif ev == "PostModelSwitch" and d.get("source") == "auto":
    rec.update(model=d.get("to_model"), from_model=d.get("from_model"), source=d.get("source"))
elif ev == "StopFailure" and re.search(pat, d.get("last_assistant_message") or ""):
    rec.update(message=d.get("last_assistant_message"), error=d.get("error"))
else:
    sys.exit(0)
rec.update(transcript_path=d.get("transcript_path"), cwd=d.get("cwd"))
print(json.dumps({k: v for k, v in rec.items() if v is not None},
                 ensure_ascii=False, separators=(",", ":")))
' "$ts" "$REFUSAL_RE" "$PROMPT_MAX"
}

if [ "${REFUSAL_LOG_NO_JQ:-0}" != "1" ] && command -v jq >/dev/null; then
  line="$(build_with_jq)" || exit 0
elif command -v python3 >/dev/null; then
  line="$(build_with_python)" || exit 0
else
  exit 0
fi
[ -n "$line" ] || exit 0

printf '%s\n' "$line" >>"$log_file"

if [ -n "${REFUSAL_LOG_URL:-}" ] && command -v curl >/dev/null; then
  # token は argv に載せない (ps で見える) — ヘッダはプロセス置換のファイル経由で渡す
  (
    hdr=(-H 'Content-Type: application/json')
    if [ -n "${REFUSAL_LOG_TOKEN:-}" ]; then
      exec 3< <(printf 'Authorization: Bearer %s\n' "$REFUSAL_LOG_TOKEN")
      hdr+=(-H @/dev/fd/3)
    fi
    printf '%s' "$line" | curl -sS -o /dev/null --max-time 3 -X POST \
      "${hdr[@]}" --data-binary @- "$REFUSAL_LOG_URL"
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null
fi

exit 0
