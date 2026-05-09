---
description: Show 24hour-ClaudeCode runtime state — current PR, iteration, last action, recent events.
---

Read and pretty-print the runtime state for this project.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
RUNTIME="$PROJECT_DIR/.claude/runtime/24hour-ClaudeCode"

if [ ! -d "$RUNTIME" ]; then
  echo "No 24hour-ClaudeCode runtime in this project. Run /24hour-ClaudeCode:setup first."
  exit 0
fi

echo "── state.json ──────────────────────────"
[ -f "$RUNTIME/state.json" ] && jq . "$RUNTIME/state.json" || echo "(missing)"

echo ""
echo "── current-pr.json ─────────────────────"
[ -f "$RUNTIME/current-pr.json" ] && jq . "$RUNTIME/current-pr.json" || echo "(no PR yet)"

echo ""
echo "── last-run.json ───────────────────────"
[ -f "$RUNTIME/last-run.json" ] && jq . "$RUNTIME/last-run.json" || echo "(no runs yet)"

echo ""
echo "── feedback.json (last poll) ───────────"
[ -f "$RUNTIME/feedback.json" ] && jq '{polled_at, pr: .pr, checks: (.checks // [] | length), reviews: (.reviews // [] | length)}' "$RUNTIME/feedback.json" || echo "(no polls yet)"

echo ""
echo "── lock state ──────────────────────────"
if [ -d "$RUNTIME/lock" ]; then
  echo "🔒 LOCKED. Holder:"
  cat "$RUNTIME/lock/holder"
  echo "(Use /24hour-ClaudeCode:clear-lock if stuck)"
else
  echo "🔓 unlocked"
fi
[ -f "$RUNTIME/lock.queued" ] && echo "📥 queue flag set (more work waiting)"
```

Report the output to the user as-is. Do not interpret or take action — this is read-only.
