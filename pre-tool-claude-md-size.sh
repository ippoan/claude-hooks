#!/bin/bash
# PreToolUse hook (Write|Edit): repo の CLAUDE.md を ≤50 行 / ≤2000 字 に強制する。
# CLAUDE.md ダイエット (ippoan/claude-md#90) の恒久ガード。上限を超える CLAUDE.md を
# Claude が書こうとした瞬間に deny し、詳細は <repo>-map skill へ退避するよう促す。
#
# 対象: basename がちょうど "CLAUDE.md" のファイルのみ。
#   除外: CLAUDE.md.template / user-memory.md (basename が異なるので自動除外)、
#         パスに /.claude/ を含むもの (~/.claude/CLAUDE.md = user memory 等)。
#   exempt: 内容に "claude-md-size-exempt" を含む場合は許可 (意図的な大型 = claude-md 自身等)。
# 判定は「変更後の CLAUDE.md 全文」に対して行う (Edit は old→new を適用した結果)。
# エラー時は fail-open (exit 0)。session を止めない。
set -u

MAX_LINES=50
MAX_CHARS=2000

INPUT=$(cat)

# jq が無ければ判定不能 → fail-open
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)

[ -z "$FILE_PATH" ] && exit 0

# basename が CLAUDE.md でなければ対象外
case "$(basename "$FILE_PATH")" in
  CLAUDE.md) ;;
  *) exit 0 ;;
esac

# user memory / .claude 配下は対象外 (repo に注入される CLAUDE.md ではない)
case "$FILE_PATH" in
  */.claude/*) exit 0 ;;
esac

# 変更後の全文を計算 (Write=content そのまま / Edit=現ファイルに old→new を適用)
RESULT=$(FILE_PATH="$FILE_PATH" TOOL="$TOOL" python3 - "$INPUT" <<'PY' 2>/dev/null
import sys, json, os
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(3)  # parse 不能 → fail-open
ti = data.get("tool_input", {}) or {}
tool = os.environ.get("TOOL", "")
path = os.environ.get("FILE_PATH", "")

if tool == "Write":
    content = ti.get("content", "")
elif tool == "Edit":
    try:
        with open(path, "r") as f:
            content = f.read()
    except Exception:
        sys.exit(0)  # 新規 Edit 等で読めない → fail-open (判定せず許可)
    old = ti.get("old_string", "")
    new = ti.get("new_string", "")
    if old == "":
        sys.exit(0)
    if ti.get("replace_all"):
        content = content.replace(old, new)
    else:
        content = content.replace(old, new, 1)
else:
    sys.exit(0)  # Write/Edit 以外は対象外

if "claude-md-size-exempt" in content:
    sys.exit(0)  # 明示 exempt

lines = content.count("\n") + (0 if content.endswith("\n") or content == "" else 1)
chars = len(content)
if lines > int(os.environ.get("MAX_LINES", "50")) or chars > int(os.environ.get("MAX_CHARS", "2000")):
    print(f"{lines}\t{chars}")
    sys.exit(10)  # 上限超
sys.exit(0)  # OK
PY
)
STATUS=$?

# python が OK / fail-open で抜けた (exit 0) → 許可
[ "$STATUS" -eq 10 ] || exit 0

LINES=$(printf '%s' "$RESULT" | cut -f1)
CHARS=$(printf '%s' "$RESULT" | cut -f2)

jq -n --arg path "$FILE_PATH" --arg lines "$LINES" --arg chars "$CHARS" \
      --arg maxl "$MAX_LINES" --arg maxc "$MAX_CHARS" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": ("CLAUDE.md が上限超過です (" + $lines + " 行 / " + $chars + " 字 > 上限 " + $maxl + " 行 / " + $maxc + " 字)。\nCLAUDE.md ダイエット規約 (ippoan/claude-md#90): CLAUDE.md には repo の identity・「まず読むもの」条件付きポインタ・repo 固有の 1 行 invariant だけを書き、テーブル定義/エンドポイント/gotcha/デプロイ手順などの詳細は <repo>-map skill (ippoan/claude-skills、lazy) へ退避してください。共通規範は user memory (~/.claude/CLAUDE.md) にあるので繰り返さないこと。\n意図的に大型にする必要がある場合のみ、ファイル内に \"claude-md-size-exempt\" を含めれば許可されます。\n対象: " + $path)
  }
}'
exit 0
