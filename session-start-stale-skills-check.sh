#!/usr/bin/env bash
# SessionStart hook: stale yhonda-ohishi/claude-skills checkout を探索する。
#
# Background:
#   skill repo は ippoan/claude-skills に移行済み (claude-md / claude-hooks の
#   bootstrap も切り替え済み)。だが古い env で
#   `~/.claude/sources/claude-skills/.git/config` の origin remote が
#   yhonda-ohishi のまま残っていると、claude-hooks/install.sh 経由 (local dev)
#   の `pull --ff-only` は yhonda 側を fetch し続け、新規 skill
#   (ippoan-infra-map など) が反映されない。
#
#   session-start-install-hooks.sh は CCoW container 内では fetch 前に
#   `remote set-url origin` で自動 reseat するが、本 hook はそれが効かない
#   経路 (local dev / 別 env / 自前 git pull) も網羅して explicit に検知する。
#
# Scan targets:
#   - ~/.claude/sources/*/        (skills / hooks bootstrap source)
#   - /home/user/*/               (CCoW attached repo) — CLAUDE_HOOKS_SCAN_DIRS で上書き可
#
# Match:
#   origin remote URL に `yhonda-ohishi/claude-skills` を含む checkout
#
# 出力:
#   stale が 1 つでもあれば warning + reseat コマンドを additionalContext に inject。
#   clean なら 1 行だけ報告 (動作確認用)。
#
# env override:
#   CLAUDE_HOME              ~/.claude の path (default: $HOME/.claude)
#   CLAUDE_HOOKS_SCAN_DIRS   attached repo の親 dir, space 区切り (default: /home/user)
set -u

CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SOURCES_DIR="$CLAUDE_HOME/sources"
SCAN_DIRS="${CLAUDE_HOOKS_SCAN_DIRS:-/home/user}"

emit() {
  python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":sys.argv[1]}}))' "$1"
}

scan_targets=()
if [ -d "$SOURCES_DIR" ]; then
  for d in "$SOURCES_DIR"/*/; do
    [ -d "${d}.git" ] && scan_targets+=("${d%/}")
  done
fi
for parent in $SCAN_DIRS; do
  [ -d "$parent" ] || continue
  for d in "$parent"/*/; do
    [ -d "${d}.git" ] && scan_targets+=("${d%/}")
  done
done

stale=()
for dir in "${scan_targets[@]}"; do
  url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *yhonda-ohishi/claude-skills*)
      stale+=("${dir} -> ${url}")
      ;;
  esac
done

if [ ${#stale[@]} -eq 0 ]; then
  emit "stale-skills-check: no yhonda-ohishi/claude-skills remotes found (scanned ${#scan_targets[@]} checkout(s))"
  exit 0
fi

msg="stale yhonda-ohishi/claude-skills checkout(s) detected — skill repo は ippoan/claude-skills に移行済み:"
for s in "${stale[@]}"; do
  msg="${msg}"$'\n'"  - ${s}"
done
msg="${msg}"$'\n'"reseat 手順:"
msg="${msg}"$'\n'"  git -C <dir> remote set-url origin https://github.com/ippoan/claude-skills.git"
msg="${msg}"$'\n'"  git -C <dir> fetch --depth 1 origin && git -C <dir> reset --hard origin/main"

emit "$msg"
