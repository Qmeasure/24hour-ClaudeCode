#!/usr/bin/env bash
# split-workflow-pr.sh — Split workflow file changes into a separate "preflight" PR.
#
# Why: GitHub refuses to authenticate the Claude Code Action (401) if a PR's
# .github/workflows/*.yml differs from the version on the default branch. This
# breaks the auto-review loop on any PR that mixes workflow + code changes.
# Solution: split the workflow file changes into their own preflight PR that
# auto-merges first; the rebased main branch's PR then has a clean workflow
# diff and the auto-review works.
#
# Inputs:
#   $CLAUDE_PROJECT_DIR — current project (defaults to pwd)
#   stdin or --files <space-separated list> — workflow file paths to split.
#     If neither, the script falls back to `git diff --name-only` filtered to
#     .github/workflows/*.yml.
#
# Output:
#   stdout: preflight PR number (one line) on success
#   exit 0 on success, non-zero on any failure (with stderr explaining why)
#
# Algorithm (8 steps):
#   1. Determine current branch + base branch + workflow file list
#   2. Validate preconditions:
#      - Working tree changes (only) should contain the workflow files
#      - No already-committed-but-unpushed workflow changes (out of scope; refuse)
#      - origin/<base> must be fetchable
#   3. Save the new content of each workflow file into temp files
#   4. Restore each workflow file to origin/<base>'s version on the original branch
#      (so the working tree no longer contains workflow changes — they're saved aside)
#   5. Create + checkout preflight branch from origin/<base>
#   6. Apply the saved new content to the preflight branch; commit + push
#   7. gh pr create + gh pr merge --auto on the preflight PR
#   8. Switch back to original branch (working tree retains the non-workflow changes)
#
# Required tools: git, gh, jq.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Args ----
FILES_INPUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES_INPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "split-workflow-pr: unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Read from stdin if --files not given and stdin is non-tty
if [[ -z "$FILES_INPUT" ]] && [[ ! -t 0 ]]; then
  FILES_INPUT=$(cat)
fi

cd "$PROJECT_DIR"

# ---- Step 1: branch + base detection ----
ORIG_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[[ -z "$ORIG_BRANCH" ]] && { echo "split-workflow-pr: cannot determine current branch (detached HEAD?)" >&2; exit 3; }

BASE_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
fi

# Workflow file list — explicit or derived from current diff
if [[ -z "$FILES_INPUT" ]]; then
  FILES_INPUT=$(git diff --name-only HEAD 2>/dev/null | grep -E '^\.github/workflows/.+\.ya?ml$' || true)
  # Also include staged (already added but not committed)
  FILES_INPUT="$FILES_INPUT
$(git diff --staged --name-only 2>/dev/null | grep -E '^\.github/workflows/.+\.ya?ml$' || true)"
  # And untracked workflow files
  FILES_INPUT="$FILES_INPUT
$(git ls-files --others --exclude-standard 2>/dev/null | grep -E '^\.github/workflows/.+\.ya?ml$' || true)"
fi

# Normalize: dedupe, trim empty lines
WORKFLOW_FILES=$(printf '%s\n' "$FILES_INPUT" | tr ' ' '\n' | awk 'NF' | sort -u)

if [[ -z "$WORKFLOW_FILES" ]]; then
  echo "split-workflow-pr: no workflow files to split" >&2
  exit 4
fi

# ---- Step 2: precondition checks ----

# Refuse if any workflow file is in committed-but-unpushed history (v1 limitation)
git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || {
  echo "split-workflow-pr: cannot fetch origin/$BASE_BRANCH" >&2
  exit 5
}

committed_workflow_changes=$(git log "origin/$BASE_BRANCH..HEAD" --name-only --pretty=format: 2>/dev/null | grep -E '^\.github/workflows/.+\.ya?ml$' | sort -u || true)
if [[ -n "$committed_workflow_changes" ]]; then
  echo "split-workflow-pr: workflow files are in committed history (not just working tree):" >&2
  echo "$committed_workflow_changes" | sed 's/^/  /' >&2
  echo "split-workflow-pr: v1 only handles working-tree changes. Resolve the commit history manually:" >&2
  echo "  git reset HEAD~ -- .github/workflows/  # un-commit workflow files only" >&2
  echo "  git commit --amend --no-edit            # amend the prior commit without them" >&2
  echo "Then re-trigger the Stop hook." >&2
  exit 6
fi

# ---- Step 3: save new content of each workflow file ----
# (Use parallel arrays — macOS ships bash 3.2, no associative arrays.)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SAVED_PATHS=()    # workflow file paths (relative to repo root)
SAVED_TMPS=()     # corresponding saved content path, or literal "<DELETED>"
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  SAVED_PATHS+=("$f")
  if [[ ! -f "$f" ]]; then
    # File deletion in workflow — also part of the split
    SAVED_TMPS+=("<DELETED>")
  else
    saved_path="$TMPDIR/$(echo "$f" | tr '/' '_')"
    cp "$f" "$saved_path"
    SAVED_TMPS+=("$saved_path")
  fi
done <<< "$WORKFLOW_FILES"

file_count=${#SAVED_PATHS[@]}
echo "split-workflow-pr: detected $file_count workflow file change(s) on branch $ORIG_BRANCH" >&2

# ---- Step 4: revert each workflow file on the original branch ----
# This puts the working tree in a state where workflow files match origin/<base>,
# while non-workflow changes are preserved.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if git cat-file -e "origin/$BASE_BRANCH:$f" 2>/dev/null; then
    # File exists on base — restore that version
    git checkout "origin/$BASE_BRANCH" -- "$f"
  else
    # File doesn't exist on base — was a NEW workflow file; remove from working tree + index
    git rm --cached "$f" >/dev/null 2>&1 || true
    rm -f "$f"
  fi
done <<< "$WORKFLOW_FILES"

# ---- Step 5: create preflight branch from origin/<base> ----
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
PREFLIGHT_BRANCH="preflight/${ORIG_BRANCH}-workflow-${TIMESTAMP}"

# Stash any non-workflow changes so checkout doesn't carry them over
STASH_REF=""
if ! git diff --quiet 2>/dev/null || [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
  if git stash push -u -m "split-workflow-pr-temp-${TIMESTAMP}" >/dev/null 2>&1; then
    STASH_REF="stash@{0}"
  fi
fi

if ! git checkout -b "$PREFLIGHT_BRANCH" "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  # Fallback: if the branch name collides somehow (shouldn't with timestamp)
  PREFLIGHT_BRANCH="${PREFLIGHT_BRANCH}-$$"
  git checkout -b "$PREFLIGHT_BRANCH" "origin/$BASE_BRANCH" >/dev/null 2>&1 || {
    echo "split-workflow-pr: cannot create preflight branch" >&2
    [[ -n "$STASH_REF" ]] && git checkout "$ORIG_BRANCH" >/dev/null 2>&1 && git stash pop >/dev/null 2>&1
    exit 7
  }
fi

# ---- Step 6: apply saved content to preflight branch; commit + push ----
mkdir -p .github/workflows
for i in "${!SAVED_PATHS[@]}"; do
  f="${SAVED_PATHS[$i]}"
  saved="${SAVED_TMPS[$i]}"
  if [[ "$saved" == "<DELETED>" ]]; then
    # File was deleted — also delete on preflight (only if it exists on base)
    git rm "$f" >/dev/null 2>&1 || true
  else
    mkdir -p "$(dirname "$f")"
    cp "$saved" "$f"
    git add "$f"
  fi
done

# Sanity: bail if nothing was actually staged
if git diff --staged --quiet 2>/dev/null; then
  echo "split-workflow-pr: nothing to stage on preflight branch (all workflow files identical to base?)" >&2
  git checkout "$ORIG_BRANCH" >/dev/null 2>&1
  git branch -D "$PREFLIGHT_BRANCH" >/dev/null 2>&1 || true
  [[ -n "$STASH_REF" ]] && git stash pop >/dev/null 2>&1
  exit 8
fi

# Precompute the file list bullets so the heredocs don't embed nested $(...)
FILE_LIST_BULLETS=$(for f in "${SAVED_PATHS[@]}"; do printf '  - %s\n' "$f"; done | sort)

COMMIT_MSG_FILE=$(mktemp)
{
  printf 'ci: pre-merge workflow changes from %s\n\n' "$ORIG_BRANCH"
  printf 'Auto-split by 24hour-ClaudeCode plugin. The workflow file changes below need\n'
  printf 'to land on %s BEFORE the rest of the work on %s can be\n' "$BASE_BRANCH" "$ORIG_BRANCH"
  printf 'auto-reviewed (GitHub workflow-validation security policy: workflow files on\n'
  printf 'a PR branch must match %s for App-token auth to succeed).\n\n' "$BASE_BRANCH"
  printf 'Files:\n%s\n\n' "$FILE_LIST_BULLETS"
  printf 'After this PR auto-merges, the auto-PR loop on %s resumes\n' "$ORIG_BRANCH"
  printf 'automatically. See plugin docs: scripts/split-workflow-pr.sh.\n'
} > "$COMMIT_MSG_FILE"

if ! git -c user.email="24hour-ClaudeCode@noreply.invalid" \
        -c user.name="24hour-ClaudeCode-bot" \
        commit -q -F "$COMMIT_MSG_FILE"; then
  rm -f "$COMMIT_MSG_FILE"
  echo "split-workflow-pr: commit failed on preflight branch" >&2
  exit 9
fi
rm -f "$COMMIT_MSG_FILE"

if ! git push -u origin "$PREFLIGHT_BRANCH" >/dev/null 2>&1; then
  echo "split-workflow-pr: push of preflight branch failed" >&2
  exit 10
fi

# ---- Step 7: open PR + enable auto-merge ----
PR_TITLE="ci: workflow pre-merge for $ORIG_BRANCH"
PR_BODY_FILE=$(mktemp)
{
  printf '**Auto-split by 24hour-ClaudeCode plugin.**\n\n'
  printf 'This PR carries the workflow file changes destined for branch `%s`.\n' "$ORIG_BRANCH"
  printf "GitHub's security policy refuses to authenticate the auto-review (HTTP 401)\n"
  printf 'when a PR modifies workflow files that differ from %s. Splitting\n' "$BASE_BRANCH"
  printf 'them here lets the main PR have a clean diff against %s.\n\n' "$BASE_BRANCH"
  printf 'Files in this PR:\n%s\n\n' "$FILE_LIST_BULLETS"
  printf 'Auto-merge is enabled. Once required checks pass, this merges automatically\n'
  printf 'and the auto-PR loop on `%s` resumes.\n\n' "$ORIG_BRANCH"
  printf '> If you have configured `claude-code-review` as a **required** check in\n'
  printf '> branch protection, this preflight PR will hang (the review on a workflow-only\n'
  printf '> diff also hits the 401). Disable that requirement, or merge this PR manually.\n'
} > "$PR_BODY_FILE"

PR_NUM=$(gh pr create --base "$BASE_BRANCH" --head "$PREFLIGHT_BRANCH" \
                      --title "$PR_TITLE" --body-file "$PR_BODY_FILE" 2>/dev/null \
         | grep -oE '/pull/[0-9]+' | grep -oE '[0-9]+' | tail -1)
rm -f "$PR_BODY_FILE"

if [[ -z "$PR_NUM" ]]; then
  echo "split-workflow-pr: gh pr create succeeded but no PR number captured" >&2
  exit 11
fi

# Enable auto-merge (squash). If branch protection is loose this fires immediately.
gh pr merge "$PR_NUM" --auto --squash >/dev/null 2>&1 || {
  # Auto-merge enable may fail if checks haven't reported yet, or if perms are insufficient
  echo "split-workflow-pr: gh pr merge --auto failed for PR #$PR_NUM (continuing; user may need to merge manually)" >&2
}

# ---- Step 8: switch back to original branch ----
git checkout "$ORIG_BRANCH" >/dev/null 2>&1 || {
  echo "split-workflow-pr: cannot switch back to $ORIG_BRANCH" >&2
  exit 12
}

# Restore any stashed non-workflow changes
if [[ -n "$STASH_REF" ]]; then
  git stash pop >/dev/null 2>&1 || {
    echo "split-workflow-pr: stash pop had conflicts; resolve manually with 'git stash pop'" >&2
    # Don't fail the script here — the preflight PR is already open
  }
fi

# Output the PR number on stdout (consumed by callers)
echo "$PR_NUM"
exit 0
