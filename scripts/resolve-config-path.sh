#!/usr/bin/env bash
# resolve-config-path.sh — print the effective `.claude/24hour-ClaudeCode.config.json` path.
#
# Search order:
#   1. $CLAUDE_PROJECT_DIR/.claude/24hour-ClaudeCode.config.json (always preferred)
#   2. If $CLAUDE_PROJECT_DIR is a git worktree, fall back to the main checkout's same
#      file. Onboarding runs on the main checkout (so workflow YAMLs land on the
#      default branch); worktrees inherit that config without re-onboarding.
#   3. Otherwise, return path #1 verbatim (the caller's `[[ -f ... ]]` will fail).
#
# Why: setup writes `.claude/24hour-ClaudeCode.config.json` to the main checkout
# but does NOT commit it to git, so a worktree created after onboarding has no
# local copy. Without this fallback, every worktree session would falsely report
# "onboarding incomplete" — wasting the user's time.
#
# Usage:
#   CONFIG_FILE=$(CLAUDE_PROJECT_DIR=/path/to/wt bash scripts/resolve-config-path.sh)
#
# Required env:
#   CLAUDE_PROJECT_DIR — current project dir (worktree path or main checkout)

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [[ -z "$PROJECT_DIR" ]]; then
  # Best-effort: caller forgot to set the env var. Emit nothing so the
  # caller's `[[ -f "" ]]` fails cleanly rather than blowing up.
  exit 0
fi

LOCAL_CONFIG="$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"

# Preferred: local file exists
if [[ -f "$LOCAL_CONFIG" ]]; then
  echo "$LOCAL_CONFIG"
  exit 0
fi

# Fallback: if we're in a worktree, find the main checkout's config.
# `git rev-parse --git-dir` vs `--git-common-dir` differ inside a worktree.
git_dir=$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null || echo "")
git_common=$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null || echo "")

if [[ -n "$git_dir" && -n "$git_common" && "$git_dir" != "$git_common" ]]; then
  # Inside a worktree. `git worktree list --porcelain` lists the main checkout
  # first — that's where setup is supposed to be run, and where its config lives.
  main_checkout=$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree / {print $2; exit}')
  if [[ -n "$main_checkout" && "$main_checkout" != "$PROJECT_DIR" ]]; then
    main_config="$main_checkout/.claude/24hour-ClaudeCode.config.json"
    if [[ -f "$main_config" ]]; then
      echo "$main_config"
      exit 0
    fi
  fi
fi

# Nothing found; return the preferred (local) path so callers' "missing config"
# branch fires correctly.
echo "$LOCAL_CONFIG"
