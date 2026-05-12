#!/usr/bin/env bash
# auto-commit.sh — Stage tracked changes and commit with an `auto: WIP` placeholder.
#
# Behavior:
#   - Refuses to run on a protected branch (caller should have checked, but defense in depth).
#   - Skips files in danger_paths (per detect-changes.sh's danger_hit).
#   - `git add -A` minus dangerous paths.
#   - If nothing to stage, exits 1 (so caller knows there was nothing to commit).
#   - Commit message: `auto: WIP on <branch> [<HH:MM:SS>]`.
#   - Prints the resulting commit SHA to stdout, or empty + non-zero exit if nothing committed.
#
# Required env: CLAUDE_PROJECT_DIR.
# Required tool: jq.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$PROJECT_DIR"

# Defense-in-depth protected branch check (real GitHub protection + hardcoded fallback)
branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ -n "$branch" ]]; then
  helper="$SCRIPT_DIR/is-protected-branch.sh"
  if [[ -x "$helper" ]]; then
    if [[ "$(bash "$helper" "$branch" 2>/dev/null)" == "true" ]]; then
      echo "auto-commit: refusing to commit on protected branch '$branch'" >&2
      exit 2
    fi
  else
    # Fallback to hardcoded if helper unavailable
    case "$branch" in
      main|master|develop|dev|staging|production|release|prod|release/*|hotfix/*)
        echo "auto-commit: refusing to commit on protected branch '$branch'" >&2
        exit 2
        ;;
    esac
  fi
fi

# Get change classification
changes=$(bash "$SCRIPT_DIR/detect-changes.sh")
has_changes=$(echo "$changes" | jq -r '.has_changes')

if [[ "$has_changes" != "true" ]]; then
  echo "auto-commit: no changes to stage" >&2
  exit 1
fi

# Get danger files to exclude
danger_files=$(echo "$changes" | jq -r '.danger_hit[]?' || true)

# Stage tracked changes one by one, skipping danger paths
all_files=$(echo "$changes" | jq -r '.files[]?')
staged_count=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  # skip if in danger list
  if printf '%s\n' "$danger_files" | grep -qxF "$f"; then
    continue
  fi
  git add -- "$f" 2>/dev/null && staged_count=$((staged_count+1)) || true
done <<< "$all_files"

if (( staged_count == 0 )); then
  echo "auto-commit: no non-danger files to stage" >&2
  exit 1
fi

# Build placeholder commit message
ts=$(date +%H:%M:%S)
msg="auto: WIP on $branch [$ts]"

# Commit. Use --no-verify only if config says so; default: respect hooks.
git commit -m "$msg" --quiet || {
  echo "auto-commit: git commit failed" >&2
  exit 3
}

# Print SHA
git rev-parse HEAD
