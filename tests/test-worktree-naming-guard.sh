#!/bin/bash
# Stdin-pipe test runner for worktree-naming-guard.sh.
#
# Works both locally (run from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# T1–T8 mirror the manual test matrix in README.md.
#
# Requires:
#   - jq, gh in PATH
#   - GH_TOKEN env var (for `gh issue view` against this repo)
#
# Exit code = number of failures.

set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/worktree-naming-guard.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "ERROR: hook not executable: $HOOK" >&2
  exit 99
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq not installed" >&2
  exit 99
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh not installed" >&2
  exit 99
fi

PASS=0
FAIL=0

run() {
  local name="$1" expected="$2" cmd="$3" envvars="${4:-}"
  local input out actual

  input=$(jq -nc \
    --arg cmd "$cmd" \
    --arg cwd "$REPO_ROOT" \
    '{tool_name: "Bash", tool_input: {command: $cmd}, cwd: $cwd}')

  if [[ -n "$envvars" ]]; then
    # shellcheck disable=SC2086
    out=$(env $envvars "$HOOK" <<< "$input" 2>&1)
  else
    out=$("$HOOK" <<< "$input" 2>&1)
  fi

  actual="allow"
  if echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    actual="deny"
  fi

  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name → $actual"
    PASS=$((PASS+1))
  else
    echo "✗ $name → expected=$expected actual=$actual"
    echo "  cmd:  $cmd"
    echo "  env:  $envvars"
    echo "  out:  $out"
    FAIL=$((FAIL+1))
  fi
}

echo "=== worktree-naming-guard.sh pipe tests (repo=$REPO_ROOT) ==="

run "T1 worktree add valid (issue#2 exists)" \
    "allow" \
    "git worktree add -b 2-feat-worktree-naming-guard .claude/worktrees/x origin/master"

run "T2 worktree add invalid regex (no issue-number)" \
    "deny" \
    "git worktree add -b fix/onedrive .claude/worktrees/x origin/main"

run "T3 worktree add invalid issue (999999 not exist)" \
    "deny" \
    "git worktree add -b 999999-feat-x .claude/worktrees/x origin/main"

run "T4 checkout -b invalid type" \
    "deny" \
    "git checkout -b 1-typo-foo"

run "T5 switch -c valid (issue#2 exists)" \
    "allow" \
    "git switch -c 2-feat-x"

run "T6 git commit -m with embedded keyword (anchor protect)" \
    "allow" \
    'git commit -m "ref to git worktree add -b 1-feat-x"'

run "T7 SKIP env var bypasses issue check" \
    "allow" \
    "git worktree add -b 999999-feat-x .claude/worktrees/x origin/main" \
    "CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1"

run "T8 BRANCH_TYPES extended (docs, issue#1 closed exists)" \
    "allow" \
    "git checkout -b 1-docs-readme" \
    "CLAUDE_HOOKS_BRANCH_TYPES=feat,fix,refactor,infra,docs"

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
exit "$FAIL"
