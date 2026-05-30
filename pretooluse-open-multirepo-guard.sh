#!/bin/bash
# PreToolUse hook: agent が `Skill open-multirepo` 呼び出し時に args へ
# `repos=` を勝手に合成するのを block する。
#
# 経緯: ippoan/mcp-relay-rs#9 Phase 4 session (2026-05-20) で user が
# `/open-multirepo` を引数無しで invoke したのに、agent が
# `args=repos=A,B,C prompt:...` を Skill tool に渡し、結果 narrowed scope
# (3 repo) の launch URL を作ってしまった。skill 仕様では「引数無し →
# 全 MCP scope (~11 repo)」が正で、agent 側の synthesize ミス。
#
# 仕様再確認: ippoan/claude-skills/.claude/skills/open-multirepo/SKILL.md
# "Distinguishing **explicit list** vs **descriptive mention**" — user が
# literal に `owner/repo, owner/repo` 形式の list を書いた時だけ narrow 可。
# agent が user の prose を解釈して repos= を作るのは禁止。
#
# 本 hook は `Skill open-multirepo` 呼び出しで args に `repos=` が含まれて
# いれば exit 2 で block。agent は user の元入力を再確認して、(a) repos= を
# 削って再呼び出し、または (b) user が本当に list を書いていたら明示的に
# 例外を取る (本 hook を bypass する `OPEN_MULTIREPO_REPOS_OK=1` env を立てて
# 再実行)。

set -euo pipefail

INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')"
# Skill 以外は素通り
[ "$TOOL_NAME" != "Skill" ] && exit 0

SKILL="$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // ""')"
ARGS="$(printf '%s' "$INPUT" | jq -r '.tool_input.args // ""')"

# open-multirepo 以外は素通り
[ "$SKILL" != "open-multirepo" ] && exit 0

# args が空なら問題なし (skill が全 MCP scope で起動する正しい呼び出し)
[ -z "$ARGS" ] && exit 0

# bypass: user 確認済みの場合用 escape hatch
[ "${OPEN_MULTIREPO_REPOS_OK:-0}" = "1" ] && exit 0

# args が `repos=` を含むかチェック。
# 行頭、prose 内 (空白 or `,` の後) いずれでも match させる。
if printf '%s' "$ARGS" | grep -qE '(^|[[:space:],])repos='; then
  cat >&2 <<'EOF'
::error::open-multirepo: args に `repos=` を含む narrowed scope 呼び出しを block しました。

理由:
  skill 仕様では引数無し or "repos=" 無しなら **全 MCP scope** (~11 repo) を
  attach するのが default。agent が user の prose を解釈して repos= を
  合成してはいけない (= narrow scope の launch URL になり、cross-repo
  verification が壊れる)。

確認事項:
  user の元 (今ターン or 直前ターン) の literal text を確認:
    - `/open-multirepo repos=A,B,C ...` のように comma-separated owner/repo
      list を **literal に書いていた** か?
    - 書いていない (prose 内で repo 名を mention しただけ) なら、agent の
      synthesize ミス。

対処:
  1. Skill 呼び出しから `repos=...` 部分を削除し、prompt だけを args として渡す。
     skill が default で全 MCP scope を attach する。
  2. user が本当に list を literal に書いていた場合のみ、env
     `OPEN_MULTIREPO_REPOS_OK=1` を立てて再実行 (bypass)。

参照:
  - ippoan/claude-skills/.claude/skills/open-multirepo/SKILL.md
    "Distinguishing **explicit list** vs **descriptive mention**"
  - ippoan/mcp-relay-rs#9 Phase 4 session (2026-05-20 regression)
EOF
  exit 2
fi

exit 0
