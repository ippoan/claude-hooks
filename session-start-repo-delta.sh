#!/bin/bash
# SessionStart hook: 前回 session 以降の各 repo の変更 (commit + 変更 symbol) を
# additionalContext に注入する。
#
# 目的 (ippoan/claude-md#76 タスク 5): 「前回から何が変わったか」をソースを読む
# 前に把握させ、context 消費を抑える。保存型の変更台帳 (旧 ippoan-drift 構想) は
# 必ず drift するため持たない — git log / diff からその場で生成する。
#
# 仕組み:
#   - marker file に「repo 名 + HEAD sha」を毎回記録する
#   - 次回起動時、記録 sha と現在 HEAD の差分を repo ごとに
#       * commit 一覧 (git log --oneline、上限あり)
#       * 変更 symbol 名 (git diff -U0 の hunk header `@@ ... @@ <fn>` から抽出。
#         git userdiff が Rust/TS/Go 等で関数名を埋める。LSP 不要)
#     として注入する
#   - marker が無い repo (fresh container 等) は直近 commit 1 行に degrade
#   - 変化が無い repo は出力しない
#
# 出力: SessionStart hookSpecificOutput.additionalContext JSON 1 オブジェクト。
# 失敗時は fail-open (warning すら出さず exit 0 を基本とする)。
#
# env override:
#   CLAUDE_HOME                   ~/.claude の path (default: $HOME/.claude)
#   CLAUDE_HOOKS_SCAN_DIRS        attached repo の親 dir, space 区切り (default: /home/user)
#   CLAUDE_REPO_DELTA_MARKER      marker file (default: $CLAUDE_HOME/.repo-delta-heads)
#   CLAUDE_REPO_DELTA_MAX_COMMITS repo あたりの commit 表示上限 (default: 5)
#   CLAUDE_REPO_DELTA_MAX_SYMBOLS repo あたりの変更 symbol 表示上限 (default: 8)
#   CLAUDE_REPO_DELTA_MAX_REPOS   詳細表示する repo 数の上限 (default: 10)
#   CLAUDE_REPO_DELTA_FRESH_DAYS  marker 無し時に「最近の repo」とみなす日数 (default: 7)
set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SCAN_DIRS="${CLAUDE_HOOKS_SCAN_DIRS:-/home/user}"
MARKER="${CLAUDE_REPO_DELTA_MARKER:-$CLAUDE_HOME/.repo-delta-heads}"
MAX_COMMITS="${CLAUDE_REPO_DELTA_MAX_COMMITS:-5}"
MAX_SYMBOLS="${CLAUDE_REPO_DELTA_MAX_SYMBOLS:-8}"
MAX_REPOS="${CLAUDE_REPO_DELTA_MAX_REPOS:-10}"
FRESH_DAYS="${CLAUDE_REPO_DELTA_FRESH_DAYS:-7}"

emit() {
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$1"
}

# marker を連想配列に読む (形式: "<repo> <sha>" 1 行ずつ)
declare -A prev_sha
if [ -f "$MARKER" ]; then
  while read -r r s; do
    [ -n "${r:-}" ] && [ -n "${s:-}" ] && prev_sha["$r"]="$s"
  done < "$MARKER"
fi

out=""
shown=0
skipped=0
new_marker=""

for base in $SCAN_DIRS; do
  [ -d "$base" ] || continue
  for dir in "$base"/*/; do
    [ -d "$dir/.git" ] || continue
    repo="$(basename "$dir")"
    cur="$(git -C "$dir" rev-parse --verify -q HEAD 2>/dev/null)" || continue
    [ -n "$cur" ] || continue
    new_marker+="$repo $cur"$'\n'

    prev="${prev_sha[$repo]:-}"
    if [ -n "$prev" ] && [ "$prev" = "$cur" ]; then
      continue
    fi

    if [ "$shown" -ge "$MAX_REPOS" ]; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ -n "$prev" ] && git -C "$dir" cat-file -e "$prev" 2>/dev/null \
        && git -C "$dir" merge-base --is-ancestor "$prev" "$cur" 2>/dev/null; then
      commits="$(git -C "$dir" log --oneline --no-color "$prev..$cur" 2>/dev/null | head -n "$MAX_COMMITS")"
      total="$(git -C "$dir" rev-list --count "$prev..$cur" 2>/dev/null || echo '?')"
      symbols="$(git -C "$dir" diff --no-color -U0 "$prev..$cur" 2>/dev/null \
        | sed -n 's/^@@[^@]*@@ \(.\{1,80\}\).*/\1/p' \
        | sed 's/[[:space:]]*$//' | sort -u | head -n "$MAX_SYMBOLS" | paste -sd ',' - | sed 's/,/, /g')"
      out+="● $repo: ${total} commit(s) since last session"$'\n'
      [ -n "$commits" ] && out+="$(printf '%s\n' "$commits" | sed 's/^/    /')"$'\n'
      [ -n "$symbols" ] && out+="    changed symbols: $symbols"$'\n'
    elif [ -n "$prev" ]; then
      # 記録 sha が履歴に無い (force push / shallow / 別 clone)。直近だけ示す
      last="$(git -C "$dir" log -1 --oneline --no-color 2>/dev/null)"
      out+="● $repo: history diverged from last marker — latest: ${last}"$'\n'
    else
      # marker 無し (fresh container)。最近 push があった repo だけ 1 行
      ts="$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)"
      now="$(date +%s)"
      if [ "$ts" -gt 0 ] && [ $(( (now - ts) / 86400 )) -lt "$FRESH_DAYS" ]; then
        last="$(git -C "$dir" log -1 --format='%h %s (%cr)' --no-color 2>/dev/null)"
        out+="● $repo: latest: ${last}"$'\n'
      else
        continue
      fi
    fi
    shown=$((shown + 1))
  done
done

# marker を atomic に更新 (書けなくても fail-open)
if [ -n "$new_marker" ]; then
  mkdir -p "$(dirname "$MARKER")" 2>/dev/null
  tmp="$(mktemp "${MARKER}.XXXXXX" 2>/dev/null)" && {
    printf '%s' "$new_marker" > "$tmp" && mv -f "$tmp" "$MARKER"
  } 2>/dev/null
fi

if [ -z "$out" ]; then
  emit "repo-delta: no repo changes since last session"
  exit 0
fi

header="[repo-delta] 前回 session 以降に変化のあった repo (詳細が必要な時のみソースを読む):"
[ "$skipped" -gt 0 ] && out+="(+ $skipped repo(s) も変化あり — 上限 $MAX_REPOS で省略)"$'\n'
emit "$header
$out"
exit 0
