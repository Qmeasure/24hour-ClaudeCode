# CLAUDE.md

This file provides guidance to Claude Code when working on this repository.

## What This Repo Is

`24hour-ClaudeCode` is a Claude Code plugin. It is not a standalone app and has no package-manager build step. Most work is Bash, Markdown, JSON, and GitHub Actions YAML.

Key directories:

- `.claude-plugin/` — plugin manifest and marketplace metadata.
- `hooks/` — Claude Code lifecycle hooks.
- `skills/` — mandatory workflows and phase skills.
- `commands/` — debug slash commands.
- `scripts/` — version synchronization and deterministic Superset file helpers.
- `templates/` — user-project workflow/config/Superset templates.
- `README*.md` and `FLOW*.md` — user-facing and architecture docs.

## Current Architecture

The runtime is skill-first:

```text
SessionStart hook -> injects using-24hour-ClaudeCode or onboarding skill
Stop prompt hook -> routes current session to review-loop
review-loop skill Stop hook -> prevents mid-loop stopping
review-loop skill -> commit / push / PR / wait review / fix / merge
GitHub Claude Code Action -> reviewer only
current Claude Code session -> fixer only
```

Hard rule: do not move the PR/review/merge workflow into hooks. The plugin Stop hook is a prompt-based router that may only block stopping with `REVIEW_LOOP_CONTINUE` and point the current session to `review-loop`.

## Operating Principles

Follow these principles when changing runtime behavior:

- Hook = trigger or context injection only. No long-running PR workflow belongs in hooks.
- `UserPromptSubmit` is a fully supported Claude Code hook event. It fires before Claude processes each submitted prompt, supports context injection and prompt blocking, and does not support matchers; use it when prompt-time routing or Goal-related context is needed.
- Skill = behavior, judgment, and workflow. `review-loop` owns commit/push/PR/review/fix/merge sequencing; `github-actions-onboarding` owns repo onboarding.
- Script = deterministic mechanical helper only. Scripts need clear input/output and should be safe to run repeatedly.
- State = minimal and visible. Keep `review-loop-state.md` readable; do not encode hidden workflow machinery in state.
- Review = real GitHub surfaces. Do not require custom verdict artifacts or infer pass from silence.
- Session = same Claude Code session and WorkTree. Do not spawn another Claude CLI to repair code.
- Skill description = trigger condition only. Put workflow details in the skill body.

## Hook / Skill / Script Routing

- Hook routes the agent to the right next context. It should trigger, inspect lifecycle input, inject context, or block/continue with a short reason; it must not own a full multi-step workflow.
- For long workflow scenarios, use prompt-based hooks to make the semantic routing decision and guide the current agent into the correct skill. The prompt text must explicitly tell Claude to use the target skill via the Skill tool, for example: "Use the `review-loop` skill (via the Skill tool) to run the complete PR review loop." Do not leave the handoff as an abstract "route" instruction.
- Skill constrains the agent's behavior and workflow. Multi-step order, stopping rules, review discipline, rework boundaries, verification standards, and merge rules belong in skills such as `review-loop` and `github-actions-onboarding`.
- For deterministic non-workflow scenarios, use command hooks to call scripts. Use this path for fixed checks, environment detection, config reads, marker writes, context generation, formatting, validation, install, or sync actions.
- Script only performs mechanical, deterministic, repeatable tool actions. Scripts may parse hook JSON input, inspect files, run fixed commands, and emit structured JSON, but they must not decide or run agent-level workflows.
- In short: long workflows use prompt-based hooks to route to skills; deterministic tool actions use command hooks to run scripts. Hook routes, skill governs, script executes repeatable mechanics.

## Proven Review Loop Prompt Contract

The successful `/Users/lesterbot/Downloads/claude-test2` review-loop pattern is the current reference:

- Review-loop Stop hooks must use `type: "prompt"`, not command, HTTP, MCP, or agent hooks.
- Prompt hooks use `model: "claude-opus-4-7"` and `timeout: 7200`.
- Do not put an explicit hook input placeholder in review-loop hook prompts. Claude Code appends hook input when the placeholder is omitted.
- Review-loop hook prompts must contain only the workflow objective and workflow steps.
- Do not include hook decision scaffolding in review-loop prompts: no return-instruction block, no allow/block JSON examples, no protocol fields, no acceptance-criteria section, and no output-format section.
- The prompt content should state only the complete review-loop workflow: use the `review-loop` skill via the Skill tool, preflight, prove reviewable changes, inspect, verify, commit, push, bind current SHA, create or refresh PR, wait for current-SHA GitHub review, read top-level and inline review output, fix blocking security/correctness findings, repeat, merge or enable auto-merge, then write a terminal state.
- Keep unrelated rationale, history, implementation commentary, JSON protocol details, and fallback narratives out of the hook prompt.
- Onboarding must add `.Claude/` to the project root `.gitignore`. Do not add `.claude/` there, because onboarding intentionally commits `.claude/24hour-ClaudeCode.config.json` and `.claude/runtime/24hour-ClaudeCode/.gitignore`.

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

The setup script must not call removed runtime helpers such as `scripts/check-actions.sh`, and must not print maintenance commands pointing at plugin-internal scripts. It may point users to slash commands such as `/24hour-ClaudeCode:status`, `/24hour-ClaudeCode:retry`, `/24hour-ClaudeCode:setup`, and `claude plugin details 24hour-ClaudeCode@24hour-ClaudeCode`.

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

## Important Runtime Files

- `skills/review-loop/SKILL.md` — main workflow.
- `skills/using-24hour-ClaudeCode/SKILL.md` — bootstrap contract injected by SessionStart.
- `.claude/runtime/24hour-ClaudeCode/review-loop-state.md` — visible loop state in user projects.

The runtime state directory must contain `.gitignore` with `*` so local state never leaks into PR diffs.

## What Scripts Are For

Scripts are allowed only for deterministic mechanical work:

- version bumping
- Superset config file install/verify

Scripts must not become workflow engines. Do not add scripts such as `wait.sh`, `decide.sh`, `next-step.sh`, or verdict parsers unless the task is narrowly mechanical and the `review-loop` skill remains the workflow owner.

## Review Contract

Do not assume GitHub Claude Code Action emits a custom verdict artifact. Review-loop decisions must read real GitHub surfaces:

- PR review submissions
- inline review comments
- check run details, annotations, and logs
- PR comments only when clearly tied to the current review run or current SHA

Never treat missing, stale, or ambiguous review output as pass. Auto-merge is allowed only when evidence is reliably bound to `git rev-parse HEAD`.

## Goal Mode

Use native Claude Code `/goal`. Official Claude Code docs describe `/goal` as a built-in session-scoped prompt-based Stop hook. This plugin does not maintain a separate Goal guard or ready marker.

## Commands For Editing This Repo

```bash
bash -n hooks/*.sh scripts/*.sh templates/*.sh
jq -e . .claude-plugin/plugin.json
jq -e . .claude-plugin/marketplace.json
jq -e . hooks/hooks.json
jq -e . templates/24hour-ClaudeCode.config.json
bash scripts/install-superset-config.sh --verify
```

## Conventions

- Bash scripts should use defensive quoting and small helpers.
- Frontmatter `description` in skills should describe trigger conditions, not summarize the workflow.
- Markdown should be concise and beginner-friendly in `README*`; use `FLOW*` for architecture detail.
- Keep user-facing English and Chinese docs aligned when behavior changes.
- Use existing GitHub Action templates; do not invent alternate workflow structures.

## Do Not Do

- Do not reintroduce custom `review-verdict-<sha>.json` as the merge gate.
- Do not add a long-running Stop hook.
- Do not spawn another Claude CLI to fix code.
- Do not switch WorkTrees during review-loop.
- Do not rely on frontend-style fake progress or fake review pass signals.
- Do not bypass git hooks with `--no-verify`.
- Do not modify `.github/workflows/` from inside a Claude Code Action run.
