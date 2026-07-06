#!/bin/bash
# Stdin-pipe test runner for pre-tool-claude-md-size.sh.
# Works locally (from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/pre-tool-claude-md-size.sh"

[[ -x "$HOOK" ]] || { echo "ERROR: hook not executable: $HOOK" >&2; exit 99; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not installed" >&2; exit 99; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not installed" >&2; exit 99; }

PASS=0
FAIL=0
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# run <name> <expect: deny|allow> <json-input>
run() {
  local name="$1" expect="$2" input="$3"
  local out decided
  out=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null)
  if printf '%s' "$out" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    decided="deny"
  else
    decided="allow"
  fi
  if [ "$decided" = "$expect" ]; then
    echo "  PASS: $name (=$decided)"; PASS=$((PASS+1))
  else
    echo "  FAIL: $name (expected $expect, got $decided)"; FAIL=$((FAIL+1))
  fi
}

j() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1"; }

OVER=$(python3 -c "print('y'*2500)")

run "write over-limit CLAUDE.md -> deny" deny \
  "$(j "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/home/user/foo/CLAUDE.md\",\"content\":\"$OVER\"}}")"
run "write under-limit CLAUDE.md -> allow" allow \
  "$(j '{"tool_name":"Write","tool_input":{"file_path":"/home/user/foo/CLAUDE.md","content":"# hi\nshort"}}')"
run "write non-CLAUDE.md -> allow" allow \
  "$(j "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/home/user/foo/README.md\",\"content\":\"$OVER\"}}")"
run "exempt marker -> allow" allow \
  "$(j "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/home/user/foo/CLAUDE.md\",\"content\":\"claude-md-size-exempt $OVER\"}}")"
run ".claude path -> allow" allow \
  "$(j "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/root/.claude/CLAUDE.md\",\"content\":\"$OVER\"}}")"

# Edit cases against a real over-limit temp file
EDIT_FILE="$TMPDIR_T/CLAUDE.md"
python3 -c "open('$EDIT_FILE','w').write('# Big\n'+'DETAIL '*400)"
run "edit keeps over-limit -> deny" deny \
  "$(j "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$EDIT_FILE\",\"old_string\":\"# Big\",\"new_string\":\"# Still Big\"}}")"
run "edit trims under-limit -> allow" allow \
  "$(j "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$EDIT_FILE\",\"old_string\":\"$(python3 -c "print('DETAIL '*400,end='')")\",\"new_string\":\"small\"}}")"

echo "  ---- claude-md-size-guard: $PASS passed, $FAIL failed ----"
exit "$FAIL"
