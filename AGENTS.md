# Repository Guidelines

## Project Structure & Module Organization

This repository contains the `24hour-ClaudeCode` Claude Code plugin. Runtime behavior is skill-first: hooks are thin lifecycle triggers, `skills/review-loop/SKILL.md` owns the PR review loop, `skills/github-actions-onboarding/SKILL.md` owns onboarding, and scripts are limited to version synchronization and deterministic Superset file installation. Slash-command docs are in `commands/`, reusable agent workflows are in `skills/`, and starter files are in `templates/`. User-facing docs are `README*.md` and `FLOW*.md`.

## Architecture Principles

- Hook = trigger only. Do not put commit/push/PR/review/merge orchestration into plugin hooks or skill-scoped hooks.
- `UserPromptSubmit` is a fully supported Claude Code hook event. It fires before Claude processes each submitted prompt, supports context injection and prompt blocking, and does not support matchers; use it when prompt-time routing or Goal-related context is needed.
- Skill = workflow and judgment. Put Claude behavior, review handling, stopping rules, and merge discipline in skills.
- Script = deterministic mechanical helper. Use scripts only when inputs, outputs, repeatability, and exit codes are clear.
- Review evidence must come from real GitHub surfaces bound to the current HEAD SHA; do not require custom verdict artifacts.
- Keep repair in the current Claude Code session and current WorkTree. Do not spawn another Claude CLI as a fixer.
- Skill frontmatter `description` should describe when to use the skill, not summarize the workflow.

## Hook / Skill / Script Routing

- Hook routes the agent to the right next context. It should trigger, inspect lifecycle input, inject context, or block/continue with a short reason; it must not own a full multi-step workflow.
- For long workflow scenarios, use prompt-based hooks to make the semantic routing decision and guide the current agent into the correct skill. The prompt text must explicitly tell Claude to use the target skill via the Skill tool, for example: "Use the `review-loop` skill (via the Skill tool) to run the complete PR review loop." Do not leave the handoff as an abstract "route" instruction.
- Skill constrains the agent's behavior and workflow. Multi-step order, stopping rules, review discipline, rework boundaries, verification standards, and merge rules belong in skills such as `review-loop` and `github-actions-onboarding`.
- For deterministic non-workflow scenarios, use command hooks to call scripts. Use this path for fixed checks, environment detection, config reads, marker writes, context generation, formatting, validation, install, or sync actions.
- Script only performs mechanical, deterministic, repeatable tool actions. Scripts may parse hook JSON input, inspect files, run fixed commands, and emit structured JSON, but they must not decide or run agent-level workflows.
- In short: long workflows use prompt-based hooks to route to skills; deterministic tool actions use command hooks to run scripts. Hook routes, skill governs, script executes repeatable mechanics.

## Review Loop Prompt Rules

- Review-loop Stop hooks must use `type: "prompt"`, not command, HTTP, MCP, or agent hooks.
- Prompt hooks use `model: "claude-opus-4-7"` and `timeout: 7200`.
- Do not put an explicit hook input placeholder in review-loop hook prompts.
- Review-loop hook prompts must contain only the workflow objective and workflow steps.
- Do not include hook decision scaffolding in review-loop prompts: no return-instruction block, no allow/block JSON examples, no protocol fields, no acceptance-criteria section, and no output-format section.
- The prompt content should state only the complete review-loop workflow: use the `review-loop` skill via the Skill tool, preflight, prove reviewable changes, inspect, verify, commit, push, bind current SHA, create or refresh PR, wait for current-SHA GitHub review, read top-level and inline review output, fix blocking security/correctness findings, repeat, merge or enable auto-merge, or report a concrete blocker.
- Keep unrelated rationale, history, implementation commentary, JSON protocol details, and fallback narratives out of the hook prompt.
- Onboarding must add `.Claude/` to the project root `.gitignore`. Do not add `.claude/` there, because onboarding intentionally commits `.claude/24hour-ClaudeCode.config.json`.

## Version Bump Rule

Any change that should reach installed plugin users must bump `.claude-plugin/plugin.json` before push. Claude Code plugin updates are version-gated; if the version stays unchanged, users can keep running the old cached plugin even after `main` changes.

Use:

```bash
bash scripts/bump-version.sh patch
```

Run the bump in the same change as hook, skill, command, template, onboarding, runtime, or user-facing docs changes that alter behavior. Verify with `claude plugin validate .` before pushing.

## Superset Integration Rules

Superset workspace scripts run inside user project worktrees, not inside the plugin hook environment. Do not rely on `${CLAUDE_PLUGIN_ROOT}` or project-local `.claude/plugins/24hour-ClaudeCode` paths there.

`.superset/setup.sh` must verify plugin installation through Claude Code itself:

```bash
claude plugin list
```

The setup script must not call removed runtime helpers such as `scripts/check-actions.sh`, must not reference local loop-state markdown files, and must not print maintenance commands pointing at plugin-internal scripts. It may point users to slash commands such as `/24hour-ClaudeCode:status`, `/24hour-ClaudeCode:setup`, and `claude plugin details 24hour-ClaudeCode@24hour-ClaudeCode`.

Superset setup is allowed to normalize a newly opened Superset workspace to `origin/main`; do not apply this rule to non-Superset flows. The setup script must fetch and, when needed, reset the current Superset worktree to `origin/main`:

```bash
git fetch origin --prune
git reset --hard origin/main
git clean -fd
```

Do not change the normal feature worktree creation guidance for users who are not using Superset.

When changing Superset templates, validate with a temporary repo install plus `bash scripts/install-superset-config.sh --verify`; the verifier should catch stale `.superset/setup.sh` copies that still reference project-local plugin paths or removed scripts.

## Official Hook Facts

- Verify Claude Code hook behavior against the official docs or local `claude --help` before changing runtime architecture.
- Official docs list `UserPromptSubmit` as a first-class hook event: it runs when the user submits a prompt, before Claude processes it.
- `UserPromptSubmit` receives the submitted text in `prompt`, can add `additionalContext`, can block the prompt with `decision: "block"`, and always fires when configured because matchers are not supported for this event.
- Prompt hooks are officially supported for `UserPromptSubmit`, `UserPromptExpansion`, `Stop`, `SubagentStop`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `TaskCreated`, and `TaskCompleted`.
- `SessionStart` and `Setup` support `command` and `mcp_tool` hooks only. They do not support `http`, `prompt`, or `agent` hooks.
- Prompt hooks produce an internal allow/block decision. For this repo's review-loop hooks, keep that protocol out of the prompt text; the prompt text should only state the Skill-tool handoff and the review-loop workflow.
- For `PermissionRequest`, prompt-hook `ok: false` does not deny approval. Use a command hook with `hookSpecificOutput.decision.behavior: "deny"` when denial is required.
- Use `UserPromptSubmit` for prompt-time context or validation. Use `Stop` for end-of-turn continuation, including routing a completed implementation into `review-loop`.
- `/goal` is a built-in shortcut for a session-scoped prompt-based `Stop` hook. Treat it as native Claude Code behavior, not as something this plugin needs to emulate with a separate long-running shell workflow.
- Do not remove a `UserPromptSubmit` design just because it is prompt-time logic; only reject it if the official schema or a live hook test proves the specific implementation is wrong.

## Local Claude Code Docs

Before changing or reviewing Claude Code Hook or Claude Code Plugin behavior, query these local playbooks first:

- `/Users/lesterbot/Documents/api-playbooks/Claude Code Hooks.md` — use for hook events, matcher rules, handler types, JSON input/output, exit codes, async hooks, HTTP hooks, prompt hooks, MCP tool hooks, and skill-scoped hooks.
- `/Users/lesterbot/Documents/api-playbooks/Claude Code Plugin.md` — use for plugin layout, manifests, marketplace config, bundled hooks, skills, slash commands, plugin root/data paths, user configuration, and plugin distribution behavior.

Suggested lookup flow:

```bash
rg -n "<hook event|field|handler type|plugin topic>" "/Users/lesterbot/Documents/api-playbooks/Claude Code Hooks.md" "/Users/lesterbot/Documents/api-playbooks/Claude Code Plugin.md"
sed -n '<start>,<end>p' "/Users/lesterbot/Documents/api-playbooks/Claude Code Hooks.md"
sed -n '<start>,<end>p' "/Users/lesterbot/Documents/api-playbooks/Claude Code Plugin.md"
```

Do not rely on memory when a task touches Claude Code hooks or plugins. Verify the relevant local playbook section, then implement or answer from that evidence.

## Build, Test, and Development Commands

- `bash scripts/install-superset-config.sh --verify`: check Superset integration files when touching Superset templates.
- `bash -n scripts/*.sh hooks/*.sh`: run shell syntax validation before committing.

There is no package manager build step in this repo; changes are mostly shell, Markdown, JSON, and YAML.

## Coding Style & Naming Conventions

Shell scripts use Bash with defensive defaults such as `set -euo pipefail` where appropriate. Prefer small helper functions, explicit errors, quoted variable expansions, and existing helpers over duplicated logic. Keep script names lowercase and hyphenated, for example `bump-version.sh` or `install-superset-config.sh`. Markdown should use clear headings, short steps, and copyable command blocks.

## Testing Guidelines

No formal unit test framework is present. For script changes, run `bash -n` on modified shell files plus a targeted dry run or verification command. For workflow template changes, validate YAML shape through the copied templates or a temporary onboarding simulation. For GitHub integration changes, verify the exact `gh` commands in `skills/github-actions-onboarding/SKILL.md`.

## Commit & Pull Request Guidelines

Recent history uses Conventional Commit-style messages, especially `chore:` and `fix(scope): ...` such as `chore: bump version to 1.0.14` and `fix(stop): docs/lock/trivial-only PRs short-circuit straight to auto-merge`. Keep commits focused and mention the changed runtime area when useful. Pull requests should include a concise behavior summary, verification commands run, linked issue if applicable, and screenshots only when rendered documentation or UI-like output changed.

## Security & Configuration Tips

Never commit tokens or local secrets. GitHub secrets such as `CLAUDE_CODE_OAUTH_TOKEN` must be configured through `gh secret set`, not stored in repo files. Treat `.claude/24hour-ClaudeCode.config.json` and generated workflow YAML as contract surfaces; preserve backward compatibility unless the change intentionally migrates users.
