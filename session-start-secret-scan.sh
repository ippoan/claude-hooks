#!/usr/bin/env bash
# SessionStart hook: ~/ 配下の .env backup 漏れを検知して状況を session に報告する。
#
# /usr/bin/gcloud-secrets scan を実行し、結果サマリを additionalContext に常時注入。
# (「無音 = クリーン」だと hook 自体が動いたのか判別できないため、毎回 1 行は出す)
#
# - クリーン (NEW=0 / DIFF=0 / ⚠=0): ✓ サマリ 1 行 (件数 + ignore 件数) を出す
# - 警告あり (NEW/DIFF/⚠ いずれか > 0): ⚠ + 詳細リスト
# - scan 自体が失敗 (OAuth 失効等): ⚠ + 復旧コマンド案内
# - CLI 不在等の環境問題: 無音 exit (この PC で gcloud-secrets を使ってない場合)
# - timeout は settings.json 側で制御 (10s 目安)
#
# stdin: SessionStart hook input JSON
# stdout: { hookSpecificOutput: { hookEventName, additionalContext } } JSON
set -euo pipefail

CLI=/usr/bin/gcloud-secrets

# CLI が無ければ無音 (環境依存で gcloud-secrets が入ってない場合の保険)
[[ -x "$CLI" ]] || exit 0

# benign / 既知 OK の警告を抑制するための ignore list
# 1 行 1 プロジェクト名。空行と # コメントは無視。
IGNORE_FILE="${HOME}/.secrets-manager-scan-ignore.txt"

# scan 実行 (stderr 含めて取得、失敗してもこのスクリプトは fail させない)
OUT=$("$CLI" scan "$HOME" --env dev 2>&1) || SCAN_RC=$? && SCAN_RC=${SCAN_RC:-0}

# ignore list 適用: 該当プロジェクト名を含む [NEW] / [DIFF] / ⚠-付き OK 行を削除
# 抑制した件数も保持して報告に出す
IGNORED_COUNT=0
IGNORED_NAMES=""
if [[ -f "$IGNORE_FILE" ]]; then
  while IFS= read -r proj; do
    [[ -z "$proj" || "$proj" =~ ^# ]] && continue
    BEFORE=$(grep -cE "^\[(NEW|DIFF|OK)\][[:space:]]+${proj}/" <<< "$OUT" || true)
    if [[ ${BEFORE:-0} -gt 0 ]]; then
      IGNORED_COUNT=$((IGNORED_COUNT + BEFORE))
      IGNORED_NAMES="${IGNORED_NAMES}${IGNORED_NAMES:+, }${proj}"
    fi
    OUT=$(grep -v -E "^\[(NEW|DIFF|OK)\][[:space:]]+${proj}/" <<< "$OUT" || true)
  done < "$IGNORE_FILE"
fi

# 原本サマリから登録済み件数を抽出 (情報量増のため)
TOTAL_OK=$(grep -oE '登録済み: [0-9]+' <<< "$OUT" | grep -oE '[0-9]+' | head -1 || echo "?")

# auth 状況 (~/.secrets-manager-oauth.json から refresh_token の残り寿命を算出)
# Testing OAuth client は 7 日で refresh_token 失効するため早期警告が重要
AUTH_STATUS=""
OAUTH_FILE="${HOME}/.secrets-manager-oauth.json"
if [[ -f "$OAUTH_FILE" ]]; then
  CLIENT_TYPE=$(jq -r '._client_type // "desktop"' "$OAUTH_FILE" 2>/dev/null || echo "desktop")
  RT_EXPIRES_IN=$(jq -r '.refresh_token_expires_in // empty' "$OAUTH_FILE" 2>/dev/null)
  MTIME=$(stat -c '%Y' "$OAUTH_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  if [[ -n "$RT_EXPIRES_IN" && "$MTIME" -gt 0 ]]; then
    RT_EXPIRY=$((MTIME + RT_EXPIRES_IN))
    REMAIN_SEC=$((RT_EXPIRY - NOW))
    REMAIN_DAYS=$((REMAIN_SEC / 86400))
    REMAIN_HOURS=$(( (REMAIN_SEC % 86400) / 3600 ))
    if [[ $REMAIN_SEC -lt 0 ]]; then
      AUTH_STATUS="⚠ refresh_token 失効済 (\`gcloud-secrets reauth\` 必須)"
    elif [[ $REMAIN_SEC -lt 86400 ]]; then
      AUTH_STATUS="⚠ refresh_token 残 ${REMAIN_HOURS}h ($CLIENT_TYPE flow) — 早めに \`gcloud-secrets reauth\`"
    elif [[ $REMAIN_DAYS -lt 3 ]]; then
      AUTH_STATUS="auth: refresh_token 残 ${REMAIN_DAYS}d ${REMAIN_HOURS}h ($CLIENT_TYPE) — そろそろ reauth 推奨"
    else
      AUTH_STATUS="auth: refresh_token 残 ${REMAIN_DAYS}d ($CLIENT_TYPE)"
    fi
  else
    AUTH_STATUS="auth: ($CLIENT_TYPE flow, RT 寿命情報なし)"
  fi
fi

emit_context() {
  jq -n --arg context "$1" '{
    hookSpecificOutput: {
      hookEventName: "SessionStart",
      additionalContext: $context
    }
  }'
}

# OAuth 失効 / 設定不在 / その他エラーで scan 自体が失敗した場合
if [[ $SCAN_RC -ne 0 ]] || ! grep -qE '^合計:' <<< "$OUT"; then
  # invalid_grant や init 未実行などの典型エラーは短く要約
  REASON=$(grep -oE 'invalid_grant|先に init を実行|ENOENT|EACCES' <<< "$OUT" | head -1)
  [[ -z "$REASON" ]] && REASON="scan failed (RC=$SCAN_RC)"
  emit_context "⚠ gcloud-secrets scan が実行できません ($REASON)。
\`gcloud-secrets reauth\` または \`gcloud-secrets init\` での復旧が必要かもしれません。"
  exit 0
fi

# ignore 適用後のフィルタ済み出力から自前で再カウント (gcloud-secrets のサマリは原本ベース)
NEW=$(grep -cE '^\[NEW\]' <<< "$OUT" || true)
DIFF=$(grep -cE '^\[DIFF\]' <<< "$OUT" || true)
# ⚠ 付き行 (NEW でも OK でも語尾に ⚠ が付くケースが両方ある)
WARN=$(grep -cE '⚠$' <<< "$OUT" || true)
NEW=${NEW:-0}; DIFF=${DIFF:-0}; WARN=${WARN:-0}

IGNORE_DESC=""
if [[ $IGNORED_COUNT -gt 0 ]]; then
  IGNORE_DESC=" (ignored: $IGNORED_COUNT — $IGNORED_NAMES)"
fi

# クリーンケース: ✓ 1 行 summary を出す (hook が走ったことを user に示す)
if [[ $NEW -eq 0 && $DIFF -eq 0 && $WARN -eq 0 ]]; then
  CLEAN_MSG="✓ gcloud-secrets scan: 登録済み ${TOTAL_OK} / 未登録 0 / 差分 0 / .gitignore 漏れ 0${IGNORE_DESC}"
  [[ -n "$AUTH_STATUS" ]] && CLEAN_MSG="${CLEAN_MSG}
${AUTH_STATUS}"
  emit_context "$CLEAN_MSG"
  exit 0
fi

# 警告ケース: 詳細リスト
DETAILS=$(grep -E '^\[(NEW|DIFF)\]|⚠$' <<< "$OUT" | head -20)

CONTEXT=$(cat <<EOF
⚠ gcloud-secrets バックアップ漏れを検知 (\`gcloud-secrets scan ~/ --env dev\` 結果):
  登録済み: ${TOTAL_OK} / 未登録: $NEW / 差分あり: $DIFF / .gitignore 漏れ: $WARN${IGNORE_DESC}

$DETAILS

対応: 各プロジェクトで \`cd <dir> && /usr/bin/gcloud-secrets push <folder> .env --env dev\`
benign なら \`~/.secrets-manager-scan-ignore.txt\` に project 名を 1 行追加で抑制可
EOF
)

emit_context "$CONTEXT"
