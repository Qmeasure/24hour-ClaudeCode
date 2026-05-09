---
description: Run interactive Claude Code Actions onboarding + write 24hour-ClaudeCode.config.json. Run once per repo, or to re-onboard after Actions config drift.
---

Onboard this repo for the 24hour-ClaudeCode auto-PR loop. Three things happen:

1. **Claude Code Actions deploy** — install the GitHub App, generate OAuth token, save to `CLAUDE_CODE_OAUTH_TOKEN` secret, render and push `.github/workflows/claude*.yml`.
2. **Project config seed** — write `.claude/24hour-ClaudeCode.config.json` from `templates/24hour-ClaudeCode.config.json` (auto-detects test/lint/typecheck commands from the project).
3. **Runtime state init** — initialize `.claude/runtime/24hour-ClaudeCode/state.json`.

Tell the user:

> "Setting up 24hour-ClaudeCode for this repo. Takes 5–10 minutes. I'll explain each step before doing it. The script asks for confirmation before any push or token write."

Then run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/configure-actions.sh"
```

After it succeeds, seed the runtime config:

```bash
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
mkdir -p "$PROJECT_DIR/.claude"

if [ -f "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json" ]; then
  echo "Config already exists; skipping seed."
else
  cp "${CLAUDE_PLUGIN_ROOT}/templates/24hour-ClaudeCode.config.json" "$PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"
  echo "✓ Seeded $PROJECT_DIR/.claude/24hour-ClaudeCode.config.json"
fi

# Initialize runtime state
bash "${CLAUDE_PLUGIN_ROOT}/scripts/runtime-state.sh" init
echo "✓ Runtime state initialized"

# Health check
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-actions.sh" -v
```

After health check passes, tell the user:

> "✓ Setup complete. The auto-PR loop is now active for this repo. Open a worktree (`git worktree add ../my-feature -b feat/my-feature`) and edit code — the on-edit hook will kick in automatically.
>
> To verify: run `/24hour-ClaudeCode:status` for runtime state, or `/clear` to re-trigger SessionStart and see the runtime contract injected."
