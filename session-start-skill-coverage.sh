#!/usr/bin/env bash
# SessionStart hook: attached repo のうち「構造把握用 map skill が無い」repo を
# 列挙する (coverage のみ)。
#
# 縮小の経緯 (ippoan/claude-hooks#18):
#   旧版は stale 判定 (skill の記録 tree-sha vs repo の現在 tree-sha) も持っていたが、
#   (1) tree-sha 完全一致のため 1 コミットで常時 stale 化 (オオカミ少年)、
#   (2) covered[repo] が glob 順の後勝ち上書きで複数 skill カバー時に stale をマスク、
#   (3) SessionStart の warn 自体が CCoW で無視される、という理由で機能しなかった。
#   stale 判定は skills-check CI (PR diff、ippoan/ci-workflows#118) へ移譲し、
#   本 hook は「map の無い repo の通知」だけに縮小した。
#
# 設計: ippoan/claude-skills の cross-repo-symbol-index skill。
#   横断 symbol index を D1/CI で持つ代わりに「symbol はその場でローカル ctags、
#   構造 map は手書き skill」最小形。鮮度 (code↔map の追従) は CI が見る。
#
# generated-from の形式 (skill SKILL.md の frontmatter):
#   新: generated-from: <repo>:<commit-sha>      (+ 別行 `paths: [src/, ...]`)
#   旧/横断: generated-from: claude-md:<tree-sha> claude-hooks:<tree-sha> ...
#   どちらも space 区切りの `<repo>:<sha>` を列挙する形なので、本 hook は repo 名
#   だけを取り出して coverage を計算する (sha / paths は CI が使う、ここでは無視)。
#
# 出力: uncovered が 1 つでもあれば warning、無ければ 1 行報告。
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

# 1. 全 skill の generated-from から「カバーされている repo の集合」を作る。
#    covered[repo] には カバーしている skill 名を **蓄積** する (後勝ち上書きしない
#    = 複数 skill が同一 repo をカバーしても両方記録する。旧版のマスクバグ修正)。
declare -A covered
if [ -d "$SKILLS_DIR" ]; then
  for f in "$SKILLS_DIR"/*/SKILL.md; do
    [ -f "$f" ] || continue
    skill="$(basename "$(dirname "$f")")"
    line="$(grep -m1 '^generated-from:' "$f" 2>/dev/null)" || continue
    for pair in ${line#generated-from:}; do
      repo="${pair%%:*}"
      sha="${pair#*:}"
      # `<repo>:<sha>` の形でなければ (colon 無し → repo==sha) skip
      { [ -n "$repo" ] && [ "$repo" != "$sha" ]; } || continue
      case " ${covered[$repo]:-} " in
        *" $skill "*) ;;  # 既に記録済み
        *) covered["$repo"]="${covered[$repo]:-}${covered[$repo]:+ }$skill" ;;
      esac
    done
  done
fi

# 2. clone 済み repo を走査し、covered に居ない repo を uncovered とする。
uncovered=()
for parent in $SCAN_DIRS; do
  [ -d "$parent" ] || continue
  for d in "$parent"/*/; do
    [ -d "${d}.git" ] || continue
    repo="$(basename "$d")"
    case "$IGNORE" in *" $repo "*) continue ;; esac
    [ -n "${covered[$repo]:-}" ] || uncovered+=("$repo")
  done
done

if [ ${#uncovered[@]} -eq 0 ]; then
  emit "skill-coverage: 全 attached repo に対応 map skill あり"
  exit 0
fi

msg="skill coverage (cross-repo-symbol-index skill):"
msg="${msg}"$'\n'"⚠ 対応 map skill が無い repo (${#uncovered[@]}): ${uncovered[*]}"
msg="${msg}"$'\n'"  → repo-map skill でローカル ctags しつつ <repo>-map を作ると良い"
msg="${msg}"$'\n'"    (frontmatter に generated-from: <repo>:<commit-sha> + paths: [...] を付ける。"
msg="${msg}"$'\n'"     code↔map の鮮度は skills-check CI が PR で見る)"
emit "$msg"
