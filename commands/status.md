---
description: Show 24hour-ClaudeCode git, PR, and plugin status for the current worktree.
---

Read and pretty-print the current project status. Do not modify files.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_DIR"

echo "── 24hour-ClaudeCode config ─────────────"
if [ -f ".claude/24hour-ClaudeCode.config.json" ]; then
  jq -r '"enabled: " + ((.enabled // true) | tostring)' .claude/24hour-ClaudeCode.config.json 2>/dev/null || cat .claude/24hour-ClaudeCode.config.json
else
  echo "(missing .claude/24hour-ClaudeCode.config.json — run /24hour-ClaudeCode:setup from the main checkout)"
fi

echo ""
echo "── git sync ─────────────────────────────"
git fetch origin --prune >/dev/null 2>&1 || echo "(git fetch origin --prune failed)"
branch="$(git branch --show-current 2>/dev/null || true)"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
default_branch="$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
if [ -z "$default_branch" ]; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)"
fi
default_branch="${default_branch:-main}"

echo "branch: ${branch:-<unknown>}"
echo "upstream: ${upstream:-<none>}"
echo "default: origin/$default_branch"

if [ -n "$upstream" ]; then
  git status -sb | head -1
fi

if git rev-parse --verify "origin/$default_branch" >/dev/null 2>&1; then
  read -r ahead behind <<EOF
$(git rev-list --left-right --count HEAD..."origin/$default_branch")
EOF
  echo "vs origin/$default_branch: ahead $ahead, behind $behind"
  if git merge-base --is-ancestor "origin/$default_branch" HEAD; then
    echo "base freshness: current HEAD contains latest origin/$default_branch"
  else
    echo "base freshness: STALE — rebase or merge origin/$default_branch before review/merge"
  fi
fi

echo ""
echo "── git status ───────────────────────────"
git status --short

echo ""
echo "── current PR ───────────────────────────"
if gh pr view --json number,url,state,isDraft,headRefName,headRefOid 2>/dev/null; then
  :
else
  echo "(no open PR for this branch, or gh is unavailable)"
fi
```

Report the output to the user as-is. Do not interpret or take action — this is read-only.
