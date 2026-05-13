---
description: "Set 24hour-ClaudeCode.config.json `enabled: false`. Stops SessionStart bootstrap content and Stop prompt review-loop routing until re-enabled."
---

Disable the 24hour-ClaudeCode runtime for this project. Workflow YAMLs remain in place; the loop simply stops auto-engaging.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Config not present; nothing to disable. (Run /24hour-ClaudeCode:setup if you want to enable.)"
  exit 0
fi

tmp=$(mktemp)
jq '.enabled = false' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
echo "✓ Disabled. SessionStart bootstrap content and Stop prompt review-loop routing will stay silent until re-enabled."
echo "  To re-enable: /24hour-ClaudeCode:enable"
```

Tell the user:

> "Runtime disabled for this project. Your edits will not route to the review-loop skill automatically. The Claude Code Action workflows in `.github/workflows/` are unaffected — they'll still review PRs you open manually. Re-enable with `/24hour-ClaudeCode:enable`."

Use this when:
- You're in a hot debugging session and don't want the Stop prompt to re-enter review-loop
- You're working on a sensitive change that needs careful manual handling
- You're testing how the project behaves WITHOUT the runtime
