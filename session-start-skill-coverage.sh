#!/usr/bin/env bash
# SessionStart hook: repo ↔ skill の coverage と鮮度を点検する。
#
# 2 つを warning として additionalContext に inject する:
#   (1) coverage — /home/user/<repo> のうち、どの skill の `generated-from` にも
#       載っていない repo を「構造把握用 skill が無い」として列挙。
#   (2) staleness — `generated-from` を持つ skill について、記録した tree-sha と
#       現在の repo の tree-sha がズレていたら「skill が code 変化に追従していない
#       (要再生成)」として列挙。
#
# 設計: ippoan/claude-skills の cross-repo-symbol-index skill。
#   横断 symbol index を D1/CI で持つ代わりに「symbol はその場でローカル ctags、
#   手書き skill が code と乖離してないかだけ hook で見る」最小形。
#
# generated-from の形式 (skill SKILL.md の frontmatter、1 行・space 区切り):
#   generated-from: claude-md:<tree-sha> mcp-relay-rs:<tree-sha> ...
#   tree-sha = 生成時の `git -C /home/user/<repo> rev-parse HEAD^{tree}`
#
# 出力: stale / uncovered が 1 つでもあれば warning。両方空なら 1 行報告。
#
# env override:
#   CLAUDE_HOME             ~/.claude の path (default: $HOME/.claude)
#   CLAUDE_HOOKS_SCAN_DIRS  attached repo の親 dir, space 区切り (default: /home/user)
#   CLAUDE_SKILL_COVERAGE_IGNORE  coverage 警告から除外する repo 名, space 区切り
set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_HOME/skills"
SCAN_DIRS="${CLAUDE_HOOKS_SCAN_DIRS:-/home/user}"
IGNORE=" ${CLAUDE_SKILL_COVERAGE_IGNORE:-} "

emit() {
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$1"
}

# 1. 全 skill の generated-from を集める: covered[repo]=記録 tree-sha
declare -A covered
if [ -d "$SKILLS_DIR" ]; then
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    line="$(grep -m1 '^generated-from:' "$f" 2>/dev/null)" || continue
    for pair in ${line#generated-from:}; do
      repo="${pair%%:*}"
      sha="${pair#*:}"
      [ -n "$repo" ] && [ "$repo" != "$sha" ] && covered["$repo"]="$sha"
    done
  done
fi

# 2. clone 済み repo を走査して stale / uncovered を仕分け
stale=()
uncovered=()
for parent in $SCAN_DIRS; do
  [ -d "$parent" ] || continue
  for d in "$parent"/*/; do
    [ -d "${d}.git" ] || continue
    repo="$(basename "$d")"
    case "$IGNORE" in *" $repo "*) continue ;; esac
    if [ -n "${covered[$repo]:-}" ]; then
      # --verify -q: 空 repo (HEAD 無し) は何も出さず非ゼロ → cur="" で鮮度比較スキップ。
      # 素朴な `rev-parse 'HEAD^{tree}'` は失敗時に literal "HEAD^{tree}" を stdout に
      # 出すため、empty-tree-sha の placeholder map を stale 誤検出してしまう (それを回避)。
      cur="$(git -C "$d" rev-parse --verify -q 'HEAD^{tree}' 2>/dev/null)"
      [ -n "$cur" ] && [ "${covered[$repo]}" != "$cur" ] && stale+=("$repo")
    else
      uncovered+=("$repo")
    fi
  done
done

if [ ${#stale[@]} -eq 0 ] && [ ${#uncovered[@]} -eq 0 ]; then
  emit "skill-coverage: 全 attached repo に generated-from 付き skill あり / 鮮度 OK"
  exit 0
fi

msg="skill coverage / 鮮度チェック (cross-repo-symbol-index skill):"
if [ ${#uncovered[@]} -gt 0 ]; then
  msg="${msg}"$'\n'"⚠ 対応 skill が無い repo (${#uncovered[@]}): ${uncovered[*]}"
  msg="${msg}"$'\n'"  → 構造を把握したい repo は、その場でローカル ctags しつつ skill 化すると良い"
  msg="${msg}"$'\n'"    (skill に generated-from: <repo>:<tree-sha> を付ければ以後 鮮度も追える)"
fi
if [ ${#stale[@]} -gt 0 ]; then
  msg="${msg}"$'\n'"⚠ code が変わったのに追従してない skill の対象 repo (${#stale[@]}): ${stale[*]}"
  msg="${msg}"$'\n'"  → 該当 skill を再生成し generated-from の tree-sha を更新する"
fi
emit "$msg"
