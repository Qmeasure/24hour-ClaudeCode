---
description: "Set 24hour-ClaudeCode.config.json `enabled: true`. Re-activates SessionStart bootstrap and Stop prompt review-loop routing for this project."
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

Tell the user the runtime is enabled but the full contract is injected on the next session start or `/clear`. The Stop prompt can route the next completed implementation turn to `review-loop`.
