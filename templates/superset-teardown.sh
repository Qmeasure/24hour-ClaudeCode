#!/usr/bin/env bash
# .superset/teardown.sh — runs before Superset deletes a workspace.
#
# Cleans local runtime state. Reminds the user to clean the worktree from
# the main checkout (Superset can't safely remove a worktree it's currently in).
#
# FORBIDDEN here:
#   - close PRs / delete remote branches
#   - delete workflow YMLs
#   - merge PRs

set -uo pipefail

ROOT="${SUPERSET_ROOT_PATH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WS_NAME="${SUPERSET_WORKSPACE_NAME:-$(git branch --show-current 2>/dev/null || echo unnamed)}"
WS_PATH="${SUPERSET_WORKSPACE_PATH:-$(pwd)}"
RUNTIME="$WS_PATH/.claude/runtime/24hour-ClaudeCode"

echo "▸ Workspace teardown: $WS_NAME"

# Clean lock + transient decision files. Preserve state.json + last-run.json
# in case the user wants to inspect them later — Superset's force-delete will
# remove the entire worktree dir anyway.
if [[ -d "$RUNTIME/lock" ]]; then
  rm -rf "$RUNTIME/lock" "$RUNTIME/lock.queued" 2>/dev/null
  echo "  ✓ Cleared runtime lock"
fi

# Reminder
echo ""
echo "Reminder: if PR is MERGED, clean up from MAIN checkout (NOT here):"
echo "  cd $ROOT"
echo "  git worktree remove $WS_PATH"
echo "  git branch -d $WS_NAME"
