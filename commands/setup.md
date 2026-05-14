---
description: Invoke the GitHub Actions onboarding skill when this repo needs 24hour-ClaudeCode setup or re-onboarding after Actions config drift.
---

Invoke the `github-actions-onboarding` skill now.

This slash command is a trigger, not the onboarding workflow. The skill owns the workflow.

Do not run a monolithic onboarding script. Use scripts only for deterministic mechanical helper actions when the skill calls for them:

- `scripts/install-superset-config.sh` only if the user wants Superset integration

After onboarding succeeds, tell the user:

> "Setup complete. The auto-PR loop is now active for this repo. Open a worktree (`git worktree add ../my-feature -b feat/my-feature`), start a fresh Claude Code session inside it, and use `/goal <your objective>` for feature work. After native `/goal` allows stopping, the Stop prompt can route to the review-loop skill.
>
> To verify: run `/24hour-ClaudeCode:status` for config, git, and PR status, or `/clear` to re-trigger SessionStart and see the runtime contract injected."
