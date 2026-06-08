#!/bin/bash
# PreToolUse hook (matcher: "Write|Edit")
#
# CF Secrets Store ↔ GCP Secret Manager の secret 命名規約を **非ブロッキング**
# で警告する guard。規約 (SoT) は claude-skills の `secret-naming` skill:
#
#   - CF Secrets Store binding `secret_name` (wrangler.{toml,jsonc,json})
#       → kebab-case  (`[a-z0-9-]` のみ)
#   - GCP Secret Manager の secret 名
#       (`--set-secrets` / `--update-secrets` の `ENV=SECRET:ver`、
#        `gcloud secrets create <NAME>`)
#       → SCREAMING_SNAKE_CASE  (`[A-Z0-9_]` のみ)
#
# 経緯: ippoan/secrets-inventory#23。両プラットフォームとも secret 名 rename 不可
# (= delete+再投入)、alias 併存は rotation 2 重 bump で drift する。なので名前は
# 揃えず規約で固定し、違反は code review より前に Edit/Write 時点で気付かせ、
# 既存違反は随時修正する方針。
#
# deny はしない (= 値の正当性は人間判断もあり得る)。additionalContext で警告のみ。
# 失敗時は fail-open (jq 不在 / parse 不能なら静かに allow)。
set -u

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"

TOOL="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || exit 0
# Write は content、Edit は new_string を検査対象にする。
CONTENT="$(printf '%s' "$INPUT" | jq -r '
  (.tool_input.content // .tool_input.new_string // "")
' 2>/dev/null)" || exit 0
[ -z "$CONTENT" ] && exit 0

BASE="$(basename "$FILE")"

WARN=""

# --- check A: wrangler の secret_name は kebab-case --------------------------
case "$BASE" in
  wrangler.toml|wrangler.json|wrangler.jsonc)
    # `secret_name = "X"` (toml) / `"secret_name": "X"` (json) の X を抜き出す。
    while IFS= read -r val; do
      [ -z "$val" ] && continue
      # kebab 違反 = 大文字 or アンダースコア を含む
      if printf '%s' "$val" | grep -qE '[A-Z_]'; then
        WARN="${WARN}  - CF Secrets Store の secret_name \"${val}\" は kebab-case 推奨 (大文字 / _ を含まない)
"
      fi
    done < <(printf '%s' "$CONTENT" \
      | grep -oE '"?secret_name"?[[:space:]]*[:=][[:space:]]*"[^"]+"' \
      | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/')
    ;;
esac

# --- check B: GCP Secret Manager の secret 名は SCREAMING_SNAKE_CASE ---------
# B-1: `--set-secrets` / `--update-secrets` の ENV=SECRET:ver マッピング。
#      mapping は comma 区切りで複数並ぶ。各 mapping の `=` 右辺 (`:` まで) が
#      GCP secret 名。grep で全 mapping ブロックを抜き、comma で pair に割り、
#      各 pair の secret 名を検査する。出力は command substitution で集約する
#      (pipe の while は subshell なので変数代入が外へ伝わらないため)。
B1_WARN="$(printf '%s' "$CONTENT" \
  | grep -oE '(--set-secrets|--update-secrets)[=[:space:]]+"?[A-Za-z0-9_=:,./-]+' \
  | sed -E 's/^--(set|update)-secrets[=[:space:]]+"?//' \
  | tr ',' '\n' \
  | while IFS= read -r pair; do
      # `ENV=SECRET:ver` → SECRET (= 上の repo 規約では SCREAMING_SNAKE)
      sec="$(printf '%s' "$pair" | sed -E 's/^[^=]*=//; s/:.*$//')"
      [ -z "$sec" ] && continue
      # SCREAMING_SNAKE 違反 = 小文字 or ハイフン を含む
      if printf '%s' "$sec" | grep -qE '[a-z-]'; then
        printf '  - GCP Secret Manager 名 "%s" (--set-secrets/--update-secrets) は SCREAMING_SNAKE_CASE 推奨 (小文字 / - を含まない)\n' "$sec"
      fi
    done)"
[ -n "$B1_WARN" ] && WARN="${WARN}${B1_WARN}
"

# B-2: `gcloud secrets create <NAME>` の NAME。
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if printf '%s' "$name" | grep -qE '[a-z-]'; then
    WARN="${WARN}  - GCP Secret Manager 名 \"${name}\" (gcloud secrets create) は SCREAMING_SNAKE_CASE 推奨 (小文字 / - を含まない)
"
  fi
done < <(printf '%s' "$CONTENT" \
  | grep -oE 'gcloud[[:space:]]+secrets[[:space:]]+create[[:space:]]+"?[A-Za-z0-9_-]+' \
  | sed -E 's/.*create[[:space:]]+"?//')

[ -z "$WARN" ] && exit 0

MSG="⚠️ secret 命名規約 (claude-skills \`secret-naming\` / Refs ippoan/secrets-inventory#23) に外れる可能性:

${WARN}
規約: CF Secrets Store binding \`secret_name\` は kebab-case、GCP Secret Manager 名は SCREAMING_SNAKE_CASE。同一 value の pair は GCP を先に rotate → CF/GH へ片方向 propagate (\`sync_from_gcp\`)。意図的に違反する場合はそのまま進めて構いません (これは警告であり block ではありません)。"

jq -n --arg ctx "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $ctx
  }
}'
exit 0
