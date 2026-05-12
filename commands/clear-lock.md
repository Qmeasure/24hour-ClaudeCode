---
description: Delete <runtime>/lock — recovery from a stuck Stop hook cycle. Use only after investigating WHY the lock is stuck.
---

<EXTREMELY-IMPORTANT>
Before clearing the lock, INVESTIGATE. The lock is held = a Stop hook invocation is in progress or crashed. Killing the lock without diagnosis can cause:
- Concurrent commits stomping on each other
- Half-finished pushes leaving the remote in a weird state

If the lock has been held longer than the configured Stop timeout, or the holder PID is gone, it is safe to clear.
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
rm -rf "$RUNTIME/lock" 2>/dev/null
echo "✓ Lock cleared"
```

After clearing, run `/24hour-ClaudeCode:retry` to re-run the Stop hook pipeline if there are pending changes or an in-flight PR.

Report to the user what you cleared and recommend the retry.
