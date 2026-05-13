---
description: Show 24hour-ClaudeCode runtime state, including the visible review-loop state file.
---

Read and pretty-print the runtime state for this project.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
STATE="$RUNTIME/review-loop-state.md"

if [ ! -d "$RUNTIME" ]; then
  echo "No 24hour-ClaudeCode runtime in this project. Run /24hour-ClaudeCode:setup first."
  exit 0
fi

echo "── review-loop-state.md ────────────────"
[ -f "$STATE" ] && cat "$STATE" || echo "(missing)"

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
