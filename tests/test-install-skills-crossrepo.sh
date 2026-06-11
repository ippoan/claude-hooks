#!/bin/bash
# Test runner for session-start-install-skills.sh の cross-repo symlink 対応
# (ippoan/claude-hooks#18 PR3)。
#
# NETWORK_POLICY=off + HOME override で git/network を一切使わず、attached repo の
# .claude/skills/<repo>-map を ~/.claude/skills へ symlink する挙動を検証する。
# 判定はファイルシステム (symlink の有無と指す先) で行う。
#
# Works locally (run from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# Requires: jq, python3 不要。
#
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/session-start-install-skills.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable: $HOOK" >&2
  exit 99
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 99
fi

PASS=0
FAIL=0
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# fake attached repo with a co-located map
mk_attached_map() {
  local repo="$1" mapname="$2"
  mkdir -p "$TMP/repos/$repo/.git"
  mkdir -p "$TMP/repos/$repo/.claude/skills/$mapname"
  printf -- '---\nname: %s\ngenerated-from: %s:deadbeef\npaths: [src/]\n---\n' \
    "$mapname" "$repo" > "$TMP/repos/$repo/.claude/skills/$mapname/SKILL.md"
}

run_hook() {
  HOME="$TMP/home" \
  CLAUDE_HOOKS_INSTALL_NETWORK=off \
  CLAUDE_HOOKS_SCAN_DIRS="$TMP/repos" \
    bash "$HOOK" </dev/null >/dev/null 2>&1
}

check() {
  local name="$1" cond="$2"
  if eval "$cond"; then echo "✓ $name"; PASS=$((PASS+1));
  else echo "✗ $name  (cond: $cond)"; FAIL=$((FAIL+1)); fi
}

SK="$TMP/home/.claude/skills"

# --- A: attached repo の map が symlink される ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_map "rust-flickr" "rust-flickr-map"
run_hook
check "A attached map linked" \
  '[[ -L "$SK/rust-flickr-map" && "$(readlink "$SK/rust-flickr-map")" == "$TMP/repos/rust-flickr/.claude/skills/rust-flickr-map" ]]'

# --- B: 既存 symlink (sources 由来想定) を attached が override する ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_map "rust-flickr" "rust-flickr-map"
mkdir -p "$SK" "$TMP/other/rust-flickr-map"
ln -sfn "$TMP/other/rust-flickr-map" "$SK/rust-flickr-map"   # 旧 (claude-skills) 由来を模す
run_hook
check "B attached overrides existing symlink (attached wins)" \
  '[[ "$(readlink "$SK/rust-flickr-map")" == "$TMP/repos/rust-flickr/.claude/skills/rust-flickr-map" ]]'

# --- C: 手書き (非 symlink) ターゲットは override せず skip ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_map "rust-flickr" "rust-flickr-map"
mkdir -p "$SK/rust-flickr-map"                                # 実ディレクトリ = 手管理
echo "manual" > "$SK/rust-flickr-map/SKILL.md"
run_hook
check "C non-symlink target skipped (not clobbered)" \
  '[[ ! -L "$SK/rust-flickr-map" && -f "$SK/rust-flickr-map/SKILL.md" && "$(cat "$SK/rust-flickr-map/SKILL.md")" == "manual" ]]'

# --- D: source repo (claude-skills) の attached checkout はスキップ ---
rm -rf "$TMP/home" "$TMP/repos"
mkdir -p "$TMP/repos/claude-skills/.git"
mkdir -p "$TMP/repos/claude-skills/.claude/skills/should-skip-map"
printf -- '---\nname: should-skip-map\n---\n' > "$TMP/repos/claude-skills/.claude/skills/should-skip-map/SKILL.md"
run_hook
check "D source repo's attached checkout skipped" \
  '[[ ! -e "$SK/should-skip-map" ]]'

# --- E: .claude/skills が無い attached repo は無視 ---
rm -rf "$TMP/home" "$TMP/repos"
mkdir -p "$TMP/repos/plain/.git"
run_hook
check "E repo without .claude/skills is a no-op" \
  '[[ -d "$SK" ]]'

echo ""
echo "install-skills-crossrepo: $PASS passed, $FAIL failed"
exit "$FAIL"
