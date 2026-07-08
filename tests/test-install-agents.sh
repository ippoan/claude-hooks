#!/bin/bash
# Test runner for session-start-install-skills.sh の agent symlink 対応。
#
# claude-skills は .claude/agents/*.md に再利用 sub-agent 定義を同梱する。hook は
# skills と同じ要領でこれを ~/.claude/agents/<name>.md へ symlink し、**user-level
# agent** にする (単独 repo セッションでも解決できるようにするため)。
#
# NETWORK_POLICY=off + HOME override で git/network を一切使わず、sources checkout と
# attached repo の .claude/agents/*.md が ~/.claude/agents へ symlink される挙動を
# 検証する。判定はファイルシステム (symlink の有無と指す先) で行う。
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

# fake sources/claude-skills checkout (as install.sh would clone) with an agent
mk_sources_agent() {
  local name="$1"
  mkdir -p "$TMP/home/.claude/sources/claude-skills/.claude/agents"
  printf -- '---\nname: %s\nmodel: opus\ntools: Read\n---\nbody\n' \
    "$name" > "$TMP/home/.claude/sources/claude-skills/.claude/agents/$name.md"
}

# fake attached repo carrying its own co-located agent
mk_attached_agent() {
  local repo="$1" name="$2"
  mkdir -p "$TMP/repos/$repo/.git"
  mkdir -p "$TMP/repos/$repo/.claude/agents"
  printf -- '---\nname: %s\n---\nbody\n' \
    "$name" > "$TMP/repos/$repo/.claude/agents/$name.md"
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

AG="$TMP/home/.claude/agents"

# --- A: sources/claude-skills の agent が user-level に symlink される ---
rm -rf "$TMP/home" "$TMP/repos"
mk_sources_agent "opus-advisor"
run_hook
check "A sources agent linked to ~/.claude/agents" \
  '[[ -L "$AG/opus-advisor.md" && "$(readlink "$AG/opus-advisor.md")" == "$TMP/home/.claude/sources/claude-skills/.claude/agents/opus-advisor.md" ]]'

# --- B: attached repo の co-located agent が symlink される ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_agent "shakenapp" "shaken-helper"
run_hook
check "B attached repo agent linked" \
  '[[ -L "$AG/shaken-helper.md" && "$(readlink "$AG/shaken-helper.md")" == "$TMP/repos/shakenapp/.claude/agents/shaken-helper.md" ]]'

# --- C: 既存 symlink (sources 由来想定) を attached が override する ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_agent "shakenapp" "opus-advisor"
mkdir -p "$AG" "$TMP/other"
printf -- '---\nname: opus-advisor\n---\n' > "$TMP/other/opus-advisor.md"
ln -sfn "$TMP/other/opus-advisor.md" "$AG/opus-advisor.md"   # 旧 (sources) 由来を模す
run_hook
check "C attached overrides existing symlink (attached wins)" \
  '[[ "$(readlink "$AG/opus-advisor.md")" == "$TMP/repos/shakenapp/.claude/agents/opus-advisor.md" ]]'

# --- D: 手書き (非 symlink) ターゲットは override せず skip ---
rm -rf "$TMP/home" "$TMP/repos"
mk_attached_agent "shakenapp" "opus-advisor"
mkdir -p "$AG"
echo "manual" > "$AG/opus-advisor.md"                        # 実ファイル = 手管理
run_hook
check "D non-symlink target skipped (not clobbered)" \
  '[[ ! -L "$AG/opus-advisor.md" && "$(cat "$AG/opus-advisor.md")" == "manual" ]]'

# --- E: source repo (claude-skills) の attached checkout はスキップ ---
rm -rf "$TMP/home" "$TMP/repos"
mkdir -p "$TMP/repos/claude-skills/.git/x" "$TMP/repos/claude-skills/.claude/agents"
printf -- '---\nname: should-skip-agent\n---\n' > "$TMP/repos/claude-skills/.claude/agents/should-skip-agent.md"
run_hook
check "E source repo's attached checkout skipped" \
  '[[ ! -e "$AG/should-skip-agent.md" ]]'

# --- F: .claude/agents が無い attached repo は no-op ---
rm -rf "$TMP/home" "$TMP/repos"
mkdir -p "$TMP/repos/plain/.git/x"
run_hook
check "F repo without .claude/agents is a no-op" \
  '[[ -d "$AG" ]]'

echo ""
echo "install-agents: $PASS passed, $FAIL failed"
exit "$FAIL"
