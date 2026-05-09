---
description: Delete <runtime>/lock and <runtime>/lock.queued — recovery from a stuck on-edit cycle. Use only after investigating WHY the lock is stuck.
---

<EXTREMELY-IMPORTANT>
Before clearing the lock, INVESTIGATE. The lock is held = some on-edit.sh invocation is in progress (or crashed). Killing the lock without diagnosis can cause:
- Concurrent commits stomping on each other
- Half-finished pushes leaving the remote in a weird state
- Lost work if a debounce was about to fire

If the lock has been held for >2 minutes AND no on-edit.sh process is running, it's safe to clear.
</EXTREMELY-IMPORTANT>

Diagnostic first:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

echo "── Lock holder ──"
[ -f "$RUNTIME/lock/holder" ] && cat "$RUNTIME/lock/holder" || echo "(no holder file)"

echo ""
echo "── Is the holder PID still alive? ──"
PID=$(grep -oE 'pid=[0-9]+' "$RUNTIME/lock/holder" 2>/dev/null | cut -d= -f2)
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  echo "  PID $PID is still running — DO NOT clear lock yet."
  exit 1
else
  echo "  PID $PID is gone — safe to clear."
fi

echo ""
echo "── Time held ──"
ACQUIRED=$(grep -oE 'acquired_at=.*' "$RUNTIME/lock/holder" 2>/dev/null | cut -d= -f2-)
echo "  Held since: $ACQUIRED"
```

If the diagnostic says safe-to-clear, then:

```bash
rm -rf "$RUNTIME/lock" "$RUNTIME/lock.queued" 2>/dev/null
echo "✓ Lock cleared"
```

After clearing, run `/24hour-ClaudeCode:retry` to re-trigger the on-edit pipeline if there are pending changes.

Report to the user what you cleared and recommend the retry.
