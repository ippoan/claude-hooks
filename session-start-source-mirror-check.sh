#!/bin/bash
# SessionStart hook: SOURCE-MIRROR 宣言付きコピーの drift を検出する。
#
# 規約 (ippoan/claude-md#76 タスク 4):
#   lib 集約できない構造的コピー (ts-rs 生成型の配布先、暫定 sync コピー等) は
#   コピー先ファイルの先頭 5 行以内に宣言を書く:
#
#     // SOURCE-MIRROR: <repo>:<path>
#
#   <repo>  = canonical を持つ repo 名 (/home/user/<repo> に clone される名前)
#   <path>  = canonical ファイルの repo 内相対 path
#
# 本 hook は attached repo を走査して宣言を集め、canonical 側と内容を比較
# (SOURCE-MIRROR 宣言行自身は除外して sha256) し、ズレていれば warning を
# additionalContext で注入する。対象が「宣言済みコピー」に限定されるため
# 誤検知は出ない。canonical repo が clone されていない場合は skip (unchecked)。
#
# 失敗時は fail-open。
#
# env override:
#   CLAUDE_HOOKS_SCAN_DIRS    attached repo の親 dir, space 区切り (default: /home/user)
#   CLAUDE_SOURCE_MIRROR_MAX  warning に列挙する最大件数 (default: 10)
set -u

SCAN_DIRS="${CLAUDE_HOOKS_SCAN_DIRS:-/home/user}"
MAX="${CLAUDE_SOURCE_MIRROR_MAX:-10}"

emit() {
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$1"
}

# 宣言行を除いた sha256 (比較は宣言行以外の内容で行う)
content_sha() {
  grep -v 'SOURCE-MIRROR:' "$1" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1
}

total=0
drifted=""
unchecked=0
missing=""

for base in $SCAN_DIRS; do
  [ -d "$base" ] || continue
  for dir in "$base"/*/; do
    [ -d "$dir/.git" ] || continue
    # 先頭 5 行以内に宣言を持つ tracked file を列挙
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      mirror="$dir$rel"
      decl="$(head -5 "$mirror" 2>/dev/null | grep -m1 -o 'SOURCE-MIRROR:[[:space:]]*[^[:space:]]*' )" || continue
      spec="${decl#SOURCE-MIRROR:}"
      spec="${spec#"${spec%%[![:space:]]*}"}"
      src_repo="${spec%%:*}"
      src_path="${spec#*:}"
      if [ -z "$src_repo" ] || [ -z "$src_path" ] || [ "$src_repo" = "$spec" ]; then continue; fi
      total=$((total + 1))

      canonical=""
      for b2 in $SCAN_DIRS; do
        [ -d "$b2/$src_repo" ] && canonical="$b2/$src_repo/$src_path" && break
      done
      if [ -z "$canonical" ]; then
        unchecked=$((unchecked + 1))
        continue
      fi
      if [ ! -f "$canonical" ]; then
        missing+="  - $(basename "$dir")/$rel → $src_repo:$src_path (canonical 不在)"$'\n'
        continue
      fi
      if [ "$(content_sha "$mirror")" != "$(content_sha "$canonical")" ]; then
        drifted+="  - $(basename "$dir")/$rel ≠ $src_repo:$src_path"$'\n'
      fi
    done < <(git -C "$dir" grep -l -I 'SOURCE-MIRROR:' -- . 2>/dev/null \
              | while IFS= read -r f; do
                  head -5 "$dir$f" 2>/dev/null | grep -q 'SOURCE-MIRROR:' && printf '%s\n' "$f"
                done)
  done
done

if [ "$total" -eq 0 ]; then
  # 宣言が 1 つも無い環境では無言で終了 (ノイズを増やさない)
  exit 0
fi

if [ -z "$drifted" ] && [ -z "$missing" ]; then
  emit "source-mirror: ${total} mirror(s) in sync (unchecked: ${unchecked})"
  exit 0
fi

msg="[source-mirror] 宣言済みコピーが canonical とズレています。"$'\n'
msg+="canonical 側を正として mirror を更新するか、意図的な分岐なら SOURCE-MIRROR 宣言を外してください:"$'\n'
[ -n "$drifted" ] && msg+="$(printf '%s' "$drifted" | head -n "$MAX")"$'\n'
[ -n "$missing" ] && msg+="canonical が見つからない宣言:"$'\n'"$(printf '%s' "$missing" | head -n "$MAX")"$'\n'
emit "$msg"
exit 0
