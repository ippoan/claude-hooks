#!/bin/bash
# PreToolUse hook: deny `git clone` of a repo that is already pre-cloned at
# `/home/user/<repo>`.
#
# Why: in CCoW environments the runner pre-clones a repo at `/home/user/<name>`
# with a credential-bearing proxy remote
# (`http://local_proxy@127.0.0.1:NNNN/git/<owner>/<name>`). A subsequent plain
# `git clone https://github.com/<owner>/<name>.git /tmp/...` works for **fetch**
# but leaves the new clone with a credential-less HTTPS remote, so any later
# `git push` fails with
#   fatal: could not read Username for 'https://github.com'
# and the agent then falls back to pushing via MCP API calls that embed the
# whole file content as a JSON parameter — slow and token-heavy.
#
# This guard blocks the manual clone and tells the agent to `cd` into the
# pre-existing clone instead.
#
# Pass-through cases (NOT blocked):
#   - the repo isn't pre-cloned at `/home/user/<name>` (= a genuine external
#     dependency / one-off public-repo lookup)
#   - the command is `git clone --depth ... ~/.claude/...` etc. — anything
#     that targets a destination *outside* the pre-clone area (the agent can
#     always re-clone elsewhere; the guard only fires when there is a working
#     pre-clone to redirect to)
#   - the URL is a worktree-style local path (`/home/user/.../`) — those are
#     legitimate local clones
#
# Trigger: PreToolUse with matcher "Bash".

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Fast-path: command doesn't contain `git clone` at all.
if ! echo "$COMMAND" | grep -qE '(^|[[:space:]&;|])git[[:space:]]+clone\b'; then
  exit 0
fi

# Extract the first http(s) / git@ argument that looks like a repo URL. We
# don't try to be clever about quoting — the typical `git clone <url> [<dir>]`
# pattern is enough. If we can't find a URL we let the command through.
URL=$(echo "$COMMAND" \
  | grep -oE '(https?://[^[:space:]]+|git@[^[:space:]]+|ssh://[^[:space:]]+)' \
  | head -n 1)
if [ -z "$URL" ]; then
  exit 0
fi

# Skip the `http://local_proxy@...` URLs — those ARE the proxy remotes the
# pre-clone uses, so a deliberate clone via the proxy is fine.
if echo "$URL" | grep -q 'local_proxy@'; then
  exit 0
fi

# Derive `<name>` from the URL's last path segment, dropping `.git` if present.
REPO_NAME=$(echo "$URL" \
  | sed -E 's|[/:]+$||; s|\.git$||' \
  | awk -F'[/:]' '{print $NF}')
if [ -z "$REPO_NAME" ]; then
  exit 0
fi

PRE_CLONE_DIR="/home/user/${REPO_NAME}"
if [ ! -d "${PRE_CLONE_DIR}/.git" ]; then
  # No pre-existing clone for this name → let the command through.
  exit 0
fi

# Block: tell the agent to use the pre-existing clone.
jq -n \
  --arg url "$URL" \
  --arg dir "$PRE_CLONE_DIR" \
  --arg name "$REPO_NAME" '{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": (
      "git clone " + $url + " is blocked: " + $name +
      " is already pre-cloned at " + $dir +
      " with a credential-bearing proxy remote. A fresh `git clone` over plain HTTPS would leave the new clone without push credentials, forcing slow MCP-based pushes. Use the pre-existing clone instead:\n\n" +
      "  cd " + $dir + "\n" +
      "  git fetch origin\n" +
      "  git checkout -b <new-branch> origin/main   # or `git checkout <existing-branch>`\n\n" +
      "If you genuinely need a separate working copy, use `git worktree add` from " + $dir + " (the worktree inherits the same proxy remote)."
    )
  }
}'
exit 0
