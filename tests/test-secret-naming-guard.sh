#!/bin/bash
# Stdin-pipe test runner for secret-naming-guard.sh.
#
# 非ブロッキング warn hook なので、判定軸は deny/allow ではなく
# 「additionalContext を出した = warn」 / 「何も出さない = clean」。
#
# Works locally (run from repo root) and in CI (GITHUB_WORKSPACE = repo root).
# Requires: jq in PATH.
#
# Exit code = number of failures.
set -u

REPO_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOOK="$REPO_ROOT/secret-naming-guard.sh"

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

# run <name> <expected: warn|clean> <tool> <file_path> <content>
run() {
  local name="$1" expected="$2" tool="$3" file="$4" content="$5"
  local input out actual field

  field="content"
  [[ "$tool" == "Edit" ]] && field="new_string"

  input=$(jq -nc \
    --arg tool "$tool" \
    --arg file "$file" \
    --arg field "$field" \
    --arg content "$content" \
    '{tool_name: $tool, tool_input: ({file_path: $file} + {($field): $content})}')

  out=$("$HOOK" <<< "$input" 2>/dev/null)

  actual="clean"
  if echo "$out" | jq -e '.hookSpecificOutput.additionalContext // empty | length > 0' >/dev/null 2>&1; then
    actual="warn"
  fi

  if [[ "$actual" == "$expected" ]]; then
    echo "✓ $name → $actual"
    PASS=$((PASS+1))
  else
    echo "✗ $name → expected=$expected actual=$actual"
    FAIL=$((FAIL+1))
  fi
}

# --- A: wrangler secret_name (kebab-case) ---
run "A1 wrangler kebab ok"          clean Write "wrangler.jsonc" '"secret_name": "secrets-inventory-gcp-proxy-api-key"'
run "A2 wrangler SCREAMING warn"    warn  Write "wrangler.jsonc" '"secret_name": "SECRETS_INVENTORY_GCP_PROXY_API_KEY"'
run "A3 wrangler toml = warn"       warn  Write "wrangler.toml"  'secret_name = "Cf-Secrets-Store"'
run "A4 non-wrangler ignored"       clean Write "config.json"    '"secret_name": "SCREAMING_SNAKE_NAME"'
run "A5 wrangler Edit kebab ok"     clean Edit  "wrangler.toml"  'secret_name = "gh-org-secrets-write"'

# --- B1: --set-secrets / --update-secrets (SCREAMING_SNAKE) ---
run "B1 update-secrets ok"          clean Write "ci.yml" '--update-secrets=INVENTORY_API_KEY=SECRETS_INVENTORY_GCP_PROXY_API_KEY_STAGING:latest'
run "B2 update-secrets kebab warn"  warn  Write "ci.yml" '--update-secrets=INVENTORY_API_KEY=secrets-inventory-gcp-proxy-api-key:latest'
run "B3 set-secrets multi warn"     warn  Write "deploy.sh" '--set-secrets=A=GOOD_NAME:latest,B=bad-name:latest'

# --- B2: gcloud secrets create ---
run "C1 gcloud create ok"           clean Write "setup.sh" 'gcloud secrets create SECRETS_INVENTORY_GCP_PROXY_API_KEY --project=cloudsql-sv'
run "C2 gcloud create kebab warn"   warn  Write "setup.sh" 'gcloud secrets create secrets-inventory-gcp-proxy-api-key --project=cloudsql-sv'

# --- misc ---
run "D1 empty content clean"        clean Write "wrangler.toml" ''
run "D2 unrelated tool ignored"     clean Bash  ""              'gcloud secrets create bad-name'

echo ""
echo "PASS=$PASS FAIL=$FAIL"
exit "$FAIL"
