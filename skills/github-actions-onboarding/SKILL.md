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
> 2. **Auto-detect** the Claude GitHub App on this repo (via the `check_suites`
>    side-channel — no clicks if it's already installed at account level, which
>    is the common case). Only walks you through https://github.com/apps/claude
>    if not detected.
> 3. **Detect** the `CLAUDE_CODE_OAUTH_TOKEN` secret via the precise probe
>    `gh api repos/.../actions/secrets/CLAUDE_CODE_OAUTH_TOKEN`. If missing,
>    the script prints **two CLI commands for YOU to run in YOUR terminal**
>    (browser OAuth + paste — neither can be driven from inside the script),
>    then waits for you to come back and Enter, then re-verifies:
>    ```bash
>    claude setup-token                                       # browser OAuth → prints sk-ant-oat01-...
>    gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <owner>/<repo>  # paste at prompt
>    ```
> 4. Detect this repo's project type, test commands, style guides, and sensitive paths.
> 5. Render `.github/workflows/claude.yml` and `claude-code-review.yml` tailored to what I detected.
> 6. Write `.claude/24hour-ClaudeCode.config.json` with your auto-loop preferences.
> 7. Commit + push (with your confirmation).
>
> The script asks for confirmation before each push, never auto-runs interactive token commands, and verifies state via precise GitHub API probes (no user input trusted blindly)."

## Run the onboarder script

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/configure-actions.sh"
```

Or, if the user invoked `/24hour-ClaudeCode:setup`, that command already invoked this script. Re-run only if it failed mid-flow.

## What the script does (high-level)

1. **Pre-flight:** `gh auth status` (must include `workflow` scope), `claude --version`, `git --version`.
2. **GitHub App detect:** runs `${CLAUDE_PLUGIN_ROOT}/scripts/check-claude-app.sh <repo>`. If installed, skips ahead. If not, opens https://github.com/apps/claude, waits for user, re-detects.
3. **OAuth token detect + guide:** runs `${CLAUDE_PLUGIN_ROOT}/scripts/check-secret.sh <repo> CLAUDE_CODE_OAUTH_TOKEN`. If exists, skips ahead. If missing, **prints the 2 CLI commands for the user to run in their terminal** (`claude setup-token` + `gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <repo>`), waits for them to come back, re-verifies via the same precise probe. Does NOT invoke these interactive commands itself.
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
| `CLAUDE_CODE_OAUTH_TOKEN` secret missing | run `claude setup-token` then `gh secret set CLAUDE_CODE_OAUTH_TOKEN -R <repo>` (paste token). Verify with `bash $CLAUDE_PLUGIN_ROOT/scripts/check-secret.sh <repo> CLAUDE_CODE_OAUTH_TOKEN` (should print `exists: ...`). |
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
