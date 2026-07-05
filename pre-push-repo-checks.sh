#!/bin/bash
# PreToolUse hook (Bash matcher): repo 固有の pre-push チェックを git push 前に自動実行
#
# push 先 repo の toplevel に `scripts/pre-push-checks.sh` が存在すれば実行し、
# 非 0 終了なら push を deny する。無い repo では何もしない (repo 側 opt-in)。
#
# 動機: bazel の BUILD 配線漏れ (rust_test への all_crate_deps(normal_dev) 忘れ) の
# ように「`cargo check --tests` では原理的に捕まらず CI まで漏れる」クラスの検査を、
# push 時点のローカル 1 秒で止める (Refs ippoan/rust-alc-api#539 — alc-misc #523 /
# alc-devices #540 で 2 回 CI まで漏れた実害)。checks の中身は各 repo が
# scripts/pre-push-checks.sh に持つ (数秒以内・ネットワーク不要のものに限る規約)。
set -u

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Fast-path: command doesn't contain `git push` at all.
if ! echo "$COMMAND" | grep -qE '(^|[[:space:]&;|(])git[[:space:]]+push\b'; then
  exit 0
fi

# cwd 推定 (proxy-push-guard.sh と同ロジック):
#   - `cd /abs/path && git push ...` → cd 先
#   - 単体 `git push` → $PWD (Bash tool tracking cwd)
TARGET_CWD=""
CD_PATH=$(echo "$COMMAND" | grep -oE '^cd\s+["'\'']?[^&;"'\'' ]+' 2>/dev/null | head -1 | sed -E 's/^cd\s+["'\'']?//' || true)
if [ -n "$CD_PATH" ]; then
  TARGET_CWD="$CD_PATH"
elif [ -n "${PWD:-}" ]; then
  TARGET_CWD="$PWD"
fi
[ -n "$TARGET_CWD" ] || exit 0
[ -d "$TARGET_CWD" ] || exit 0

TOP=$(git -C "$TARGET_CWD" rev-parse --show-toplevel 2>/dev/null || echo "")
[ -n "$TOP" ] || exit 0

CHECK="$TOP/scripts/pre-push-checks.sh"
[ -f "$CHECK" ] || exit 0

OUT=$(cd "$TOP" && bash "$CHECK" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  TAIL=$(echo "$OUT" | tail -15)
  jq -n --arg reason "scripts/pre-push-checks.sh が fail しました (exit $RC)。修正してから push してください。出力末尾:
$TAIL" '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": $reason
    }
  }'
  exit 0
fi

exit 0
