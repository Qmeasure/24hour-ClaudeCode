---
name: using-24hour-ClaudeCode
description: Use when a project session starts with the 24hour-ClaudeCode plugin active and Claude must know the runtime contract, hook handoff, and mandatory skills
---

# 24hour-ClaudeCode Runtime Contract

<EXTREMELY-IMPORTANT>
You are operating inside the **24hour-ClaudeCode** runtime.

This runtime is skill-first:

```text
SessionStart hook -> injects onboarding or runtime context
Stop prompt hook -> explicitly tells Claude to use the review-loop skill via the Skill tool
review-loop skill -> commit / push / PR / wait review / fix / merge
github-actions-onboarding skill -> repo onboarding and setup verification
current Claude Code session -> fixer
GitHub Claude Code Action -> reviewer
scripts -> deterministic helper actions only
```

Do not start another Claude CLI. Do not switch WorkTrees. Do not ask the user for confirmation before the `review-loop` skill commits, pushes, opens a PR, reads review feedback, fixes blocking findings, or enables auto-merge.
</EXTREMELY-IMPORTANT>

## Hook To Skill Handoff

The plugin `Stop` prompt hook does not run git, GitHub, review, or merge logic. It only decides whether Claude may stop.

When the `Stop` prompt blocks stopping, its `reason` must explicitly instruct the main Claude agent to use the skill via the Skill tool:

```text
REVIEW_LOOP_CONTINUE

Use the `review-loop` skill (via the Skill tool) to run the complete PR review loop in this same Claude Code session and same WorkTree. Follow `skills/review-loop/SKILL.md` exactly. Do not stop until the PR is merged, auto-merge is enabled, or a concrete blocker is reported to the user.
```

When you see `REVIEW_LOOP_CONTINUE`, immediately use the `review-loop` skill via the Skill tool and follow it exactly. Do not treat this as a suggestion, and do not continue with ad hoc PR logic outside the skill.

## Runtime Hooks

| Hook | Source | Purpose |
|---|---|---|
| `SessionStart` | `hooks/hooks.json` -> `hooks/bootstrap.sh` | Detect onboarding/runtime state and inject either `github-actions-onboarding` or this runtime contract. |
| `Stop` | `hooks/hooks.json` prompt hook | If implementation appears complete in an active worktree, block stopping and tell Claude to use `review-loop` via the Skill tool. |
| `Stop` while `review-loop` is active | `skills/review-loop/SKILL.md` frontmatter | Keep the review loop running until the PR is merged, auto-merge is enabled, a concrete blocker remains, or the user explicitly stops it. |

Hooks must not own the PR workflow. The PR workflow belongs to `review-loop`.

## Runtime Activation

The runtime is active only when all of these are true:

```text
current session is in a git worktree
branch is not protected
GitHub CLI auth works
workflow files are installed
.claude/24hour-ClaudeCode.config.json exists and is enabled
```

If onboarding is incomplete, use `github-actions-onboarding` instead of editing code.

If the session is in the main checkout rather than a worktree, the runtime is intentionally dormant.

## Goal Mode

Prefer native Claude Code `/goal <condition>` for feature work. `/goal` is a built-in session-scoped prompt-based Stop hook. This plugin does not implement a separate Goal state machine.

If native `/goal` still appears in progress, let native `/goal` continue. After `/goal` allows the turn to stop, the 24hour-ClaudeCode `Stop` prompt may hand off to `review-loop`.

## Mandatory Skills

| Skill | Use when |
|---|---|
| `github-actions-onboarding` | SessionStart says onboarding is incomplete, or the user runs `/24hour-ClaudeCode:setup`. |
| `review-loop` | Stop prompt emits `REVIEW_LOOP_CONTINUE`, or implementation is complete and must go through PR review before stopping. |

All PR review triage, rework, CI triage, pre-push checks, stop handling, and merge handling stay inside `review-loop`.

## Runtime Files

Project runtime config is repo-local:

```text
.claude/24hour-ClaudeCode.config.json
```

Do not create or rely on local loop-state markdown files. GitHub, git, and the current Claude Code session are the sources of truth.

## Slash Commands

The `commands/` directory is intentionally kept. Claude Code plugins discover flat Markdown files in `commands/` as slash-command skills. These commands are small project controls, not workflow engines:

| Command | Purpose |
|---|---|
| `/24hour-ClaudeCode:setup` | Use `github-actions-onboarding`. |
| `/24hour-ClaudeCode:status` | Read git status, config, and current PR status. |
| `/24hour-ClaudeCode:disable` | Set project config `enabled=false`. |
| `/24hour-ClaudeCode:enable` | Set project config `enabled=true`. |

Do not delete these command files unless the user intentionally removes the corresponding slash-command UX or replaces it with an equivalent skill entry point.

## Forbidden Behaviors

- Do not put commit/push/PR/review/merge orchestration into hooks.
- Do not run the review loop from the main checkout.
- Do not switch WorkTrees during the loop.
- Do not start another Claude CLI as a fixer.
- Do not depend on custom `review-verdict-<sha>.json` artifacts.
- Do not treat missing, stale, or ambiguous review output as pass.
- Do not fix unrelated code while addressing review feedback.
- Do not bypass git hooks with `--no-verify`.
- Do not force-push unless the user explicitly asks and you use `--force-with-lease`.
