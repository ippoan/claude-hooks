#!/bin/bash
# PostToolUse hook: after `gh pr create` or `mcp__github__create_pull_request`
# completes, detect the new PR, check that CI actually triggered, and emit a
# `hookSpecificOutput` that tells Claude to start watching the run in the
# background (`gh run watch <id> --exit-status`).
#
# Why a hook (vs. asking Claude every time):
#   - PR-create → CI-watch is mechanical; the user wants it to happen
#     unconditionally without typing "now watch CI"
#   - `workflow_dispatch` is intentionally disabled on some repos (e.g.
#     github-mcp-server-rs#56), so a PR push is the only trigger path —
#     missing CI means the PR can't merge, which is exactly the failure
#     mode this hook surfaces immediately
#   - `gh run watch` blocks until terminal status, which we want in a
#     background subprocess (Claude can keep working in parallel)
#
# Output channels:
#   - `hookSpecificOutput.additionalContext` for every branch (info / warn /
#     instruction). Stderr is NOT used because Claude doesn't necessarily
#     surface stderr from PostToolUse hooks in the conversation.
#
# Triggers (settings.json `PostToolUse.matcher`):
#   - "Bash"                              — covers `gh pr create`
#   - "mcp__github__create_pull_request"  — covers MCP-side PR creation
#
# Side effect on the repo allowlist:
#   When the new PR's repo has a protected `main`, this hook also appends the
#   repo root to `~/.claude/protected-repos.txt` so other guards (e.g.
#   `git-safe-push.sh`) know main is protected for that repo. This is
#   non-essential and silently best-effort.

set -u

INPUT=$(cat)

emit() {
  # $1: additionalContext string
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":sys.argv[1]}}))' "$1"
}

# Pull a PR URL from the tool output. Matches both shapes:
#   gh pr create stdout: "https://github.com/owner/repo/pull/123"
#   mcp__github__create_pull_request JSON: {"url":"https://github.com/owner/repo/pull/123"}
PR_URL=$(echo "$INPUT" | grep -oE 'https://github\.com/[^/]+/[^/]+/pull/[0-9]+' | head -1)
if [ -z "$PR_URL" ]; then
  # Not a PR-creating tool result — nothing to do, fast-path exit.
  exit 0
fi

REPO=$(echo "$PR_URL" | sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/.*|\1|')
PR_NUM=$(echo "$PR_URL" | sed -E 's|.*/pull/([0-9]+)|\1|')

# Give GitHub a moment to register the PR + kick off workflows.
sleep 3

# ── 0. Protected-repo allowlist (best-effort, non-blocking) ──────────────
PROTECTED=$(gh api "repos/$REPO/branches/main" --jq '.protected' 2>/dev/null || true)
if [ "$PROTECTED" = "true" ]; then
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null || true)
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$REPO_ROOT" ]; then
    CONF="$HOME/.claude/protected-repos.txt"
    mkdir -p "$(dirname "$CONF")"
    touch "$CONF"
    grep -qxF "$REPO_ROOT" "$CONF" || echo "$REPO_ROOT" >> "$CONF"
  fi
fi

# ── 1. Mergeability ──────────────────────────────────────────────────────
MERGEABLE=$(gh pr view "$PR_NUM" --repo "$REPO" --json mergeable --jq '.mergeable' 2>/dev/null || true)
if [ "$MERGEABLE" = "CONFLICTING" ]; then
  emit "⚠️ PR #$PR_NUM ($REPO) has merge conflicts. Rebase against main before CI can run."
  exit 0
fi

# ── 2. CI run detection ──────────────────────────────────────────────────
# Give the workflow trigger another beat to register on GitHub's side.
sleep 5

BRANCH=$(gh pr view "$PR_NUM" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || true)
if [ -z "$BRANCH" ]; then
  emit "⚠️ PR #$PR_NUM ($REPO): could not resolve head branch — check that the PR exists and you have repo access."
  exit 0
fi

# Look at the most recent run on the PR's branch. We pull databaseId + status
# in one shot so we can fork on status without a second API call.
RUN_INFO=$(gh run list --repo "$REPO" --branch "$BRANCH" --limit 1 \
  --json databaseId,status,name --jq '.[0] | "\(.databaseId)\t\(.status)\t\(.name)"' 2>/dev/null || true)
RUN_ID=$(echo "$RUN_INFO" | awk -F'\t' '{print $1}')
RUN_STATUS=$(echo "$RUN_INFO" | awk -F'\t' '{print $2}')
RUN_NAME=$(echo "$RUN_INFO" | awk -F'\t' '{print $3}')

if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  emit "⚠️ PR #$PR_NUM ($REPO): no CI run detected on branch \`$BRANCH\`.
Possible causes:
  - workflow file's \`on: pull_request\` / \`on: push\` filters exclude this branch / path
  - workflow_dispatch-only workflow (no auto trigger)
  - the PR's head repo doesn't expose the required workflow
Check \`.github/workflows/*.yml\` triggers, then re-push or open via UI to re-trigger."
  exit 0
fi

# ── 3. Auto-suggest ci-watch when CI is live ─────────────────────────────
case "$RUN_STATUS" in
  in_progress|queued|waiting|requested|pending)
    emit "✓ PR #$PR_NUM ($REPO) — CI run detected: \`$RUN_NAME\` ($RUN_STATUS, id=$RUN_ID)
→ Watch CI in the background:
    gh run watch $RUN_ID --repo $REPO --exit-status
  Run that with \`run_in_background: true\` so you can keep working; the run will surface its terminal status (success / failure) as a background notification."
    ;;
  completed)
    # Already finished by the time the hook fires (rare for first PR-create
    # but possible on fast-CI repos). Surface terminal conclusion if we can.
    CONCLUSION=$(gh run view "$RUN_ID" --repo "$REPO" --json conclusion --jq '.conclusion' 2>/dev/null || echo "unknown")
    emit "✓ PR #$PR_NUM ($REPO) — CI already completed: $CONCLUSION (run id=$RUN_ID). No watch needed."
    ;;
  *)
    emit "? PR #$PR_NUM ($REPO) — CI status: $RUN_STATUS (id=$RUN_ID). Inspect with \`gh run view $RUN_ID --repo $REPO\`."
    ;;
esac

exit 0
