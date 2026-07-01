#!/bin/bash
# Stdin-pipe test runner for pr-refs-link-guard.sh.
#
# Pure text check (no gh / network needed). Feeds create_pull_request tool
# inputs (title/body) and asserts allow vs deny.
#
# Requires: jq in PATH.
# Exit code = number of failures.

set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/pr-refs-link-guard.sh"

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

# run <name> <expected allow|deny> <tool_name> <title> <body>
run() {
  local name="$1" expected="$2" tool="$3" title="$4" body="$5"
  local input out actual

  input=$(jq -nc \
    --arg tool "$tool" \
    --arg title "$title" \
    --arg body "$body" \
    '{tool_name: $tool, tool_input: {title: $title, body: $body}}')

  out=$("$HOOK" <<< "$input" 2>/dev/null)

  actual="allow"
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    actual="deny"
  fi

  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name → $actual"
    PASS=$((PASS+1))
  else
    echo "✗ $name → expected=$expected actual=$actual"
    echo "  title: $title"
    echo "  body:  $body"
    echo "  out:   $out"
    FAIL=$((FAIL+1))
  fi
}

echo "=== pr-refs-link-guard.sh pipe tests (repo=$REPO_ROOT) ==="

# --- allow: ref in title ---
run "T1 Refs in title" \
    "allow" "mcp__github__create_pull_request" \
    "fix(auth): stop login loop (Refs #302)" \
    "本文に説明"

run "T2 Related to in title" \
    "allow" "mcp__github__create_pull_request" \
    "refactor: tidy (Related to #12)" \
    ""

run "T3 cross-repo Refs in title" \
    "allow" "mcp__github__create_pull_request" \
    "chore: bump (Refs ippoan/rust-alc-api#434)" \
    ""

run "T4 issue URL in title" \
    "allow" "mcp__github__create_pull_request" \
    "fix: see https://github.com/ippoan/auth-worker/issues/315" \
    ""

# --- deny: ref only in body (the regression this hook now catches) ---
run "T5 Refs only in body → deny" \
    "deny" "mcp__github__create_pull_request" \
    "fix(admin): stop cross-env cookie loop" \
    "## 変更\n\nRefs #315\nRefs ippoan/rust-alc-api#434"

run "T6 no ref anywhere → deny" \
    "deny" "mcp__github__create_pull_request" \
    "chore: cleanup" \
    "just some text"

# --- opt-out ---
run "T7 [no-issue] in body → allow" \
    "allow" "mcp__github__create_pull_request" \
    "chore: pure infra" \
    "説明\n\n[no-issue]"

run "T8 [no-issue] in title → allow" \
    "allow" "mcp__github__create_pull_request" \
    "chore: pure infra [no-issue]" \
    ""

# --- non-create tool is ignored ---
run "T9 different tool → allow (ignored)" \
    "allow" "mcp__github__update_pull_request" \
    "no ref at all" \
    ""

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
exit "$FAIL"
