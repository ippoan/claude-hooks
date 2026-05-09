#!/bin/bash
# Claude Code Notification → ntfy.sh push 通知
# - matcher は "" (全 notification 種別) で受ける
# - idle 系 (idle_prompt / idle_notification / idle) はスパムになるので除外
# - permission_prompt / tool_request 等は ntfy に転送
# - 種別ごとに件数をログに記録 (どの種別が頻繁に来るか観測)
set -u

PAYLOAD="$(cat 2>/dev/null || true)"
TOPIC_FILE="$HOME/.claude/.ntfy-topic"
LOG_FILE="$HOME/.claude/permission-alerts.log"

# topic 取得 (ファイルが無ければ早期 exit)
if [ ! -f "$TOPIC_FILE" ]; then
  echo "[$(date '+%F %T')] notification fired but $TOPIC_FILE missing" >> "$LOG_FILE"
  exit 0
fi
TOPIC="$(tr -d '[:space:]' < "$TOPIC_FILE")"
[ -z "$TOPIC" ] && { echo "[$(date '+%F %T')] empty topic" >> "$LOG_FILE"; exit 0; }

# Claude Code が送るペイロード JSON から情報を抽出
MSG="permission prompt が出ています"
CWD=""
SUBTYPE=""
EVENT=""
if command -v jq &>/dev/null && [ -n "$PAYLOAD" ]; then
  EXTRACTED="$(echo "$PAYLOAD" | jq -r '.message // empty' 2>/dev/null || true)"
  [ -n "$EXTRACTED" ] && MSG="$EXTRACTED"
  CWD="$(echo "$PAYLOAD" | jq -r '.cwd // empty' 2>/dev/null || true)"
  SUBTYPE="$(echo "$PAYLOAD" | jq -r '.subtype // .matcher // .type // empty' 2>/dev/null || true)"
  EVENT="$(echo "$PAYLOAD" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
fi

# idle 系はスパムになるので除外。ログだけ残す
case "$SUBTYPE" in
  idle*|*_idle)
    echo "[$(date '+%F %T')] SKIP idle: event=$EVENT subtype=$SUBTYPE" >> "$LOG_FILE"
    exit 0
    ;;
esac

# ntfy.sh に POST (タイムアウト 4 秒、失敗しても無視)
HTTP=$(curl -s -o /dev/null -w "%{http_code}" --max-time 4 \
  -H "Title: Claude Code 許可待ち" \
  -H "Priority: urgent" \
  -H "Tags: warning,bell" \
  -d "${MSG}${CWD:+ [${CWD##*/}]}" \
  "https://ntfy.sh/${TOPIC}" 2>/dev/null || echo "ERR")

# ログ記録 (event/subtype も記録して後で matcher を絞る判断材料にする)
echo "[$(date '+%F %T')] PUSH event=$EVENT subtype=$SUBTYPE HTTP=$HTTP cwd=${CWD##*/} msg=\"${MSG:0:80}\"" >> "$LOG_FILE"

exit 0
