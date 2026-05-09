---
name: github-actions-onboarding
description: Walks the user through deploying Claude Code Actions in their repo. Use when SessionStart bootstrap detected onboarding is incomplete (Actions YAML missing, gh not authed, or 24hour-ClaudeCode.config.json missing) — the user must finish this before the auto-PR loop is live. Steps the user through GitHub App install, OAuth token, GitHub secret, and rendered workflow YAMLs tailored to their project.
---

# GitHub Actions Onboarding

You're here because the SessionStart bootstrap of 24hour-ClaudeCode found this repo isn't fully wired. Without Claude Code Actions, the auto-PR loop has no review side and the runtime is half-blind. **Do not skip onboarding to start coding.**

## Tell the user what's about to happen

Verbatim:

> "This repo doesn't have Claude Code Actions deployed yet. Without it, no Action will review your PRs, and 24hour-ClaudeCode can't drive the review-fix-merge loop. I'll set it up now — takes 5–10 minutes. Here's what I'll do:
>
> 1. Verify gh CLI is authenticated with workflow scope.
> 2. Open https://github.com/apps/claude in your browser; you install the App on this repo.
> 3. Run `claude setup-token` to generate an OAuth token; save it to GitHub secret `CLAUDE_CODE_OAUTH_TOKEN`.
> 4. Detect this repo's project type, test commands, style guides, and sensitive paths.
> 5. Render `.github/workflows/claude.yml` and `claude-code-review.yml` tailored to what I detected.
> 6. Write `.claude/24hour-ClaudeCode.config.json` with your auto-loop preferences.
> 7. Commit + push (with your confirmation).
>
> The script asks for confirmation before each push and before generating the token."

## Run the onboarder script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/configure-actions.sh"
```

Or, if the user invoked `/24hour-ClaudeCode:setup`, that command already invoked this script. Re-run only if it failed mid-flow.

## What the script does (high-level)

1. **Pre-flight:** `gh auth status` (must include `workflow` scope), `claude --version`, `git --version`.
2. **GitHub App install:** opens https://github.com/apps/claude, waits for user confirmation it's installed.
3. **OAuth token:** runs `claude setup-token`, captures token from stdout, sets via `gh secret set CLAUDE_CODE_OAUTH_TOKEN`.
4. **Project detection:** `${CLAUDE_PLUGIN_ROOT}/scripts/detect-project.sh` discovers project type, test runner, style guides, danger paths, repo size.
5. **Workflow render:** `${CLAUDE_PLUGIN_ROOT}/scripts/render-workflows.sh` writes the two YAMLs with project-specific prompt context.
6. **Config write:** seeds `.claude/24hour-ClaudeCode.config.json` from the template at `${CLAUDE_PLUGIN_ROOT}/templates/24hour-ClaudeCode.config.json`, populating `checks.commands` from detection.
7. **Push:** asks before each `git add` / `git commit` / `git push`.
8. **Health check:** runs `${CLAUDE_PLUGIN_ROOT}/scripts/check-actions.sh -v` to confirm everything is wired.

## Verify

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/check-actions.sh" -v
```

Last line must be `✓ All checks passed`. If not, the failed check tells you what to fix:

| Failure | Fix |
|---|---|
| `gh CLI not authenticated` | `gh auth login` |
| Missing `workflow` scope | `gh auth refresh -h github.com -s workflow` |
| `CLAUDE_CODE_OAUTH_TOKEN` secret missing | re-run `claude setup-token` + `gh secret set` |
| No `.github/workflows/claude*.yml` | re-run `${CLAUDE_PLUGIN_ROOT}/scripts/render-workflows.sh` |
| Workflow missing `id-token: write` | re-render |
| Workflow missing `contents: write` (claude.yml only) | re-render |
| `.claude/24hour-ClaudeCode.config.json` missing | re-run `/24hour-ClaudeCode:setup` |

## After onboarding

Re-trigger the SessionStart bootstrap by saying `/clear` or starting a new session. The next bootstrap will detect a healthy environment and inject the `using-24hour-ClaudeCode` runtime contract instead of this skill.

## Common pitfalls

- **Don't put the OAuth token in a `.env` file or commit it.** Use stdin pipe to `gh secret set`. See `references/anti-patterns.md` H1.
- **Don't grant the App workflow-write permission.** It can't (and shouldn't) edit `.github/workflows/`. Manual edits only.
- **Don't open a `pull_request` trigger in `claude.yml`.** That's `claude-code-review.yml`'s job. Duplicate triggers double the token spend.
