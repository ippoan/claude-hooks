# claude-hooks

Claude Code 用 hook スクリプト集 (PreToolUse / PostToolUse / SessionStart / Notification)。

各スクリプトは `~/.claude/settings.json` の `hooks` セクションから呼び出される。**`~/.claude/settings.json` は git 管理外** のため、登録例は本 README に残す。

## Hook 一覧

### PreToolUse — Bash matcher

| Hook | 役割 |
|---|---|
| `bash-edit-guard.sh` | `sed -i` 等で source を直接書き換える操作を block (Edit/Write 経由に誘導) |
| `branch-switch-guard.sh` | `git checkout -b <new> main` を block (origin/main + worktree に誘導) |
| `deploy-guard.sh` | `wrangler deploy` / `deploy.sh` 直接実行を block (CI / tag-release に誘導) |
| `git-safe-push.sh` | `git commit --amend` / `git push --force` を block |
| `no-direct-frontend-dev.sh` | worktree 内 `npm run dev` / `nuxt dev` / `wrangler dev` を block (`/wt-quick` 経由に誘導) |
| `no-local-merge.sh` | `gh pr merge` のローカル実行を block (CI auto-merge に任せる) |
| `pr-create-guard.sh` | `gh pr create` 直叩きを block (`/pr-push` skill 経由に誘導) |
| `pr-state-guard.sh` | merge / close 済 PR への push を block |
| `tag-release-userprompt-guard.sh` | tag-release.sh / `git tag v*` / `gh workflow run tag-release.yml` / `/tag-release` skill を user 明示指示なしに block |
| `worktree-auto-gc.sh` | `git worktree add` 前に merged worktree を auto-GC |
| `worktree-fetch-guard.sh` | `git worktree add` 前に `origin/main` 鮮度を確認 |
| **`worktree-naming-guard.sh`** | **branch / worktree 名が `<issue-number>-<type>-<short-description>` か検証 + issue 実在 check (本 README 末尾参照)** |
| `worktree-guard.sh` | `git worktree remove` の安全実行 (cwd 検証) |

### PreToolUse — Edit / Write matcher

| Hook | 役割 |
|---|---|
| `worktree-edit-guard.sh` | protected repo の main worktree への Edit / Write を block (worktree 経由に誘導) |

### PreToolUse — Skill matcher

| Hook | 役割 |
|---|---|
| `tag-release-userprompt-guard.sh` | `/tag-release` skill の Claude autonomous 呼び出しを block (Bash と同じ script で兼用) |

### PostToolUse — Bash matcher

| Hook | 役割 |
|---|---|
| `post-commit-status.sh` | commit 後の status 確認 |
| `post-pr-check.sh` | `gh pr create` 後に conflict / CI start を auto-check |
| `post-pr-remove-worktree.sh` | PR 作成成功後に worktree を auto-remove |
| `post-push-ci-check.sh` | `git push` 後に CI 開始を確認 |

### SessionStart

| Hook | 役割 |
|---|---|
| `session-start-memory-baseline.sh` | 前 session 以降に memory file が増えていれば警告 |
| `session-start-sandbox-hint.sh` | Backend + Frontend 同時改修 (Incus + wt-quick) workflow hint を inject |
| `session-start-secret-scan.sh` | `~/` 配下の `.env` backup 漏れを scan |
| `session-start-install-skills.sh` | `yhonda-ohishi/{claude-skills,claude-hooks}` を `~/.claude/sources/` に shallow clone + skill を `~/.claude/skills/<name>` に symlink (TTL 1h、idempotent) |

### Notification

| Hook | 役割 |
|---|---|
| `permission-notify.sh` | Claude Code 通知を ntfy.sh に push |
| `claude-notifier-on-{permission,question,stop}.js` | VSCode 拡張用 notification handler |

### Utility (non-hook)

| File | 役割 |
|---|---|
| `worktree-cleanup.sh` | merged worktree を手動で一括削除するツール |

---

## `worktree-naming-guard.sh` 詳細

### 仕様

branch / worktree 作成時に以下を検証する PreToolUse hook (matcher: `Bash`):

1. **形式 (regex)**: `^[0-9]+-(feat|fix|refactor|infra)-[a-z0-9-]+$`
2. **issue 実在**: 先頭の `<N>` が origin repo に実在 (closed 含む) — `gh issue view` で確認

検出する command (anchor `(^|[;&|][[:space:]]*)` 付き — `git commit -m "..."` 内の引数文字列を誤検出しない):

- `git worktree add ... [-b] <branch>`
- `git checkout -b <branch>`
- `git switch -c <branch>`

deny 時は `hookSpecificOutput.permissionDecision = "deny"` の JSON を stdout に出力。

### 設定例

`~/.claude/settings.json` の `hooks.PreToolUse` で matcher `Bash` の hooks 配列に追加 (既存 `worktree-fetch-guard.sh` / `worktree-auto-gc.sh` より **後** に置く):

```jsonc
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          // ... 既存 hook ...
          { "type": "command", "command": "/home/yhonda/.claude/hooks/worktree-fetch-guard.sh" },
          { "type": "command", "command": "/home/yhonda/.claude/hooks/worktree-auto-gc.sh" },
          { "type": "command", "command": "/home/yhonda/.claude/hooks/worktree-naming-guard.sh", "timeout": 10 }
        ]
      }
    ]
  }
}
```

`timeout` を 10s に設定 (gh API 呼び出しのため、他 hook の 5s より長め)。

### 環境変数

| 変数 | 既定値 | 用途 |
|---|---|---|
| `CLAUDE_HOOKS_BRANCH_TYPES` | `feat,fix,refactor,infra` | 許容 type を CSV で上書き (例: `feat,fix,refactor,infra,docs`) |
| `CLAUDE_HOOKS_SKIP_ISSUE_CHECK` | (unset) | `1` を set すると issue 実在 check を skip (regex は引き続き検証) |

**`gh` 失敗時は fail-closed (deny)**。network 障害 / 未認証 / repo 不在で `gh issue view` が失敗した場合は意図的に block する。回避するには `CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1` を明示 export する。

### 手動テスト

```bash
HOOK=~/.claude/hooks/worktree-naming-guard.sh
CWD=~/.claude/hooks  # claude-hooks repo (origin = yhonda-ohishi/claude-hooks)

# T1: 正常 (issue #2 実在)
echo '{"tool_name":"Bash","tool_input":{"command":"git worktree add -b 2-feat-x .claude/worktrees/x origin/master"},"cwd":"'$CWD'"}' | $HOOK
# → exit 0, 出力なし (allow)

# T2: regex 違反
echo '{"tool_name":"Bash","tool_input":{"command":"git worktree add -b fix/foo .claude/worktrees/x origin/main"},"cwd":"'$CWD'"}' | $HOOK
# → exit 0, JSON deny 出力

# T3: issue 不在 (999999)
echo '{"tool_name":"Bash","tool_input":{"command":"git worktree add -b 999999-feat-x .claude/worktrees/x origin/main"},"cwd":"'$CWD'"}' | $HOOK
# → deny

# T4: type 不正
echo '{"tool_name":"Bash","tool_input":{"command":"git checkout -b 1-typo-foo"},"cwd":"'$CWD'"}' | $HOOK
# → deny

# T5: switch -c 正常
echo '{"tool_name":"Bash","tool_input":{"command":"git switch -c 2-feat-x"},"cwd":"'$CWD'"}' | $HOOK
# → allow

# T6: anchor 効果 (commit message 内の文字列を誤検出しない)
echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m \"ref to git worktree add -b 1-feat-x\""},"cwd":"'$CWD'"}' | $HOOK
# → allow

# T7: SKIP env var で issue check 回避
CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1 \
  echo '{"tool_name":"Bash","tool_input":{"command":"git worktree add -b 999999-feat-x .claude/worktrees/x origin/main"},"cwd":"'$CWD'"}' | env CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1 $HOOK
# → allow

# T8: BRANCH_TYPES 拡張 (docs 許可、issue #1 は closed = 実在として OK)
CLAUDE_HOOKS_BRANCH_TYPES=feat,fix,refactor,infra,docs \
  echo '{"tool_name":"Bash","tool_input":{"command":"git checkout -b 1-docs-readme"},"cwd":"'$CWD'"}' | env CLAUDE_HOOKS_BRANCH_TYPES=feat,fix,refactor,infra,docs $HOOK
# → allow
```

---

## サーバサイド検証 (推奨)

ローカル hook はバイパス可能 (Claude を介さない手作業 push 等) のため、各 repo の `.github/workflows/` に branch 名検証 job を併用することを推奨:

```yaml
on:
  pull_request:
    types: [opened, edited, synchronize]
jobs:
  validate-branch-name:
    runs-on: ubuntu-latest
    steps:
      - run: |
          BRANCH="${{ github.head_ref }}"
          if [[ ! "$BRANCH" =~ ^[0-9]+-(feat|fix|refactor|infra)-[a-z0-9-]+$ ]]; then
            echo "::error::Branch name '$BRANCH' violates policy (<issue-number>-<type>-<short-description>)"
            exit 1
          fi
```

---

## 関連

- 規約策定: [yhonda-ohishi/claude-skills#3](https://github.com/yhonda-ohishi/claude-skills/issues/3)
- 本 hook の issue: [yhonda-ohishi/claude-hooks#2](https://github.com/yhonda-ohishi/claude-hooks/issues/2)

---

## `session-start-install-skills.sh` 詳細

### 仕様

SessionStart 時に `yhonda-ohishi/claude-skills` と `yhonda-ohishi/claude-hooks` を `~/.claude/sources/` に shallow clone (or `git pull --ff-only`) し、claude-skills 内の各 `SKILL.md` を `~/.claude/skills/<skill-name>` に symlink する。

- **配置先**:
  - sources: `~/.claude/sources/{claude-skills,claude-hooks}` (shallow git checkout)
  - skill symlinks: `~/.claude/skills/<name>` → `~/.claude/sources/claude-skills/.../<name>`
- **idempotent**: 既存 checkout は `git pull --ff-only`、既存 symlink は再 link、既存の非 symlink (= ユーザが手書きした skill) は触らない
- **TTL**: 既定 1h (`CLAUDE_HOOKS_INSTALL_TTL` 秒で上書き)。TTL 内は network sync を skip し、symlink 更新のみ実施
- **fail-open**: clone/pull 失敗時もセッションは継続 (additionalContext にエラー記録)
- **hook 側 settings.json は変更しない**: hooks の登録は `~/.claude/settings.json` を user が手動で編集する (既存方針のまま)

### 設定例

`~/.claude/settings.json` の `hooks.SessionStart` に追加:

```jsonc
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "/home/yhonda/.claude/hooks/session-start-install-skills.sh", "timeout": 30 }
        ]
      }
    ]
  }
}
```

`timeout` は 30s 推奨 (初回 clone のため、他 SessionStart hook の 5–10s より長め)。

### 環境変数

| 変数 | 既定値 | 用途 |
|---|---|---|
| `CLAUDE_HOOKS_INSTALL_TTL` | `3600` | network sync を skip する TTL (秒) |
| `CLAUDE_HOOKS_SKILLS_URL` | `https://github.com/yhonda-ohishi/claude-skills.git` | claude-skills の clone URL を上書き (private fork 等) |
| `CLAUDE_HOOKS_HOOKS_URL`  | `https://github.com/yhonda-ohishi/claude-hooks.git`  | claude-hooks の clone URL を上書き |

### 手動テスト

```bash
HOOK=~/.claude/hooks/session-start-install-skills.sh

# T1: 初回実行 (clone)
rm -rf ~/.claude/sources ~/.claude/.install-skills-marker
echo '{"source":"startup","cwd":"'$HOME'"}' | $HOOK | jq -r '.hookSpecificOutput.additionalContext'
# → "cloned claude-skills" / "cloned claude-hooks" / "skills linked: N"

# T2: TTL 内 (network skip)
echo '{}' | $HOOK | jq -r '.hookSpecificOutput.additionalContext'
# → "fresh within TTL (3600s) — skipped network sync"

# T3: TTL 切れ (pull)
rm -f ~/.claude/.install-skills-marker/last-run
echo '{}' | $HOOK | jq -r '.hookSpecificOutput.additionalContext'
# → "pulled claude-skills" (差分なしでも exit 0)
```
