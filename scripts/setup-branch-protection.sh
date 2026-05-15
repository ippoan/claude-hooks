#!/usr/bin/env bash
# One-shot: enable branch protection on `master` so auto-merge has something
# to gate on. Re-runnable (the API is idempotent — last call wins).
#
# Required: `gh` CLI, authenticated as a repo admin
# (`gh auth login` with `repo` + `admin:repo_hook` scope).
#
# What it sets:
#   - Required status checks: `ci / shellcheck` + `ci / test (tests/test-worktree-naming-guard.sh)`
#     (the two jobs published by `.github/workflows/test.yml`)
#   - `strict: true`  — branches must be up to date before merge
#   - `enforce_admins: false` — admins can still bypass for emergencies
#   - `required_pull_request_reviews: null` — no review requirement (this
#     repo is solo-owner; auto-merge would deadlock with mandatory reviews)
#   - `required_linear_history: false` (squash merge is enough)
#   - `allow_force_pushes: false`, `allow_deletions: false`
#
# After this runs, also flip the repo-level "Allow auto-merge" toggle in
# Settings → General. (No API endpoint exposes that toggle as of writing.)
set -euo pipefail

OWNER="${OWNER:-yhonda-ohishi}"
REPO="${REPO:-claude-hooks}"
BRANCH="${BRANCH:-master}"

gh api -X PUT "repos/${OWNER}/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" \
  -f required_status_checks[strict]=true \
  -F required_status_checks[contexts][]='ci / shellcheck' \
  -F required_status_checks[contexts][]='ci / test (tests/test-worktree-naming-guard.sh)' \
  -F enforce_admins=false \
  -f required_pull_request_reviews= \
  -f restrictions= \
  -F required_linear_history=false \
  -F allow_force_pushes=false \
  -F allow_deletions=false \
  -F required_conversation_resolution=true

echo ""
echo "Done. Don't forget to also enable 'Allow auto-merge' in:"
echo "  https://github.com/${OWNER}/${REPO}/settings"
