#!/usr/bin/env bash
# is-protected-branch.sh — Check whether the current branch is protected.
#
# Queries GitHub's actual branch-protection state via `gh api repos/X/branches/$branch`.
# Falls back to a hardcoded list when offline / gh unavailable / repo not on GitHub.
#
# Cache: result is cached in <runtime>/state.json under `protected_branch_cache.<branch>`
# for the lifetime of the worktree (cleared by `runtime-state.sh init` and post-merge cleanup)
# to avoid hitting `gh api` on every Stop.
#
# Usage:
#   bash scripts/is-protected-branch.sh [<branch>]
# Output: "true" or "false" on stdout.
# Exit: 0 always (caller checks output).

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$PROJECT_DIR" 2>/dev/null || { echo "false"; exit 0; }

branch="${1:-$(git branch --show-current 2>/dev/null || echo "")}"
[[ -z "$branch" ]] && { echo "false"; exit 0; }

# Hardcoded fallback (used when gh fails / offline).
case "$branch" in
  main|master|develop|dev|staging|production|release|prod) hardcoded_protected=1 ;;
  release/*|hotfix/*) hardcoded_protected=1 ;;
  *) hardcoded_protected=0 ;;
esac

# Try the cache first
RUNTIME_DIR="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
STATE_FILE="$RUNTIME_DIR/state.json"

if [[ -f "$STATE_FILE" ]]; then
  cached=$(jq -r --arg br "$branch" '.protected_branch_cache[$br] // empty' "$STATE_FILE" 2>/dev/null)
  if [[ -n "$cached" ]]; then
    echo "$cached"
    exit 0
  fi
fi

# Try gh api. If it succeeds, cache the result; if it fails, use the hardcoded value.
result=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  # Repo nwo (e.g. owner/repo) needed for the API URL
  repo_nwo=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
  if [[ -n "$repo_nwo" ]]; then
    api_result=$(gh api "repos/$repo_nwo/branches/$branch" --jq '.protected' 2>/dev/null || echo "")
    if [[ "$api_result" == "true" || "$api_result" == "false" ]]; then
      result="$api_result"
    fi
  fi
fi

# Fallback to hardcoded list when API didn't give a clean answer
if [[ -z "$result" ]]; then
  if (( hardcoded_protected == 1 )); then
    result="true"
  else
    result="false"
  fi
fi

# Cache the result for this session (best-effort)
if [[ -f "$STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
  tmp=$(mktemp 2>/dev/null) || tmp="${STATE_FILE}.tmp.$$"
  jq --arg br "$branch" --arg val "$result" \
     '.protected_branch_cache //= {} | .protected_branch_cache[$br] = $val' \
     "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE" 2>/dev/null || rm -f "$tmp"
fi

echo "$result"
