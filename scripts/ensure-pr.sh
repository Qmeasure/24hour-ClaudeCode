#!/usr/bin/env bash
# ensure-pr.sh — Ensure a PR exists for the current branch. Update runtime/current-pr.json.
#
# Behavior:
#   - Checks if a PR already exists for current branch via `gh pr view`.
#   - If yes: writes its metadata to <runtime>/current-pr.json and exits 0.
#   - If no: creates a ready PR with `gh pr create --fill`.
#     - `--fill` uses the latest commit subject as title and commit body as PR body.
#   - Output: prints the PR number to stdout.
#
# Required env: CLAUDE_PROJECT_DIR.
# Required tools: gh, jq.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
CURRENT_PR_FILE="$RUNTIME_DIR/current-pr.json"

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

branch=$(git branch --show-current 2>/dev/null || echo "")
[[ -n "$branch" ]] || { echo "ensure-pr: no branch detected" >&2; exit 1; }

# Try to find an existing open PR for this branch.
pr_json=$(gh pr view --json number,url,isDraft,headRefName,headRefOid,baseRefName,state 2>/dev/null || echo "")

if [[ -n "$pr_json" ]] && [[ "$(echo "$pr_json" | jq -r '.state')" == "OPEN" ]]; then
  echo "$pr_json" > "$CURRENT_PR_FILE"
  echo "$pr_json" | jq -r '.number'
  exit 0
fi

# No PR exists; create one ready for review.
# `--fill` derives title/body from the commit.
gh pr create --fill >/dev/null 2>&1 || {
  echo "ensure-pr: gh pr create failed" >&2
  exit 2
}

# Re-fetch the freshly created PR
pr_json=$(gh pr view --json number,url,isDraft,headRefName,headRefOid,baseRefName,state)
echo "$pr_json" > "$CURRENT_PR_FILE"
echo "$pr_json" | jq -r '.number'
