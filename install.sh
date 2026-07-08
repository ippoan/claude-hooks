#!/usr/bin/env bash
# One-shot installer for ippoan/claude-hooks + ippoan/claude-skills.
#
# Usage (CCoW Setup script — paste the next line into the env's Setup script
# field; runs ONCE per container, has full proxy network reach):
#
#   curl -fsSL https://raw.githubusercontent.com/ippoan/claude-hooks/main/install.sh | bash
#
# Local dev:
#
#   bash install.sh
#
# What it does:
#   1. Clones (or `git pull --ff-only` if already present) both repos under
#      ~/.claude/sources/{claude-hooks,claude-skills}.
#   2. Symlinks every `SKILL.md` directory found under claude-skills into
#      ~/.claude/skills/<name> so user-level skills auto-pick-up.
#   3. Registers `session-start-install-skills.sh` in
#      ~/.claude/settings.json with `CLAUDE_HOOKS_INSTALL_NETWORK=off`
#      so each SessionStart only re-symlinks (no proxy calls / no 502 risk).
#      Idempotent: re-runs replace the existing entry instead of duplicating.
#
# Network policy in CCoW:
#   - install.sh (= Setup script): proxy reach, clones everything.
#   - SessionStart hook: zero network. If `~/.claude/sources/*` were wiped
#     somehow, the hook logs it but does not try to re-fetch — re-run the
#     Setup script to repair.
#
# Opt-out env vars:
#   CLAUDE_HOOKS_SKIP_SETTINGS=1   # don't touch ~/.claude/settings.json
#   CLAUDE_HOOKS_HOOKS_URL=...     # private fork
#   CLAUDE_HOOKS_SKILLS_URL=...
#
# Idempotent. Safe to re-run. Exits 0 on partial network failure (keeps any
# existing checkouts).
set -euo pipefail

CLAUDE_DIR="${CLAUDE_DIR:-${HOME}/.claude}"
SOURCES_DIR="${CLAUDE_DIR}/sources"
SKILLS_DIR="${CLAUDE_DIR}/skills"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"

HOOKS_REPO_URL="${CLAUDE_HOOKS_HOOKS_URL:-https://github.com/ippoan/claude-hooks.git}"
SKILLS_REPO_URL="${CLAUDE_HOOKS_SKILLS_URL:-https://github.com/ippoan/claude-skills.git}"

mkdir -p "$SOURCES_DIR" "$SKILLS_DIR"

clone_or_pull() {
  local name="$1" url="$2"
  local dir="${SOURCES_DIR}/${name}"
  if [[ -d "${dir}/.git" ]]; then
    if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
      echo "  ↑ pulled ${name}"
    else
      echo "  ⚠ pull failed for ${name} (kept existing checkout)"
    fi
  else
    if git clone --depth=1 --quiet "$url" "$dir" 2>/dev/null; then
      echo "  ✓ cloned ${name}"
    else
      echo "  ⚠ clone failed for ${name} (${url})" >&2
      return 1
    fi
  fi
}

echo "claude-hooks installer:"
clone_or_pull claude-hooks "$HOOKS_REPO_URL" || true
clone_or_pull claude-skills "$SKILLS_REPO_URL" || true

# Symlink every skill dir into ~/.claude/skills.
linked=0
if [[ -d "${SOURCES_DIR}/claude-skills" ]]; then
  while IFS= read -r -d '' skill_md; do
    skill_dir="$(dirname "$skill_md")"
    skill_name="$(basename "$skill_dir")"
    target="${SKILLS_DIR}/${skill_name}"
    if [[ -L "$target" || ! -e "$target" ]]; then
      ln -sfn "$skill_dir" "$target"
      linked=$((linked + 1))
    fi
  done < <(find "${SOURCES_DIR}/claude-skills" \
              \( -path "${SOURCES_DIR}/claude-skills/.git" -prune \) -o \
              -name SKILL.md -print0 2>/dev/null)
fi
echo "  ✓ linked ${linked} skill(s) into ${SKILLS_DIR}"

# Register the SessionStart hook in ~/.claude/settings.json (offline mode).
# Skipped when CLAUDE_HOOKS_SKIP_SETTINGS=1, or when jq is unavailable.
register_session_hook() {
  local cmd="$1"
  local timeout="${2:-5000}"
  local env_json="${3:-{\}}"
  [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"
  # Idempotent merge: ensure SessionStart contains exactly one entry whose
  # `command` points at our hook. Other SessionStart hooks are preserved.
  local tmp="${SETTINGS_FILE}.tmp.$$"
  jq --arg cmd "$cmd" --argjson timeout "$timeout" --argjson env "$env_json" '
    .hooks //= {} |
    .hooks.SessionStart //= [] |
    # drop any prior entry that targets our hook (so re-runs replace, not stack)
    .hooks.SessionStart |= map(
      select((.hooks // []) | map(.command) | index($cmd) | not)
    ) |
    .hooks.SessionStart += [{
      hooks: [{
        type: "command",
        command: $cmd,
        timeout: $timeout,
        env: $env
      }]
    }]
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  echo "  ✓ registered SessionStart hook ${cmd##*/} in ${SETTINGS_FILE}"
}

register_all_session_hooks() {
  [[ "${CLAUDE_HOOKS_SKIP_SETTINGS:-0}" == "1" ]] && {
    echo "  ⊘ skipped settings.json (CLAUDE_HOOKS_SKIP_SETTINGS=1)"
    return 0
  }
  if ! command -v jq >/dev/null 2>&1; then
    echo "  ⚠ jq not installed — leaving ${SETTINGS_FILE} untouched" >&2
    return 0
  fi

  register_session_hook \
    '$HOME/.claude/sources/claude-hooks/session-start-install-skills.sh' \
    5000 \
    '{"CLAUDE_HOOKS_INSTALL_NETWORK":"off"}'

  # write-mcp-user-scope: register `ref-files-native` (worker `/mcp`) into
  # `~/.claude.json` `.mcpServers` so `folder_download_url` and friends
  # are reachable without going through the Rust relay binary. Reads the
  # MCP-JWT from the token cache that `session-start-install-mcp-relay.sh`
  # already maintains, so this hook is a no-op without that one running
  # first (we declare it second; SessionStart entries run in array order).
  register_session_hook \
    '$HOME/.claude/sources/claude-hooks/session-start-write-mcp-user-scope.sh' \
    5000 \
    '{}'
}
register_all_session_hooks

# Register PreToolUse hooks.
#  - pretooluse-open-multirepo-guard.sh (Skill matcher) — blocks
#    agent-synthesized `repos=` args on `Skill open-multirepo` (regression
#    caught at ippoan/mcp-relay-rs#9 Phase 4 session, 2026-05-20).
#  - clone-guard.sh (Bash matcher) — blocks `git clone` of a repo that is
#    already pre-cloned at /home/user/<name> (those pre-clones have a
#    proxy-auth remote; a plain HTTPS re-clone leaves the new copy unable to
#    push, forcing slow MCP-based pushes).
#  - proxy-push-guard.sh (Bash matcher) — blocks `git push` from a cwd
#    whose origin URL is not a CCoW local proxy. Detects the proxy 502
#    "repository not authorized" / git "could not read Username" pre-fail
#    and steers the agent to either the pre-clone or to AskUserQuestion
#    (= scope 追加 / open-multirepo handover) before wasting cycles
#    (Refs ippoan/ref-files-worker#6 session, 2026-05-25).
#  - pre-pr-rebase-guard.sh (mcp__github__create_pull_request matcher) —
#    head が origin/<base> より遅れた (out-of-date) まま PR を作るのを deny。
#    post-push-rebase-check.sh の非ブロッキング警告を無視して PR を立てる事故
#    (GitHub "This branch is out-of-date with the base branch") を防ぐ。
#  - pr-refs-link-guard.sh (mcp__github__create_pull_request matcher) — blocks
#    PR creation when the body carries no issue ref (`Refs #N` 等). Without it
#    the issue can't be traced back from the PR (GitHub only links via closing
#    keywords) and falls out of ci-dashboard's release-close reverse-lookup /
#    /issues tracking (Refs ippoan/HealthConnectReader#14/#16/#18 close 漏れ).
#  - pr-ci-shape-guard.sh (mcp__github__create_pull_request matcher) — blocks
#    PR creation on ippoan/ohishi-exp repos whose head branch has no
#    ci-shape-report.yml caller. ci-dashboard /ci-matrix silently drops repos
#    without the caller from its list instead of flagging them, which delayed
#    detection of a rollout gap (Refs ippoan/ci-dashboard#393). Opt-out:
#    `[no-ci-shape]` in title/body.
#  - secret-naming-guard.sh (Write|Edit matcher) — **非ブロッキング**で secret
#    命名規約違反を警告。CF Secrets Store `secret_name` は kebab-case、GCP Secret
#    Manager 名は SCREAMING_SNAKE_CASE (claude-skills `secret-naming` skill が SoT)。
#    両プラットフォームとも rename 不可 + alias は rotation 2 重 bump で drift する
#    ため、名前は揃えず規約で固定し違反を Edit/Write 時点で気付かせ随時修正する
#    (Refs ippoan/secrets-inventory#23).
#  - pre-push-repo-checks.sh (Bash matcher) — repo toplevel に
#    scripts/pre-push-checks.sh があれば `git push` 前に実行し、fail なら deny。
#    bazel BUILD 配線漏れ等「cargo では捕まらず CI まで漏れる」検査をローカル
#    数秒で止める repo opt-in の汎用フック (Refs ippoan/rust-alc-api#539)。
#  - pr-push-allowlist-guard.sh (Bash matcher) — blocks `pr-push.sh` 起動を
#    repo が wt-direct-push allowlist (config/direct-push-ok.txt) に登録済の時
#    deny し /wt-direct-push に誘導する。allowlist repo は branch protection /
#    auto-merge 未設定で、/pr-push すると PR が塩漬けのまま tag-release が古い
#    main から build → release から changes が漏れる (Refs ippoan/github-mcp-
#    server-rs#28, archived; monorepo: ippoan/mcp-relay-rs)。
register_pretooluse_hooks() {
  [[ "${CLAUDE_HOOKS_SKIP_SETTINGS:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"

  # `entries` is a JSON array of {matcher, command, timeout} tuples. Each
  # gets registered idempotently: any prior entry with the same (matcher,
  # command) pair is dropped first so re-runs replace instead of stacking.
  local entries
  entries=$(jq -n '[
    {
      matcher: "Skill",
      command: "$HOME/.claude/sources/claude-hooks/pretooluse-open-multirepo-guard.sh",
      timeout: 5
    },
    {
      matcher: "Bash",
      command: "$HOME/.claude/sources/claude-hooks/clone-guard.sh",
      timeout: 5
    },
    {
      matcher: "Bash",
      command: "$HOME/.claude/sources/claude-hooks/proxy-push-guard.sh",
      timeout: 5
    },
    {
      matcher: "mcp__github__create_pull_request",
      command: "$HOME/.claude/sources/claude-hooks/pre-pr-rebase-guard.sh",
      timeout: 10
    },
    {
      matcher: "mcp__github__create_pull_request",
      command: "$HOME/.claude/sources/claude-hooks/pr-refs-link-guard.sh",
      timeout: 10
    },
    {
      matcher: "mcp__github__create_pull_request",
      command: "$HOME/.claude/sources/claude-hooks/pr-ci-shape-guard.sh",
      timeout: 10
    },
    {
      matcher: "Write|Edit",
      command: "$HOME/.claude/sources/claude-hooks/secret-naming-guard.sh",
      timeout: 10
    },
    {
      matcher: "Bash",
      command: "$HOME/.claude/sources/claude-hooks/pr-push-allowlist-guard.sh",
      timeout: 5
    },
    {
      matcher: "Bash",
      command: "$HOME/.claude/sources/claude-hooks/pre-push-repo-checks.sh",
      timeout: 60
    }
  ]')

  local tmp="${SETTINGS_FILE}.tmp.$$"
  jq --argjson entries "$entries" '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    # 1) drop any prior entry that matches one of ours (same matcher + same command)
    reduce $entries[] as $e (
      .;
      .hooks.PreToolUse |= map(
        select(
          (.matcher != $e.matcher) or
          ((.hooks // []) | map(.command) | index($e.command) | not)
        )
      )
    ) |
    # 2) append fresh entries
    .hooks.PreToolUse += ($entries | map({
      matcher: .matcher,
      hooks: [{
        type: "command",
        command: .command,
        timeout: .timeout
      }]
    }))
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  echo "  ✓ registered PreToolUse hooks in ${SETTINGS_FILE} (open-multirepo guard, clone guard, proxy-push guard, pr-rebase guard, pr-refs-link guard, pr-ci-shape guard, secret-naming guard, pr-push-allowlist guard, pre-push-repo-checks)"
}
register_pretooluse_hooks

# permissions.deny の集中管理。
#
# claude.ai built-in の GitHub MCP connector (= `@modelcontextprotocol/server-
# github` 由来の `mcp__github__*` tools) のうち、CCoW 環境では事実上ほぼ
# 害悪 (= /home/user/<repo> に pre-clone が常駐していて git push の方が
# 30× token 効率が良い) な write tool を deny する。
#
# 対象:
#   - mcp__github__create_or_update_file
#       single file の commit。ローカル git で代替可能。
#   - mcp__github__push_files
#       multi file commit。ローカル git で代替可能。
#
# どちらも tool call の `content` parameter に **ファイル全文** を JSON 文字列
# として埋め込む仕様で、33 KB のファイルを 1 回 push すると ~10K token を
# 消費する。同じ tool で同じファイルを修正再 push すると線形に積み上がる
# (実例: ippoan/secrets-inventory-gcp#23 で main.go + main_test.go を MCP push
# したら ~100KB / ~25K token を 1 PR で焼いた)。
#
# 非対称: `mcp__github__create_pull_request` 等の **state mutation tool** や、
# `mcp__github__get_file_contents` 等の **read tool** はそのまま許可する。
# あくまで file 全文を載せる write 系だけが対象。
#
# 緊急時 override は 2 通り:
#   - 該当 deny entry を ~/.claude/settings.json から手で消す
#   - CLAUDE_HOOKS_SKIP_SETTINGS=1 で installer を skip して別ルートで設定
register_permissions_deny() {
  [[ "${CLAUDE_HOOKS_SKIP_SETTINGS:-0}" == "1" ]] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$SETTINGS_FILE" ]] || echo '{}' > "$SETTINGS_FILE"

  local denies
  denies=$(jq -n '[
    "mcp__github__create_or_update_file",
    "mcp__github__push_files"
  ]')

  local tmp="${SETTINGS_FILE}.tmp.$$"
  jq --argjson denies "$denies" '
    .permissions //= {} |
    .permissions.deny //= [] |
    # union: 既存 deny は温存し、未登録のものだけ append (idempotent)
    .permissions.deny = (
      (.permissions.deny + $denies) | unique
    )
  ' "$SETTINGS_FILE" > "$tmp" && mv "$tmp" "$SETTINGS_FILE"
  echo "  ✓ registered permissions.deny in ${SETTINGS_FILE} (mcp__github write tools)"
}
register_permissions_deny

echo ""
echo "Done. SessionStart hook will run offline on every session and re-link"
echo "skills from ${SOURCES_DIR}/. To repair after a container rebuild,"
echo "re-run this installer from the Setup script."
