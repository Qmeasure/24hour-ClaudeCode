---
description: Force-clear runtime lock and run the Stop hook pipeline once. Use when the loop is stuck mid-iteration.
---

Force-resync the runtime: clear the lock, then run the Stop hook pipeline once against current changes or in-flight PR state.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

echo "Clearing lock state..."
rm -rf "$RUNTIME/lock" "$RUNTIME/lock.queued" 2>/dev/null
echo "✓ Lock cleared"

echo ""
echo "Running stop.sh once (manual trigger)..."
jq -n \
  --arg cwd "$PROJECT_DIR" \
  --arg transcript "" \
  '{hook_event_name:"Stop", cwd:$cwd, transcript_path:$transcript, stop_hook_active:false}' \
  | CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "${CLAUDE_PLUGIN_ROOT}/hooks/stop.sh"
```

The hook will detect any pending changes, run the auto-commit pipeline when allowed, and emit a Stop `systemMessage` or `decision:block`. Read that output and proceed with the loop as the runtime contract specifies.

Use this when:
- A previous Stop hook run got killed mid-iteration and left the lock held
- You manually edited files while the lock was held; the queue flag may not have re-armed
- You want to re-poll GitHub and recompute stop conditions
