---
description: Force-clear runtime lock and re-run the on-edit pipeline once. Use when the loop is stuck mid-iteration.
---

Force-resync the runtime: clear the lock and queue flag, then run the on-edit pipeline once against current changes.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

echo "Clearing lock state..."
rm -rf "$RUNTIME/lock" "$RUNTIME/lock.queued" 2>/dev/null
echo "✓ Lock cleared"

echo ""
echo "Running on-edit.sh once (manual trigger)..."
bash "${CLAUDE_PLUGIN_ROOT}/hooks/on-edit.sh" < /dev/null
```

The hook will detect any pending changes, run the auto-commit pipeline, and emit `additionalContext`. Read that context and proceed with the loop (amend commit message, mark PR ready, etc.) as the runtime contract specifies.

Use this when:
- A previous on-edit run got killed mid-iteration and left the lock held
- You manually edited files while the lock was held; the queue flag may not have re-armed
- You want to re-poll GitHub and recompute stop conditions
