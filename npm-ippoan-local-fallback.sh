#!/bin/bash
# PostToolUse hook: `npm install` が `@ippoan/*` (GitHub Packages) の 401 で
# 失敗したとき、local clone を自動探索して `file:` フォールバック手順を
# additionalContext で提案する non-blocking hook。
#
# 背景:
#   CCoW container には GitHub Packages の auth token (NODE_AUTH_TOKEN) が無い
#   ので、`@ippoan/*` を registry から引く `npm install` は
#     npm error 401 Unauthorized - GET https://npm.pkg.github.com/@ippoan%2f<pkg>
#   で必ず落ちる。だが consumer repo は /home/user/<repo> に pre-clone されており、
#   多くの `@ippoan/*` パッケージは別 repo の packages/ に **local copy がある**
#   (例: @ippoan/auth-client-worker -> /home/user/auth-worker/packages/auth-client-worker)。
#   → registry の代わりに `file:` 依存で install すれば token 無しで通る。
#   これを毎回人間が指示するのは面倒なので hook で suggest する。
#
# 検出:
#   - command が npm install / npm ci / npm i 系
#   - tool 出力に npm.pkg.github.com の 401 / auth 失敗 + @ippoan/<pkg> が出ている
#
# 出力:
#   - 失敗した @ippoan/<pkg> ごとに local copy を /home/user 配下から探索し、
#     見つかれば package.json を一時 file: へ差し替える sed コマンドを提案。
#     見つからなければ「token が要る」と明示。
#   - 終了コードは常に 0 (非ブロッキング)。
#
# Triggers (settings.json `PostToolUse.matcher`): "Bash"。
set -u

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // ""')"

# npm install 系でなければ skip (npm i / install / ci)
printf '%s' "$CMD" | grep -qE 'npm\s+(install|ci|i)\b' || exit 0

# tool 出力を defensive に集約 (harness 版で tool_response の形が違うため複数 field を見る)
OUT="$(printf '%s' "$INPUT" | jq -r '
  (.tool_response // empty) as $r
  | if ($r|type) == "string" then $r
    elif ($r|type) == "object" then
      (($r.stdout // "") + "\n" + ($r.stderr // "") + "\n" + ($r.output // ""))
    else "" end
' 2>/dev/null)"
# stdout/stderr が別 field の版にも一応対応
[ -z "$OUT" ] && OUT="$(printf '%s' "$INPUT" | jq -r '(.tool_response.stdout // "") + "\n" + (.tool_response.stderr // "")' 2>/dev/null)"

# @ippoan の GitHub Packages auth 失敗でなければ skip
printf '%s' "$OUT" | grep -q 'npm.pkg.github.com' || exit 0
printf '%s' "$OUT" | grep -qiE '401|unauthorized|authentication token not provided' || exit 0

# 失敗した @ippoan/<pkg> を抽出 (URL は %2f エンコード or 素の / 両対応) → 正規化 + uniq
PKGS="$(printf '%s' "$OUT" \
  | grep -oiE '@ippoan(%2[fF]|/)[a-z0-9._-]+' \
  | sed -E 's/%2[fF]/\//' \
  | sort -u)"
[ -z "$PKGS" ] && exit 0

# /home/user 配下から各 @ippoan/<pkg> の local copy (package.json の name 一致) を探索
declare -A LOCAL
while IFS= read -r pj; do
  [ -f "$pj" ] || continue
  nm="$(jq -r '.name // ""' "$pj" 2>/dev/null)"
  case "$nm" in
    @ippoan/*) LOCAL["$nm"]="$(dirname "$pj")" ;;
  esac
done < <(ls /home/user/*/package.json /home/user/*/packages/*/package.json 2>/dev/null)

LINES=""
SED_CMDS=""
ALL_FOUND=1
while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  path="${LOCAL[$pkg]:-}"
  if [ -n "$path" ]; then
    LINES="${LINES}  ${pkg} -> ${path}
"
    # package.json の version spec を file: へ差し替える sed (spec 値は何でもマッチ)。
    # 区切りは # なので / はエスケープ不要。# / & / \ だけ escape する。
    esc_pkg="$(printf '%s' "$pkg" | sed 's/[#&\\]/\\&/g')"
    esc_path="$(printf '%s' "$path" | sed 's/[#&\\]/\\&/g')"
    SED_CMDS="${SED_CMDS}  sed -i 's#\"${esc_pkg}\": \"[^\"]*\"#\"${esc_pkg}\": \"file:${esc_path}\"#' package.json
"
  else
    LINES="${LINES}  ${pkg} -> (local copy 見つからず: registry token が必要)
"
    ALL_FOUND=0
  fi
done < <(printf '%s\n' "$PKGS")

cd_line=""
[ -n "$CWD" ] && cd_line="  cd ${CWD}
"

if [ "$ALL_FOUND" = "1" ]; then
  TAIL="全 @ippoan dep に local copy あり。次で token 無し install できる:

  cp package.json /tmp/pkg.bak
${cd_line}${SED_CMDS}  npm install --no-audit --no-fund
  git checkout package.json package-lock.json   # ← commit には含めない (file: 依存を残さない)
"
else
  TAIL="一部は local copy が無く registry token が要る。見つかった分だけ file: 差し替え:
${cd_line}${SED_CMDS}  npm install --no-audit --no-fund
  git checkout package.json package-lock.json
"
fi

MSG="💡 @ippoan/* は GitHub Packages 認証 (NODE_AUTH_TOKEN) が要り、CCoW container には token が無いので 401 になります。consumer repo の pre-clone に local copy があるので \`file:\` でフォールバックできます (毎回 staging に逃げる必要なし)。

検出した @ippoan dep と local copy:
${LINES}
${TAIL}"

jq -n --arg ctx "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'
exit 0
