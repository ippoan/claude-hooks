#!/bin/bash
# stop-tool-syntax-check.sh — Stop hook
#
# 目的: assistant が「壊れたツール呼び出し」をテキストとして出力した時に検出する。
#
# 正しいツール呼び出しは構造化された tool_use ブロックになり、transcript の
# assistant text content には現れない。もし `<invoke name=...>` /
# `<function_calls>` / `<parameter name=...>` 等のマークアップが **テキストとして**
# 残っていたら、その呼び出しは harness にパースされず **実行されていない**。
# その場合 `decision: block` で「正しい形式で呼び直せ」と feedback を返す。
#
# 無限ループ防止: `stop_hook_active` が true の時 (= 既に一度 block 済み) は何もしない。
#
# fail-open: 入力/transcript が読めない時は exit 0 (session を止めない)。
set -u

INPUT="$(cat)"

# stop_hook_active なら再 block しない (一度の nudge で十分)
ACTIVE="$(printf '%s' "$INPUT" | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("stop_hook_active", False))
except Exception: print(False)' 2>/dev/null)"
[ "$ACTIVE" = "True" ] && exit 0

TRANSCRIPT="$(printf '%s' "$INPUT" | python3 -c 'import sys,json;
try: print(json.load(sys.stdin).get("transcript_path",""))
except Exception: print("")' 2>/dev/null)"
[ -z "$TRANSCRIPT" ] && exit 0
[ -f "$TRANSCRIPT" ] || exit 0

# transcript (JSONL) から最後の assistant メッセージの text content を取り出す。
LAST_TEXT="$(python3 - "$TRANSCRIPT" <<'PY' 2>/dev/null
import sys, json
path = sys.argv[1]
last = ""
try:
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except Exception:
                continue
            if ev.get("type") != "assistant":
                continue
            parts = []
            for c in ev.get("message", {}).get("content", []):
                if isinstance(c, dict) and c.get("type") == "text":
                    parts.append(c.get("text", ""))
            if parts:
                last = "\n".join(parts)
except Exception:
    pass
print(last)
PY
)"

[ -z "$LAST_TEXT" ] && exit 0

# 漏れたツール呼び出しマークアップを検出。
# 実際に harness にパースされない形 (`<invoke name=`, `<parameter name=`,
# `<function_calls>`, antml 名前空間付きの裸テキスト) を狙う。
if printf '%s' "$LAST_TEXT" \
  | grep -Eq '<(antml:)?(invoke|function_calls|parameter)( name=| key=|>|$)|</(antml:)?(invoke|function_calls|parameter)>'; then
  cat <<'JSON'
{"decision":"block","reason":"直前のメッセージに、テキストとして出力された未実行のツール呼び出しマークアップ (<invoke name=...> / <function_calls> / <parameter name=...> 等) が含まれています。この記法は harness にツール呼び出しとして解釈されず、コマンドは実行されていません。意図したツールを正しいツール呼び出し形式で呼び直してください。"}
JSON
  exit 0
fi

exit 0
