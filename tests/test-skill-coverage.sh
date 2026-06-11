#!/bin/bash
# Test runner for session-start-skill-coverage.sh (縮小版、coverage のみ)。
#
# SessionStart hook なので stdin tool input は無い。代わりに一時的な
# CLAUDE_HOME/skills (skill SKILL.md の generated-from) と scan dir (.git を持つ
# fake repo) を env override で差し込み、emit される additionalContext を検証する。
#
# 判定軸:
#   - uncovered repo があれば additionalContext に "対応 map skill が無い repo" を含む
#   - 全 covered なら "全 attached repo に対応 map skill あり"
#
# Works locally (run from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# Requires: python3 (emit が使う), git は不要 (.git は空ディレクトリで代用)。
#
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/session-start-skill-coverage.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable: $HOOK" >&2
  exit 99
fi

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mk_skill <name> <generated-from-value> [extra-frontmatter-line]
mk_skill() {
  local name="$1" gen="$2" extra="${3:-}"
  mkdir -p "$TMP/home/.claude/skills/$name"
  {
    echo "---"
    echo "name: $name"
    echo "generated-from: $gen"
    [ -n "$extra" ] && echo "$extra"
    echo "description: x"
    echo "---"
  } > "$TMP/home/.claude/skills/$name/SKILL.md"
}

# mk_repo <name>  — .git ディレクトリを持つ fake attached repo
mk_repo() {
  mkdir -p "$TMP/repos/$1/.git"
}

# run <name> <expected-substr|__CLEAN__>
run() {
  local name="$1" expect="$2" out ctx
  out=$(CLAUDE_HOME="$TMP/home/.claude" \
        CLAUDE_HOOKS_SCAN_DIRS="$TMP/repos" \
        CLAUDE_SKILL_COVERAGE_IGNORE="${IGNORE_OVERRIDE:-}" \
        bash "$HOOK" 2>/dev/null)
  ctx=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])' 2>/dev/null)
  local ok=0
  if [[ "$expect" == "__CLEAN__" ]]; then
    [[ "$ctx" == *"全 attached repo に対応 map skill あり"* ]] && ok=1
  else
    [[ "$ctx" == *"$expect"* ]] && ok=1
  fi
  if [[ "$ok" == 1 ]]; then
    echo "✓ $name"; PASS=$((PASS+1))
  else
    echo "✗ $name"; echo "   ctx: $ctx"; FAIL=$((FAIL+1))
  fi
}

reset() { rm -rf "$TMP/home" "$TMP/repos"; IGNORE_OVERRIDE=""; }

# --- A: new format (commit-sha + paths) covers repo → clean ---
reset
mk_skill "foo-map" "foo:c0ffee1234567890abcdef" "paths: [src/, proto/]"
mk_repo "foo"
run "A new-format covered → clean" "__CLEAN__"

# --- B: repo with no map → uncovered notice ---
reset
mk_skill "foo-map" "foo:c0ffee" "paths: [src/]"
mk_repo "foo"
mk_repo "bar"
run "B uncovered repo listed" "対応 map skill が無い repo (1): bar"

# --- C: old multi-repo tree-sha format still counts as coverage ---
reset
mk_skill "infra-map" "claude-md:aaa111 claude-hooks:bbb222"
mk_repo "claude-md"
mk_repo "claude-hooks"
run "C old multi-repo format covered → clean" "__CLEAN__"

# --- D: 複数 skill が同一 repo をカバーしても overwrite で消えない ---
#   (旧バグ: 後勝ち上書きで covered[foo] が片方で潰れる)。両方 covered のままで clean。
reset
mk_skill "foo-map"  "foo:111aaa" "paths: [src/]"
mk_skill "foo-alt"  "foo:222bbb" "paths: [app/]"
mk_repo "foo"
run "D multi-skill same repo → clean (no mask)" "__CLEAN__"

# --- E: IGNORE で除外した repo は uncovered に出ない ---
reset
mk_skill "foo-map" "foo:111aaa" "paths: [src/]"
mk_repo "foo"
mk_repo "claude-skills"
IGNORE_OVERRIDE="claude-skills"
run "E ignored repo not flagged → clean" "__CLEAN__"

# --- F: generated-from を持たない skill は coverage に寄与しない ---
reset
mkdir -p "$TMP/home/.claude/skills/plain"
printf -- '---\nname: plain\ndescription: x\n---\n' > "$TMP/home/.claude/skills/plain/SKILL.md"
mk_repo "foo"
run "F skill w/o generated-from → repo uncovered" "対応 map skill が無い repo (1): foo"

echo ""
echo "skill-coverage: $PASS passed, $FAIL failed"
exit "$FAIL"
