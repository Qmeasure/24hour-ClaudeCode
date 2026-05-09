---
description: Set 24hour-ClaudeCode.config.json `enabled: true`. Re-activates the SessionStart bootstrap and PostToolUse hook for this project.
---

Re-enable the 24hour-ClaudeCode runtime for this project.

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
CONFIG="$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Config missing. Run /24hour-ClaudeCode:setup first."
  exit 1
fi

tmp=$(mktemp)
jq '.enabled = true' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
echo "✓ Enabled. Restart Claude Code (or /clear) to re-trigger SessionStart bootstrap."
```

Tell the user the runtime is enabled but won't engage until the next session start (or `/clear`). The PostToolUse hook also re-checks `enabled` on every fire, so it'll start engaging on the next edit either way.
