---
description: Show 24hour-ClaudeCode config, git status, and PR status for the current worktree.
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
