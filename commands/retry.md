---
description: Clear REVIEW_LOOP_STOPPED state so the next Stop prompt can re-enter the review-loop skill.
---

Reset the visible review-loop stop state for this project.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"
STATE="$RUNTIME/review-loop-state.md"

mkdir -p "$RUNTIME"
printf '*\n!.gitignore\n' > "$RUNTIME/.gitignore"

if [ -f "$STATE" ] && grep -q "REVIEW_LOOP_DONE" "$STATE"; then
  echo "Review loop is DONE. Not clearing it automatically."
  echo "If you are starting a new task in this same worktree, remove $STATE intentionally."
  exit 0
fi

if [ -f "$STATE" ] && grep -q "REVIEW_LOOP_STOPPED" "$STATE"; then
  mv "$STATE" "$STATE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  echo "✓ Cleared stopped review-loop state. The next Stop prompt can re-enter review-loop."
else
  echo "No REVIEW_LOOP_STOPPED state found."
fi

echo ""
echo "Current git status:"
git status --short
```

Tell the user that retry only clears the stopped state; the next Stop prompt will route to the `review-loop` skill in the same Claude Code session when appropriate.
